# Phase 0 — Repo & Accounts Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ทำให้ repo `bookvt/vaewprach-lab` พร้อมเป็น public อย่างปลอดภัย และมี OCI account + CI identity พร้อมให้ Phase 1 (OpenTofu) ใช้

**Architecture:** ไฟล์ hygiene + security workflows เข้า `main` ผ่าน PR ขณะ repo ยัง private → ตั้งค่า GitHub ผ่าน `gh api` → gitleaks สแกนทั้ง history ผ่านแล้วจึงเปลี่ยนเป็น public → เปิด security features ที่ฟรีเฉพาะ public → สร้าง OCI bootstrap identities ด้วยมือตาม runbook แล้วเก็บ credential ใน GitHub Environments

**Tech Stack:** GitHub Actions, gitleaks, zizmor, OpenSSF Scorecard, CodeQL default setup, Renovate, bash, OCI Console / Cloud Shell

**Spec:** [`README.md`](../../../README.md) · ลำดับรวม: [`2026-11-12-roadmap.md`](2026-11-12-roadmap.md)

## Global Constraints

- GitHub owner/user: `bookvt`, repo: `bookvt/vaewprach-lab`, default branch: `main`
- ทุก third-party action pin ด้วย **full commit SHA** ตามด้วย comment `# vX.Y.Z` (ให้ Renovate อัปเดตได้)
- ทุก workflow: top-level `permissions: {}` แล้วให้สิทธิ์ราย job; `actions/checkout` ใช้ `persist-credentials: false`
- ห้ามใช้ trigger `pull_request_target` และ `workflow_run`
- OCI home region: `ap-singapore-1`; compartments: `vaewprach-lab` (infra), `vaewprach-lab-state` (state เท่านั้น); bucket: `tofu-state`
- ไม่มี OCID, IP, หรือ credential ใดๆ อยู่ใน Git — เก็บใน GitHub Environment secrets เท่านั้น
- Budget alert: $1/เดือน, แจ้งเมื่อ actual spend > 1%

## Review Focus

1. **Secret อยู่ใน history ก่อนเปิด public** — ต้องสแกนทั้ง history และผ่านก่อนเปลี่ยน visibility (Task 3 Step 1 เป็น gate)
2. **ชื่อ required status check ไม่ตรงกับชื่อ job** — Ruleset จะ block ทุก PR ตลอดไป หรือไม่บังคับอะไรเลย (Task 3 Step 7 ตรวจด้วย PR ทดสอบ)
3. **Workflow จาก fork รันโดยไม่ได้รับอนุญาต** — ต้องยืนยัน approval policy ผ่าน API (Task 3 Step 3)
4. **State passphrase หาย = state กู้คืนไม่ได้** — ต้องเก็บไว้ใน password manager ก่อนใส่ GitHub (Task 4 Step 6)
5. **`ci-plan` มี `read all-resources` ซึ่งอ่าน secret bundle ได้** — ห้ามสร้าง Vault/secret ใน compartment `vaewprach-lab`; Phase 2 จะสร้าง Vault ใน compartment แยก (Task 4 Step 4 ทดสอบว่า `ci-plan` เขียนไม่ได้)

---

### Task 1: Repo hygiene files (🤖)

**Files:**
- Create: `.gitignore`, `SECURITY.md`, `.github/CODEOWNERS`, `renovate.json`

**Interfaces:**
- Produces: `.gitignore` patterns ที่ Phase 1+ พึ่งพา (state, plan, kubeconfig, age key)

- [ ] **Step 1: เขียน check ที่ต้อง fail ก่อน**

```bash
for f in infra/live/terraform.tfstate infra/live/terraform.tfstate.backup infra/live/tfplan \
         infra/live/.terraform/x prod.tfvars .env .env.local kubeconfig x.kubeconfig \
         keys.txt my.agekey oci_api_key.pem bin/x obj/x; do
  git check-ignore -q "$f" || echo "NOT IGNORED: $f"
done
```
Expected (ก่อนสร้างไฟล์): พิมพ์ `NOT IGNORED` ทุกบรรทัด

