# Runbook: Accounts + OCI bootstrap (Phase 0)

งานมือครั้งเดียวก่อน Phase 1: บัญชี GitHub/OCI, compartment, bucket state, identity ของ CI แล้วใส่ credential ลง GitHub Environments

> **ห้ามใส่ค่าจริง (OCID, fingerprint, namespace, key) ในไฟล์นี้หรือที่ใดใน Git** — ใช้ `<placeholder>` เท่านั้น ค่าจริงอยู่ใน password manager และ GitHub Environment secrets

**ต้องมีก่อน:** repo เป็น public แล้ว และมี Environment `plan` / `production` (Phase 0 Task 3)

---

## 1. GitHub account

1. Settings → Password and authentication → **Passkeys** → Add a passkey (หรือ security key)
2. ตรวจว่า **Two-factor authentication = Enabled**
3. ดาวน์โหลด recovery codes → เก็บใน password manager

ตรวจ: `gh api user --jq .two_factor_authentication` → `true`

---

## 2. OCI account

1. สมัคร Oracle Cloud Free Tier — **home region `Singapore (ap-singapore-1)`** (เปลี่ยนภายหลังไม่ได้)
2. Profile → Security → **เปิด MFA** ให้ admin user (ใช้ passkey / authenticator app)
3. Billing → Upgrade to **Pay As You Go** (resource Always Free ยังฟรี แต่ instance ไม่ถูก reclaim)
4. Billing → Budgets → Create Budget
   - Target: root compartment (tenancy), Amount: **$1**, Reset: Monthly
   - Alert rule: **Actual spend**, threshold **1 %** ของ budget → email ของคุณ
   - (แนะนำ) Alert rule ที่ 2: **Forecast spend**, threshold **100 %** — เตือนก่อนเกินจริง
   - หมายเหตุ: สกุลเงินของ budget = สกุลเงินของ account (เช่น SGD) ไม่จำเป็นต้องเป็น USD
5. Identity & Security → **Cloud Guard** → Enable — Oracle-managed recipes, reporting region `ap-singapore-1`, target = root compartment

ตรวจใน Cloud Shell:

```bash
oci budgets budget budget list --compartment-id "$OCI_TENANCY" --query 'data[].{name:"display-name",amount:amount,rules:"alert-rule-count"}' --output table
B=$(oci budgets budget budget list --compartment-id "$OCI_TENANCY" --query 'data[0].id' --raw-output)
oci budgets budget alert-rule list --budget-id "$B" --query 'data[].{type:type,threshold:threshold}' --output table   # ACTUAL 1.0 (+ FORECAST 100.0)
oci cloud-guard configuration get --compartment-id "$OCI_TENANCY" --query 'data.status'   # "ENABLED"
```

---

## 3. Compartments + state bucket (Cloud Shell)

```bash
T="$OCI_TENANCY"   # Cloud Shell ตั้งตัวแปรนี้ให้แล้ว

oci iam compartment create --compartment-id "$T" --name vaewprach-lab       --description "vaewprach-lab infra"
oci iam compartment create --compartment-id "$T" --name vaewprach-lab-state --description "vaewprach-lab OpenTofu state only"

STATE_C=$(oci iam compartment list --compartment-id "$T" --name vaewprach-lab-state --query 'data[0].id' --raw-output)
oci os bucket create --compartment-id "$STATE_C" --name tofu-state \
  --public-access-type NoPublicAccess --versioning Enabled
```

ตรวจ: `oci os bucket get -bn tofu-state --query 'data.{access:"public-access-type",versioning:versioning}'` → `NoPublicAccess`, `Enabled`

> Compartment ใหม่ใช้เวลาสักครู่กว่าจะใช้ได้ — ถ้า `bucket create` error `NotAuthorizedOrNotFound` ให้รอ 1–2 นาทีแล้วลองใหม่

---

## 4. CI identities

### Groups + users (identity domain `Default`)

Console → Identity & Security → Domains → `Default`:

| Group | User | หมายเหตุ |
|---|---|---|
| `ci-plan` | `ci-plan` | ใช้ตอน PR — อ่านอย่างเดียว |
| `ci-apply` | `ci-apply` | ใช้ตอน merge — ผ่าน Environment `production` ที่ต้อง approve |

