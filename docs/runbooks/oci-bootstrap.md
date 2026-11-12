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

## 4. CI identities (Cloud Shell)

| Group / User | ใช้เมื่อ |
|---|---|
| `ci-plan` | PR — อ่านอย่างเดียว |
| `ci-apply` | merge — ผ่าน Environment `production` ที่ต้อง approve |

### Groups + users

Default domain บังคับให้ user มี email — ใช้ alias ของคุณเอง (Gmail: `you+ci-plan@gmail.com` เข้ากล่องเดิม) ถ้ามี email เชิญ activate **ไม่ต้องกด**

```bash
MAIL_USER=yourname; MAIL_DOMAIN=gmail.com   # ← แก้
T="$OCI_TENANCY"
for N in ci-plan ci-apply; do
  G=$(oci iam group create --compartment-id "$T" --name "$N" --description "vaewprach-lab CI ($N)" --query data.id --raw-output)
  U=$(oci iam user create  --compartment-id "$T" --name "$N" --description "vaewprach-lab CI ($N) - API only" \
        --email "${MAIL_USER}+${N}@${MAIL_DOMAIN}" --query data.id --raw-output)
  oci iam user update-user-capabilities --user-id "$U" \
    --can-use-console-password false --can-use-api-keys true --can-use-customer-secret-keys true \
    --can-use-auth-tokens false --can-use-smtp-credentials false >/dev/null
  oci iam group add-user --group-id "$G" --user-id "$U" >/dev/null
  echo "ok: $N"
done
```

### Policy `vaewprach-lab-ci` (ที่ root)

```bash
cat > ~/ci-policy.json <<'JSON'
[
  "Allow group 'Default'/'ci-apply' to manage all-resources in compartment vaewprach-lab",
  "Allow group 'Default'/'ci-plan' to read all-resources in compartment vaewprach-lab",
  "Allow group 'Default'/'ci-apply' to read buckets in compartment vaewprach-lab-state",
  "Allow group 'Default'/'ci-plan' to read buckets in compartment vaewprach-lab-state",
  "Allow group 'Default'/'ci-apply' to manage objects in compartment vaewprach-lab-state where target.bucket.name = 'tofu-state'",
  "Allow group 'Default'/'ci-plan' to read objects in compartment vaewprach-lab-state where target.bucket.name = 'tofu-state'"
]
JSON
oci iam policy create --compartment-id "$T" --name vaewprach-lab-ci \
  --description "vaewprach-lab CI least privilege" --statements file://~/ci-policy.json --query data.name --raw-output
rm ~/ci-policy.json
```

> `ci-plan` ไม่มีสิทธิ์เขียน object → เขียน state lock (`.tflock`) ไม่ได้ ดังนั้น Phase 1 ต้องรัน `tofu plan -lock=false` ตอน PR (ตั้งใจ)
>
> `read all-resources` อ่าน secret bundle ได้ → **ห้ามสร้าง Vault/secret ใน compartment `vaewprach-lab`** (Phase 2 ใช้ compartment แยก)

ตรวจ: แต่ละ user ต้อง `console=False, api=True, s3=True` และอยู่ใน group ของตัวเอง; policy มี 6 statements

```bash
for N in ci-plan ci-apply; do
  oci iam user list --name "$N" --query 'data[0].capabilities.{console:"can-use-console-password",api:"can-use-api-keys",s3:"can-use-customer-secret-keys"}' --output table
  oci iam user list-groups --user-id "$(oci iam user list --name "$N" --query 'data[0].id' --raw-output)" --query 'data[].name' --raw-output
done
oci iam policy list --compartment-id "$T" --name vaewprach-lab-ci --query 'length(data[0].statements)'   # 6
```

### Keys → `~/ci-secrets/` (ค่าลับไม่ขึ้นจอ)

**รันครั้งเดียว** — OCI จำกัด API key 3 อัน และ Customer Secret Key 2 อันต่อ user

```bash
umask 077 && mkdir -p ~/ci-secrets && cd ~/ci-secrets
for N in ci-plan ci-apply; do
  U=$(oci iam user list --name "$N" --query 'data[0].id' --raw-output); echo "$U" > $N.user
  openssl genrsa -out $N.pem 2048 2>/dev/null
  openssl rsa -pubout -in $N.pem -out $N.pub.pem 2>/dev/null
  oci iam user api-key upload --user-id "$U" --key-file $N.pub.pem --query data.fingerprint --raw-output > $N.fingerprint
  oci iam customer-secret-key create --user-id "$U" --display-name tofu-state --query 'data.{id:id,key:key}' > $N.s3.json
  echo "ok: $N"
done
cd ~
```

> Customer Secret Key ใหม่ใช้เวลา **~10 นาที** กว่าจะใช้กับ S3 API ได้ — ระหว่างนั้นจะได้ 403 "The secret key required to complete authentication could not be found"

---

## 5. ทดสอบ least privilege (Cloud Shell)

> Cloud Shell ตั้ง `OCI_CLI_AUTH=instance_obo_user` ไว้ — คำสั่งปกติรันเป็น **admin** ไม่ใช่ CI user. script ด้านล่างบังคับ `--auth api_key` ทุกคำสั่ง และเลือก check แบบที่ถ้าพลาดไปรันเป็น admin ก็แค่สร้าง probe ที่ไม่มีอันตราย (ไม่มีการลบ)