- [ ] **Step 2: สร้าง `.gitignore`** ให้ครอบคลุม path ใน Step 1 ทั้งหมด + `.DS_Store`, `.idea/`. **ห้าม** ignore `.terraform.lock.hcl` (ต้อง commit)

- [ ] **Step 3: รัน Step 1 ซ้ำ** — Expected: ไม่มี output. และ `git check-ignore -q infra/live/.terraform.lock.hcl` ต้อง exit 1 (ไม่ถูก ignore)

- [ ] **Step 4: สร้างไฟล์ที่เหลือ**
  - `.github/CODEOWNERS`: `* @bookvt`
  - `SECURITY.md`: ให้แจ้งช่องโหว่ผ่าน GitHub private vulnerability reporting (แท็บ Security → Report a vulnerability), ห้ามเปิด public issue, ระบุว่าเป็น personal lab ไม่มี SLA
  - `renovate.json`: extends `config:recommended`, `helpers:pinGitHubActionDigests`, `:dependencyDashboard`; `minimumReleaseAge: "3 days"` (กัน release ที่ถูก compromise แล้วถอนภายในไม่กี่วัน); `labels: ["dependencies"]`

- [ ] **Step 5: Commit**

```bash
git add .gitignore SECURITY.md .github/CODEOWNERS renovate.json
git commit -m "chore: add repo hygiene and security policy files"
```

---

### Task 2: Security workflows (🤖)

**Files:**
- Create: `scripts/check-sops-encrypted.sh`, `scripts/tests/check-sops-encrypted.test.sh`, `scripts/tests/fixtures/sops/encrypted.yaml`, `scripts/tests/fixtures/sops/plaintext.yaml`
- Create: `.github/workflows/security.yml`, `.github/workflows/scorecard.yml`

**Interfaces:**
- Produces: `scripts/check-sops-encrypted.sh [FILE...]` — ไม่มี argument = ตรวจทุกไฟล์ใน `git ls-files '*.sops.yaml' '*.sops.yml' '*.sops.json'`; exit 0 ถ้าทุกไฟล์เข้ารหัส (หรือไม่มีไฟล์), exit 1 + พิมพ์ `NOT ENCRYPTED: <path>` ต่อไฟล์ที่ไม่ผ่าน. ไฟล์ "เข้ารหัส" = มีบรรทัด `^sops:` **และ** `mac: ENC[`
- Produces: **ชื่อ job ที่ Task 3 ใช้เป็น required checks: `gitleaks`, `zizmor`, `sops-check`** (ห้ามเปลี่ยนชื่อโดยไม่แก้ Ruleset)

- [ ] **Step 1: สร้าง fixtures**
  - `encrypted.yaml`: รูปแบบไฟล์ SOPS จริง — `password: ENC[AES256_GCM,data:...,type:str]` + block `sops:` ที่มี `age:` และ `mac: ENC[AES256_GCM,...]` (ค่าปลอม)
  - `plaintext.yaml`: `password: hunter2` ไม่มี block `sops:`

- [ ] **Step 2: เขียน test** `scripts/tests/check-sops-encrypted.test.sh` (bash, `set -euo pipefail`) ที่ assert:
  - `check-sops-encrypted.sh fixtures/sops/encrypted.yaml` → exit 0
  - `check-sops-encrypted.sh fixtures/sops/plaintext.yaml` → exit 1 และ stdout มี `NOT ENCRYPTED: scripts/tests/fixtures/sops/plaintext.yaml`
  - `check-sops-encrypted.sh encrypted.yaml plaintext.yaml` → exit 1 (ไฟล์เดียวไม่ผ่านก็ fail)
  - ไม่มี argument (repo ยังไม่มีไฟล์ `*.sops.yaml`) → exit 0
  พิมพ์ `PASS`/`FAIL` ต่อ case, exit 1 ถ้ามี FAIL

- [ ] **Step 3: รัน test ให้ fail** — `bash scripts/tests/check-sops-encrypted.test.sh` → Expected: FAIL (script ยังไม่มี)