- User ทั้งสอง: **ไม่ตั้ง console password**, เพิ่มเข้า group ชื่อเดียวกัน
- Default domain บังคับให้มี email — ใช้ alias ของคุณเอง เช่น `you+ci-plan@gmail.com` / `you+ci-apply@gmail.com` (Gmail ส่งเข้ากล่องเดิม)
- User capabilities: เปิดเฉพาะ **API keys** และ **Customer secret keys** ปิดอย่างอื่นทั้งหมด

### Policy `vaewprach-lab-ci` (ที่ root compartment)

```
Allow group 'Default'/'ci-apply' to manage all-resources in compartment vaewprach-lab
Allow group 'Default'/'ci-plan' to read all-resources in compartment vaewprach-lab
Allow group 'Default'/'ci-apply' to read buckets in compartment vaewprach-lab-state
Allow group 'Default'/'ci-plan' to read buckets in compartment vaewprach-lab-state
Allow group 'Default'/'ci-apply' to manage objects in compartment vaewprach-lab-state where target.bucket.name = 'tofu-state'
Allow group 'Default'/'ci-plan' to read objects in compartment vaewprach-lab-state where target.bucket.name = 'tofu-state'
```

> `ci-plan` ไม่มีสิทธิ์เขียน object → เขียน state lock (`.tflock`) ไม่ได้ ดังนั้น Phase 1 ต้องรัน `tofu plan -lock=false` ตอน PR (ตั้งใจ)
>
> `read all-resources` อ่าน secret bundle ได้ → **ห้ามสร้าง Vault/secret ใน compartment `vaewprach-lab`** (Phase 2 ใช้ compartment แยก)

### Keys (ทำใน Cloud Shell, ทีละ user)

```bash
U=ci-plan   # รันซ้ำด้วย U=ci-apply
USER_ID=$(oci iam user list --name "$U" --query 'data[0].id' --raw-output)

# API signing key — private key อยู่แค่ใน Cloud Shell จนกว่าจะใส่ GitHub แล้วลบ
openssl genrsa -out ~/$U.pem 2048 && chmod 600 ~/$U.pem
openssl rsa -pubout -in ~/$U.pem -out ~/$U.pub.pem
oci iam user api-key upload --user-id "$USER_ID" --key-file ~/$U.pub.pem --query 'data.fingerprint' --raw-output

# Customer Secret Key (S3-compatible access สำหรับ OpenTofu backend)
oci iam customer-secret-key create --user-id "$USER_ID" --display-name tofu-state \
  --query 'data.{id:id,key:key}'          # "key" แสดงครั้งเดียว — คัดลอกทันที
```

`id` = `STATE_S3_ACCESS_KEY_ID`, `key` = `STATE_S3_SECRET_ACCESS_KEY`

---

## 5. ทดสอบ least privilege (Cloud Shell)

> **สำคัญ:** Cloud Shell ตั้ง `OCI_CLI_AUTH=instance_obo_user` และ `OCI_CLI_CONFIG_FILE=/etc/oci/config` ไว้ — ถ้าไม่ override คำสั่งจะรันด้วยสิทธิ์ **admin ของคุณ** ไม่ใช่ CI user ทำให้ผลทดสอบผิด และแถว `bucket delete` จะลบ bucket จริงได้

สร้างไฟล์ config แยก `~/ci-test.config` (ไม่ใช่ `~/.oci/config`):

```ini
[ci-plan]
user=<ci-plan user OCID>
fingerprint=<fingerprint>
key_file=~/ci-plan.pem
tenancy=<tenancy OCID>
region=ap-singapore-1

[ci-apply]
user=<ci-apply user OCID>
fingerprint=<fingerprint>
key_file=~/ci-apply.pem
tenancy=<tenancy OCID>
region=ap-singapore-1
```

```bash
chmod 600 ~/ci-test.config
ci() { local p=$1; shift; OCI_CLI_AUTH=api_key oci --auth api_key --config-file ~/ci-test.config --profile "$p" "$@"; }

# ยืนยันว่ารันเป็น CI user จริงก่อน — ต้องเห็น OCID ของ ci-plan ไม่ใช่ของ admin
ci ci-plan iam user get --user-id <ci-plan user OCID> --query 'data.name' --raw-output   # ci-plan
```