```bash
mkdir -p ~/lab && for f in least-privilege-test.sh s3-probe.py; do
  curl -fsSL "https://raw.githubusercontent.com/bookvt/vaewprach-lab/main/scripts/oci/$f" -o ~/lab/$f; done
bash ~/lab/least-privilege-test.sh
```

ต้อง **PASS ทุกบรรทัด** (11 checks รวม S3 list ของทั้งสอง user)

- `FAIL … CANNOT …` → สิทธิ์กว้างเกิน หรือรันเป็น admin — **หยุด** แก้ policy และลบ probe ที่อาจถูกสร้าง (`probe-plan`, `probe-root`, policy `probe`)
- `FAIL … S3 list (403 …could not be found)` → key ยังไม่พร้อม รอ ~10 นาทีแล้วรันใหม่

---

## 6. ใส่ credential ลง GitHub Environments

ต้องมี Environment `plan` / `production` แล้ว (Phase 0 Task 3) — ทำใน Cloud Shell เพื่อให้ private key ไม่ผ่านเครื่อง local

**6.1 ติดตั้ง + login `gh`** (Authenticate Git? → No)

```bash
V=2.103.3; A=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -sL https://github.com/cli/cli/releases/download/v$V/gh_${V}_linux_$A.tar.gz | tar xz -C ~ \
  && export PATH=~/gh_${V}_linux_$A/bin:$PATH
gh auth login --hostname github.com --git-protocol https --web   # ใส่รหัสที่ github.com/login/device
gh auth status   # bookvt, scopes ต้องมี 'repo'
```

**6.2 State passphrase** — สร้างใน password manager (≥ 32 ตัวอักษร) และ**บันทึกก่อน** (หาย = state ถอดรหัสไม่ได้)

**6.3 ใส่ค่า**

```bash
cd ~/ci-secrets
R=bookvt/vaewprach-lab; T="$OCI_TENANCY"
LAB_C=$(oci iam compartment list --compartment-id "$T" --name vaewprach-lab --query 'data[0].id' --raw-output)
NS=$(oci os ns get --query data --raw-output)
put() { printf '%s' "$3" | gh secret set "$1" --repo $R --env "$2"; }
s3v() { python3 -c 'import json,sys;sys.stdout.write(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1.s3.json" "$2"; }
for pair in plan:ci-plan production:ci-apply; do
  E=${pair%%:*}; N=${pair##*:}
  gh variable set OCI_REGION --repo $R --env $E --body ap-singapore-1
  put OCI_TENANCY_OCID           $E "$T"
  put OCI_COMPARTMENT_OCID       $E "$LAB_C"
  put STATE_NAMESPACE            $E "$NS"
  put OCI_USER_OCID              $E "$(cat $N.user)"
  put OCI_FINGERPRINT            $E "$(cat $N.fingerprint)"
  gh secret set OCI_PRIVATE_KEY --repo $R --env $E < $N.pem
  put STATE_S3_ACCESS_KEY_ID     $E "$(s3v $N id)"
  put STATE_S3_SECRET_ACCESS_KEY $E "$(s3v $N key)"
  echo "done: $E ($N)"
done
cd ~
# วาง passphrase เดียวกันทั้งสองครั้ง (input ไม่ขึ้นจอ)
gh secret set TOFU_STATE_PASSPHRASE --repo bookvt/vaewprach-lab --env plan
gh secret set TOFU_STATE_PASSPHRASE --repo bookvt/vaewprach-lab --env production
```

| ชื่อ | ชนิด | `plan` | `production` |
|---|---|---|---|
| `OCI_REGION` | variable | `ap-singapore-1` | `ap-singapore-1` |
| `OCI_TENANCY_OCID` | secret | tenancy OCID | tenancy OCID |
| `OCI_COMPARTMENT_OCID` | secret | OCID ของ `vaewprach-lab` | เหมือนกัน |
| `OCI_USER_OCID` | secret | ของ `ci-plan` | ของ `ci-apply` |
| `OCI_FINGERPRINT` | secret | ของ `ci-plan` | ของ `ci-apply` |
| `OCI_PRIVATE_KEY` | secret | `ci-plan.pem` | `ci-apply.pem` |
| `STATE_NAMESPACE` | secret | namespace | namespace |
| `STATE_S3_ACCESS_KEY_ID` | secret | ของ `ci-plan` | ของ `ci-apply` |
| `STATE_S3_SECRET_ACCESS_KEY` | secret | ของ `ci-plan` | ของ `ci-apply` |
| `TOFU_STATE_PASSPHRASE` | secret | passphrase | passphrase เดียวกัน |

**6.4 ตรวจ**

```bash
for e in plan production; do echo "$e: $(gh secret list --repo bookvt/vaewprach-lab --env $e | wc -l) secrets"; done   # 9 / 9
gh variable list --repo bookvt/vaewprach-lab --env plan   # OCI_REGION
```

**6.5 ล้าง Cloud Shell** (หลังตรวจผ่านเท่านั้น)

```bash
find ~/ci-secrets -type f -exec shred -u {} + && rmdir ~/ci-secrets
rm -rf ~/lab
gh auth logout --hostname github.com && rm -rf ~/gh_* ~/.config/gh
```

---

## Rotation

- API key + Customer Secret Key: ทุก 90 วัน หรือทันทีที่สงสัยว่ารั่ว — สร้างใหม่ (§4 Keys) → รอ ~10 นาที → `least-privilege-test.sh` → อัปเดต GitHub (§6.3) → ลบอันเก่าใน OCI
- **ถ้า credential หลุด: rotate ก่อน** แล้วค่อยตามลบจาก log/history