- [ ] **Step 4: เขียน `scripts/check-sops-encrypted.sh`** (bash + grep, ไม่พึ่ง sops/yq), `chmod +x`

- [ ] **Step 5: รัน test ให้ผ่าน** — Expected: ทุก case `PASS`, exit 0

- [ ] **Step 6: เขียน `.github/workflows/security.yml`**
  - triggers: `pull_request`, `push` (branches: `main`), `schedule` (`0 2 * * 1`), `workflow_dispatch`
  - `permissions: {}`, `concurrency: security-${{ github.ref }}` + `cancel-in-progress: true`
  - job `gitleaks` (`contents: read`): checkout `fetch-depth: 0` → `docker run` image `ghcr.io/gitleaks/gitleaks` (pin ด้วย digest) คำสั่ง `git /repo --redact --verbose` (สแกนทั้ง history)
  - job `zizmor` (`contents: read`): `pipx run zizmor==<pinned version> --format=github .github/workflows`
  - job `sops-check` (`contents: read`): รัน test script แล้วรัน `scripts/check-sops-encrypted.sh`
  - resolve SHA ของ action ด้วย `git ls-remote https://github.com/<owner>/<action> refs/tags/<tag>` (ใช้ SHA ของ commit ไม่ใช่ annotated tag object — ถ้ามี `^{}` ใช้บรรทัดนั้น)

- [ ] **Step 7: เขียน `.github/workflows/scorecard.yml`** ตาม template ของ `ossf/scorecard-action`: triggers `push` main + `schedule` (`0 3 * * 1`) + `branch_protection_rule`; top-level `permissions: read-all`; job ให้ `security-events: write`, `id-token: write`; steps: checkout (`persist-credentials: false`) → `ossf/scorecard-action` (`publish_results: true`) → `github/codeql-action/upload-sarif`. (job นี้จะ fail ขณะ repo ยัง private — คาดไว้แล้ว ไม่ใช่ required check)

- [ ] **Step 8: Commit README + docs + งานของ Task 1–2 แล้วเปิด PR**

```bash
git add scripts .github/workflows README.md docs
git commit -m "ci: add security workflows (gitleaks, zizmor, sops-check, scorecard)"
git push -u origin feat/initial-project-and-planing
gh pr create --base main --title "Phase 0: repo hygiene and security workflows" --body "Phase 0 tasks 1-2: hygiene files + security workflows. See docs/superpowers/plans/2026-11-12-phase-0-repo-and-accounts.md"
gh pr checks --watch
```
Expected: `gitleaks`, `zizmor`, `sops-check` = pass. ถ้า zizmor เตือน → แก้ workflow (ไม่ใช่ปิด rule)

- [ ] **Step 9: 👤 Review + merge PR** (squash) เข้า `main`

---

### Task 3: GitHub settings → เปลี่ยนเป็น public (🤖 รันคำสั่ง, 👤 อนุมัติ)

**Files:**
- Create: `.github/rulesets/main.json` (Ruleset as code — apply ด้วย `gh api`)

**Interfaces:**
- Consumes: ชื่อ job `gitleaks`, `zizmor`, `sops-check` จาก Task 2
- Produces: Environments `plan` และ `production` (ว่าง — Task 4 ใส่ secret)

- [ ] **Step 1: Gate — สแกนทั้ง history บน `main`**: `gh workflow run security.yml --ref main` แล้วดูผล `gitleaks` ต้อง pass. **ถ้า fail หยุดทั้ง task** แล้ว rotate secret ที่เจอก่อน

- [ ] **Step 2: Actions permissions**
  - `PUT repos/bookvt/vaewprach-lab/actions/permissions/workflow`: `default_workflow_permissions=read`, `can_approve_pull_request_reviews=false`
  - `PUT repos/bookvt/vaewprach-lab/actions/permissions`: `enabled=true`, `allowed_actions=all`, `sha_pinning_required=true`