| คำสั่ง | ต้องได้ |
|---|---|
| `ci ci-plan os object list -bn tofu-state` | สำเร็จ (ว่าง) |
| `ci ci-plan os object put -bn tofu-state --file /etc/hostname --name probe` | **fail** `NotAuthorizedOrNotFound` |
| `ci ci-apply os object put -bn tofu-state --file /etc/hostname --name probe` | สำเร็จ |
| `ci ci-apply os object delete -bn tofu-state --object-name probe --force` | สำเร็จ (ลบไฟล์ทดสอบ) |
| `ci ci-apply os bucket delete -bn tofu-state --force` | **fail** `NotAuthorizedOrNotFound` |

ถ้าบรรทัดที่ต้อง fail กลับสำเร็จ → policy กว้างเกิน **หยุดและแก้ policy ก่อน**

---

## 6. ใส่ credential ลง GitHub Environments

1. สร้าง state passphrase: `openssl rand -base64 32` → **บันทึกลง password manager ก่อน** (หาย = state ถอดรหัสไม่ได้)
2. หา namespace: `oci os ns get --query data --raw-output`
3. ใส่ค่าลง GitHub Environments `plan` / `production` — วิธีที่แนะนำคือรัน `gh` **ใน Cloud Shell** เพื่อไม่ให้ private key ผ่าน clipboard ของเครื่อง local:

   ```bash
   # ติดตั้ง gh ใน Cloud Shell (ครั้งเดียว) แล้ว login แบบ device code
   V=2.103.3; A=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
   curl -sL https://github.com/cli/cli/releases/download/v$V/gh_${V}_linux_$A.tar.gz | tar xz -C ~ && export PATH=~/gh_${V}_linux_$A/bin:$PATH
   gh auth login --hostname github.com --git-protocol https --web
   gh secret set OCI_PRIVATE_KEY --repo bookvt/vaewprach-lab --env plan       < ~/ci-plan.pem
   gh secret set OCI_PRIVATE_KEY --repo bookvt/vaewprach-lab --env production < ~/ci-apply.pem
   gh secret set OCI_FINGERPRINT --repo bookvt/vaewprach-lab --env plan       # วางค่าเมื่อถูกถาม (ไม่ขึ้นใน history)
   ```

   (ทางเลือก: วางทีละค่าในหน้าเว็บ GitHub → Settings → Environments — ค่าจะผ่าน clipboard ของเครื่อง local) หลังเสร็จรัน `gh auth logout` ใน Cloud Shell

| ชื่อ | ชนิด | `plan` | `production` |
|---|---|---|---|
| `OCI_REGION` | variable | `ap-singapore-1` | `ap-singapore-1` |
| `OCI_TENANCY_OCID` | secret | tenancy OCID | tenancy OCID |
| `OCI_COMPARTMENT_OCID` | secret | OCID ของ `vaewprach-lab` | เหมือนกัน |
| `OCI_USER_OCID` | secret | ของ `ci-plan` | ของ `ci-apply` |
| `OCI_FINGERPRINT` | secret | ของ `ci-plan` | ของ `ci-apply` |
| `OCI_PRIVATE_KEY` | secret | `cat ~/ci-plan.pem` | `cat ~/ci-apply.pem` |
| `STATE_NAMESPACE` | secret | namespace | namespace |
| `STATE_S3_ACCESS_KEY_ID` | secret | ของ `ci-plan` | ของ `ci-apply` |
| `STATE_S3_SECRET_ACCESS_KEY` | secret | ของ `ci-plan` | ของ `ci-apply` |
| `TOFU_STATE_PASSPHRASE` | secret | passphrase | passphrase เดียวกัน |

4. ล้าง Cloud Shell:

```bash
shred -u ~/ci-plan.pem ~/ci-apply.pem ~/ci-plan.pub.pem ~/ci-apply.pub.pem
shred -u ~/ci-test.config
```

ตรวจ (เครื่องไหนก็ได้ที่มี `gh`):

```bash
gh secret list   --repo bookvt/vaewprach-lab --env plan        # 9 ชื่อ
gh secret list   --repo bookvt/vaewprach-lab --env production  # 9 ชื่อ
gh variable list --repo bookvt/vaewprach-lab --env plan        # OCI_REGION
```

---

## Rotation

- API key + Customer Secret Key: ทุก 90 วัน หรือทันทีที่สงสัยว่ารั่ว — สร้างใหม่ → อัปเดต GitHub → ลบอันเก่าใน OCI
- **ถ้า credential หลุด: rotate ก่อน** แล้วค่อยตามลบจาก log/history