- [ ] **Step 3: Fork PR approval** — `PUT repos/bookvt/vaewprach-lab/actions/permissions/fork-pr-contributor-approval` `approval_policy=all_external_contributors`. ตรวจ: `GET` คืน `all_external_contributors`

- [ ] **Step 4: 👤 ยืนยันแล้วเปลี่ยนเป็น public** — `gh repo edit bookvt/vaewprach-lab --visibility public --accept-visibility-change-consequences`

- [ ] **Step 5: เปิด security features**
  - `PATCH repos/bookvt/vaewprach-lab`: `security_and_analysis.secret_scanning.status=enabled`, `secret_scanning_push_protection.status=enabled`
  - `PUT .../vulnerability-alerts` (Dependabot alerts), `PUT .../private-vulnerability-reporting`
  - `PATCH .../code-scanning/default-setup` `state=configured` (CodeQL — ตอนนี้จะสแกน language `actions`)
  - 👤 ติดตั้ง Renovate GitHub App ให้ repo นี้ → merge onboarding PR

- [ ] **Step 6: Ruleset** — `.github/rulesets/main.json`: target branch `~DEFAULT_BRANCH`, enforcement `active`, rules: `deletion`, `non_fast_forward`, `pull_request` (`required_approving_review_count: 0` — ทำคนเดียว แต่บังคับผ่าน PR), `required_status_checks` (`gitleaks`, `zizmor`, `sops-check`, strict = true); ไม่มี bypass actor. Apply: `gh api -X POST repos/bookvt/vaewprach-lab/rulesets --input .github/rulesets/main.json`

- [ ] **Step 7: ทดสอบ Ruleset จริง**
  - `git push origin HEAD:main` ตรงๆ → Expected: ถูก reject
  - เปิด PR ทดสอบที่เพิ่มไฟล์ `scripts/tests/fixtures/sops/leak.sops.yaml` (plaintext) → Expected: `sops-check` fail และปุ่ม merge ถูก block → ปิด PR ทิ้ง

- [ ] **Step 8: Environments**
  - `plan`: deployment branches = custom policy `*` (ทุก branch ใน repo; fork ไม่ได้รับ environment secrets อยู่แล้ว)
  - `production`: required reviewer `bookvt`, deployment branches = `main` เท่านั้น
  - ตรวจ: `gh api repos/bookvt/vaewprach-lab/environments --jq '.environments[].name'` → `plan`, `production`

- [ ] **Step 9: ตรวจภาพรวม** — `gh api repos/bookvt/vaewprach-lab --jq '{visibility, security_and_analysis}'` → `public`, secret scanning + push protection `enabled`; Scorecard workflow รันผ่านบน `main`

- [ ] **Step 10: Commit ruleset ผ่าน PR** (`chore: add main branch ruleset as code`)

---

### Task 4: Accounts + OCI bootstrap (👤 ทำตาม runbook ที่ 🤖 เขียน)

**Files:**
- Create: `docs/runbooks/oci-bootstrap.md` (ขั้นตอนที่ทำด้วยมือ ห้ามมี OCID/ค่าจริง)

**Interfaces:**
- Produces (ชื่อที่ Phase 1 ใช้):

| ชื่อ | ชนิด | Environment `plan` | Environment `production` |
|---|---|---|---|
| `OCI_REGION` | variable | `ap-singapore-1` | `ap-singapore-1` |
| `OCI_TENANCY_OCID` | secret | ✓ | ✓ |
| `OCI_COMPARTMENT_OCID` | secret | ✓ | ✓ |
| `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY` | secret | ของ `ci-plan` | ของ `ci-apply` |
| `STATE_NAMESPACE` | secret | ✓ | ✓ |
| `STATE_S3_ACCESS_KEY_ID`, `STATE_S3_SECRET_ACCESS_KEY` | secret | Customer Secret Key ของ `ci-plan` | ของ `ci-apply` |
| `TOFU_STATE_PASSPHRASE` | secret | ✓ | ✓ |

- [ ] **Step 1: 🤖 เขียน `docs/runbooks/oci-bootstrap.md`** ครอบคลุม Step 2–6 ด้านล่าง พร้อมคำสั่งตรวจ — commit ผ่าน PR

- [ ] **Step 2: 👤 GitHub account** — เพิ่ม passkey (หรือ security key), ตรวจว่า 2FA เปิด, เก็บ recovery codes ใน password manager

- [ ] **Step 3: 👤 OCI account**
  - สมัคร, home region `ap-singapore-1` (เปลี่ยนภายหลังไม่ได้), เปิด MFA ให้ admin user
  - Upgrade เป็น Pay-As-You-Go → สร้าง Budget $1/เดือนที่ root compartment + alert rule actual spend > 1% ส่งเข้า email
  - เปิด Cloud Guard (Oracle-managed recipes, reporting region `ap-singapore-1`)

- [ ] **Step 4: 👤 Bootstrap identities (Console / Cloud Shell)**
  - Compartments: `vaewprach-lab`, `vaewprach-lab-state`
  - Bucket `tofu-state` ใน `vaewprach-lab-state`: visibility private, **versioning enabled**
  - Groups (identity domain `Default`): `ci-plan`, `ci-apply`; Users: `ci-plan`, `ci-apply` (ไม่มี console password) เข้า group ของตัวเอง
  - Policy (ที่ root, ชื่อ `vaewprach-lab-ci`):
    ```
    Allow group 'Default'/'ci-apply' to manage all-resources in compartment vaewprach-lab
    Allow group 'Default'/'ci-plan' to read all-resources in compartment vaewprach-lab
    Allow group 'Default'/'ci-apply' to read buckets in compartment vaewprach-lab-state
    Allow group 'Default'/'ci-plan' to read buckets in compartment vaewprach-lab-state
    Allow group 'Default'/'ci-apply' to manage objects in compartment vaewprach-lab-state where target.bucket.name = 'tofu-state'
    Allow group 'Default'/'ci-plan' to read objects in compartment vaewprach-lab-state where target.bucket.name = 'tofu-state'
    ```
  - แต่ละ user: API signing key (สร้างใน Cloud Shell ด้วย `openssl`, private key ไม่ออกจาก Cloud Shell นอกจากไปที่ GitHub secret) + Customer Secret Key 1 อัน

- [ ] **Step 5: 👤 ทดสอบ least privilege ใน Cloud Shell** (ตั้ง OCI CLI profile `ci-plan`, `ci-apply`)
  - `oci --profile ci-plan os object list -bn tofu-state` → สำเร็จ (ว่าง)
  - `oci --profile ci-plan os object put -bn tofu-state --file /etc/hostname` → **ต้อง fail** (NotAuthorized)
  - `oci --profile ci-apply os object put -bn tofu-state --file /etc/hostname` → สำเร็จ แล้วลบทิ้ง
  - `oci --profile ci-apply os bucket delete -bn tofu-state` → **ต้อง fail**
  - ลบ API key/profile ออกจาก Cloud Shell หลังทดสอบ

- [ ] **Step 6: 👤 ใส่ credential ลง GitHub Environments** ตามตาราง Interfaces
  - `TOFU_STATE_PASSPHRASE`: สร้างด้วย `openssl rand -base64 32` → **บันทึกลง password manager ก่อน** แล้วค่อยใส่ GitHub
  - ตรวจ: `gh secret list --env plan` และ `--env production` มีครบ 9 ชื่อ, `gh variable list --env plan` มี `OCI_REGION`

---

## Checkpoint จบ Phase 0

- repo `bookvt/vaewprach-lab` เป็น public, push ตรงเข้า `main` ไม่ได้, PR ต้องผ่าน `gitleaks` / `zizmor` / `sops-check`
- secret scanning + push protection + CodeQL + Dependabot alerts + Scorecard ทำงาน
- OCI มี budget alert, Cloud Guard, `ci-plan` (อ่านอย่างเดียว) / `ci-apply` ที่ทดสอบสิทธิ์แล้ว
- GitHub Environments มี credential ครบ → พร้อมเขียน plan ของ Phase 1
