# Phase 1 — Foundation (OpenTofu) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** สร้าง infra บน OCI Always Free ทั้งหมดผ่าน OpenTofu ที่รันใน GitHub Actions — network, 3 × A1 VM (ไม่มี public IP), Network Load Balancer, DuckDNS — โดย state เข้ารหัสใน bucket `tofu-state` และ rebuild ได้จาก CI

**Architecture:** root module `infra/live` เรียก module `network` → `k3s-cluster` → `load-balancer`. PR: lint + `tofu plan` ด้วย `ci-plan` (read-only, `-lock=false`) แล้ว comment เฉพาะสรุป; merge เข้า `main`: `plan` + `apply` ด้วย `ci-apply` ผ่าน Environment `production` (ต้อง approve). log ของ tofu ไม่ถูกพิมพ์ดิบ — ผ่าน redaction (OCID, IP) ก่อนเสมอ. แต่ละ module มี `tofu test` + `mock_provider` เป็น TDD gate

**Tech Stack:** OpenTofu 1.13.x, OCI provider 9.x, tflint 0.66.x, Trivy (docker image pin ด้วย digest), GitHub Actions, bash + jq, DuckDNS

**Spec:** [`README.md`](../../../README.md) (Infrastructure บน OCI, CI/CD, Security) · ลำดับ: [`2026-11-12-roadmap.md`](2026-11-12-roadmap.md) Phase 1 · runbook: [`docs/runbooks/oci-bootstrap.md`](../../runbooks/oci-bootstrap.md)

## Global Constraints

- OpenTofu `1.13.x` (`required_version = "~> 1.13.0"`), provider `oracle/oci` `~> 9.13` — ล็อกใน `infra/live/.terraform.lock.hcl` (commit, ครบทั้ง `linux_amd64` และ `linux_arm64`)
- เวอร์ชันของ action / image ทุกตัวต้องออกมาแล้ว ≥ 3 วัน (สอดคล้อง Renovate `minimumReleaseAge`); action pin full SHA + `# vX.Y.Z`; image pin `tag@sha256:`
- **ห้ามใช้ `aquasecurity/trivy-action` / `setup-trivy`** (เคยถูก compromise) — รัน `aquasec/trivy` image ด้วย digest
- ทุก workflow: `permissions: {}` แล้วให้ราย job, `persist-credentials: false`, ห้าม `pull_request_target` / `workflow_run`, มี `step-security/harden-runner` (`egress-policy: audit`) เป็น step แรก
- Region `ap-singapore-1`; ทุก resource อยู่ใน compartment `vaewprach-lab` และมี `freeform_tags = { project = "vaewprach-lab" }`
- **Always Free เท่านั้น:** shape `VM.Standard.A1.Flex` ล้วน, รวม ≤ 4 OCPU / ≤ 24 GB / boot ≤ 200 GB, NLB 1 ตัว — บังคับด้วย variable validation + `tofu test`
- Node: ไม่มี public IP, ไม่มี SSH key, ไม่มี console password (Phase 2 ค่อยเพิ่ม Bastion)
- **ห้ามให้ OCID, tenancy namespace, IP ของ node, หรือค่าลับปรากฏใน log / PR comment / artifact** (README "ห้าม public") — ทุก output ของ `tofu` ไปที่ไฟล์ก่อนแล้วผ่าน `scripts/redact.sh`; ห้าม upload state/plan เป็น artifact
- Credential: ใช้ชื่อ secret ตาม runbook §6 เท่านั้น (`OCI_*`, `STATE_*`, `TOFU_STATE_PASSPHRASE`, variable `OCI_REGION`)
- PR plan รันด้วย `-lock=false` (ci-plan เขียน lock ไม่ได้ — ตั้งใจ); apply รันแบบมี lock + `concurrency: infra` (`cancel-in-progress: false`)
- เครื่อง executor ไม่มี cloud credential: `tofu fmt/validate/test` รันในเครื่องได้ผ่าน image `ghcr.io/opentofu/opentofu` แต่ `plan/apply` จริงเกิดใน CI เท่านั้น (หลักการ Cloud only)

## Review Focus

1. **OCID / IP รั่วใน log ของ CI** — `tofu plan` พิมพ์ `Refreshing state... [id=ocid1...]` และค่า attribute ที่เปลี่ยน ⇒ ต้องผ่าน `redact.sh` เสมอ รวมถึงตอน error (Task 2 tests + Task 3 Step ตรวจ log จริง)
2. **Environment `plan` อาจไม่ให้ job ของ PR ใช้** — deployment branch policy `*` ถูกเทียบกับ ref ของ PR ซึ่งอาจเป็น `refs/pull/N/merge` (Task 3 Step 1 ทดสอบจริง; แก้เป็นนโยบายที่ตรง ถ้าไม่ผ่าน)
3. **S3 backend บน OCI ไม่รองรับ native lock (`use_lockfile`)** — OCI S3 compat อาจไม่รองรับ conditional write (Task 1/3 ตรวจ; fallback = ปิด lockfile แล้วพึ่ง `concurrency: infra` + ADR)
4. **Image ของ Ubuntu ออกใหม่ → VM ถูก replace ทั้ง cluster** — data source หา image ล่าสุดทุกครั้ง ต้อง `ignore_changes` ที่ `source_details` (Task 6 test)
5. **tflint ไม่เข้าใจ syntax เฉพาะ OpenTofu (`encryption` block)** — Task 3 ตรวจ; fallback = ส่ง encryption ผ่าน env `TF_ENCRYPTION` แทน block ใน code (ledger ruling)
6. **A1 "Out of capacity"** — apply fail กลางทาง; apply ซ้ำต้อง idempotent ไม่สร้างซ้ำ (Task 6 Step apply)
7. **NLB preserve source IP** — client IP ต้องถึง Traefik (ใช้ rate limit ใน Phase 3/7) ⇒ `is_preserve_source = true` และ NSG ของ worker เปิด NodePort จาก `0.0.0.0/0` ได้เพราะ subnet เป็น private (ไม่มี route ขาเข้าจาก internet นอกจากผ่าน NLB) — ต้องมี test ว่า node ไม่มี public IP และ private subnet ไม่มี Internet Gateway route

---

### Task 1: Root module skeleton — provider, backend, state encryption (🤖)

**Files:**
- Create: `infra/live/versions.tf`, `infra/live/backend.tf`, `infra/live/encryption.tf`, `infra/live/providers.tf`, `infra/live/variables.tf`, `infra/live/main.tf` (ว่าง + comment), `infra/live/outputs.tf`, `infra/live/.terraform.lock.hcl`, `infra/live/tests/skeleton.tftest.hcl`, `.tflint.hcl`

**Interfaces:**
- Produces (variables ที่ CI ส่งผ่าน `TF_VAR_*`):

| variable | sensitive | มาจาก |
|---|---|---|
| `tenancy_ocid` | ✓ | `OCI_TENANCY_OCID` |
| `compartment_ocid` | ✓ | `OCI_COMPARTMENT_OCID` |
| `user_ocid`, `fingerprint`, `private_key` | ✓ | `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY` |
| `region` | | `OCI_REGION` (default `ap-singapore-1`) |
| `state_passphrase` | ✓ | `TOFU_STATE_PASSPHRASE` |

- Produces (env ที่ backend ใช้): `AWS_ACCESS_KEY_ID` ← `STATE_S3_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` ← `STATE_S3_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3` = `https://<STATE_NAMESPACE>.compat.objectstorage.<region>.oraclecloud.com`
- Produces: `locals.common_tags = { project = "vaewprach-lab" }` ใน `main.tf`

- [ ] **Step 1: เขียน test ที่ fail** — `infra/live/tests/skeleton.tftest.hcl` ใช้ `mock_provider "oci" {}` แล้ว `run "plan" { command = plan }` ตั้ง variables ปลอม และ assert `local.common_tags.project == "vaewprach-lab"`; อีก run ที่ใส่ `region = "us-ashburn-1"` ต้อง `expect_failures = [var.region]`
- [ ] **Step 2: รันให้ fail** — `docker run --rm -v "$PWD/infra/live:/w" -w /w ghcr.io/opentofu/opentofu:<pinned> test` → Expected: fail (ยังไม่มี config)
- [ ] **Step 3: เขียน config**
  - `versions.tf`: `required_version`, `required_providers.oci`
  - `backend.tf`: `backend "s3"` — `bucket = "tofu-state"`, `key = "live/terraform.tfstate"`, `region = "ap-singapore-1"`, `use_path_style = true`, `use_lockfile = true`, `skip_region_validation`, `skip_credentials_validation`, `skip_requesting_account_id`, `skip_metadata_api_check`, `skip_s3_checksum` = true. **ไม่มี** endpoint/namespace ใน code (มาจาก env)
  - `encryption.tf`: `key_provider "pbkdf2" "main" { passphrase = var.state_passphrase }`, `method "aes_gcm" "main"`, `state { enforced = true }`, `plan { enforced = true }`
  - `variables.tf`: ตามตาราง Interfaces; `region` มี validation ต้องเป็น `ap-singapore-1`
  - `.tflint.hcl`: plugin `terraform` preset `recommended`
- [ ] **Step 4: รัน test ให้ผ่าน + `tofu fmt -check -recursive` + `tofu validate`** (`init -backend=false`) → Expected: PASS
- [ ] **Step 5: สร้าง lock file หลาย platform** — `tofu providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64`
- [ ] **Step 6: Commit** — `feat(infra): add root module skeleton with encrypted S3 backend`

---

### Task 2: Log safety — `redact.sh` + `plan-summary.sh` (🤖)

**Files:**
- Create: `scripts/redact.sh`, `scripts/plan-summary.sh`, `scripts/tests/redact.test.sh`, `scripts/tests/plan-summary.test.sh`, `scripts/tests/fixtures/plan/{create.json,nochange.json,mixed.json}`

**Interfaces:**
- Produces: `redact.sh` — stdin → stdout; แทน `ocid1\.[a-z0-9_.-]+` ด้วย `<ocid>`, IPv4 ทุกตัว **ยกเว้น** `0.0.0.0` และ CIDR ในช่วง `10.0.0.0/8` ที่ประกาศใน code ด้วย `<ip>`, namespace (ค่าจาก env `STATE_NAMESPACE` ถ้ามี) ด้วย `<namespace>`
- Produces: `plan-summary.sh PLAN_JSON` — stdout เป็น markdown: บรรทัด `Plan: N to add, N to change, N to destroy` (หรือ `No changes.`) + ตาราง `| action | address |` เรียงตาม address; **ไม่พิมพ์ attribute ใด ๆ**; exit 2 ถ้ามี `delete` ของ `oci_core_instance` (ให้ CI ติดป้ายเตือน)

- [ ] **Step 1: เขียน test ที่ fail** — `redact.test.sh` assert: `ocid1.instance.oc1.ap-singapore-1.abc` → `<ocid>`; `129.150.1.2` → `<ip>`; `10.0.1.0/24` คงเดิม; `0.0.0.0/0` คงเดิม; ค่า `STATE_NAMESPACE=ax1b2c` ในข้อความ → `<namespace>`. `plan-summary.test.sh` assert ผลของ 3 fixtures (create = `Plan: 3 to add, 0 to change, 0 to destroy`; nochange = `No changes.`; mixed มี replace instance → exit 2) และ output ไม่มีสตริง `ocid1` หรือ IP ใด ๆ จาก fixture
- [ ] **Step 2: รันให้ fail** (script ยังไม่มี)
- [ ] **Step 3: เขียน script** (bash + `jq` + `sed -E`; bash 3.2 compatible)
- [ ] **Step 4: รันให้ผ่าน** และเพิ่มทั้งสอง test เข้า job `sops-check` ใน `security.yml` (เปลี่ยนชื่อ step เป็น "script tests" — **ไม่เปลี่ยนชื่อ job**)
- [ ] **Step 5: Commit** — `feat(ci): add log redaction and plan summary scripts`

---

### Task 3: `infra.yml` workflow + first PR plan = "No changes" (🤖, 👤 approve)

**Files:**
- Create: `.github/workflows/infra.yml`
- Modify: `README.md` (Repo structure ถ้าต่างจากจริง)

**Interfaces:**
- Consumes: Task 1 variables/env, Task 2 scripts
- Produces: job ids `lint`, `plan`, `apply` (ไม่ใช่ required check — มี `paths` filter); `workflow_dispatch` input `action` = `apply` | `destroy` (default `apply`)

- [ ] **Step 1: ทดสอบ Environment `plan` กับ PR ก่อน** — workflow ทดลองบน branch นี้ที่มี job `environment: plan` แค่ `echo ok` → เปิด PR → Expected: job รันได้ (ไม่ติด "branch is not allowed to deploy"). ถ้าติด: เปลี่ยน branch policy ของ `plan` ให้ตรง (ทดสอบ `**` ก่อน) แล้ว ledger ruling
- [ ] **Step 2: เขียน `infra.yml`**
  - triggers: `pull_request` + `push: main` (paths: `infra/**`, `.github/workflows/infra.yml`, `scripts/redact.sh`, `scripts/plan-summary.sh`), `workflow_dispatch`
  - `concurrency: { group: infra, cancel-in-progress: false }`
  - job `lint` (`contents: read`, ไม่มี secret): `tofu fmt -check -recursive infra`, `tofu init -backend=false` + `validate`, `tofu test` ทุก module, `tflint --recursive`, Trivy `config infra --exit-code 1 --severity HIGH,CRITICAL` (image digest)
  - job `plan` (PR เท่านั้น, `if: github.event.pull_request.head.repo.full_name == github.repository`, `environment: plan`, `contents: read`, `pull-requests: write`): `init` → `plan -lock=false -concise -no-color -out=tfplan > plan.log 2>&1`; ไม่ว่าผลเป็นอะไร `redact.sh < plan.log` ลง log; `tofu show -json tfplan | plan-summary.sh` → `gh pr comment --edit-last || gh pr comment` (comment เดียวต่อ PR)
  - job `apply` (`push` main หรือ `workflow_dispatch`, `environment: production`, `contents: read`): `init` → `plan`/`plan -destroy` → `apply tfplan` — ทุก output ผ่าน `redact.sh`
  - ตั้ง env ตาม Task 1 Interfaces ระดับ job (ไม่ใช่ workflow) และ `echo "::add-mask::$STATE_NAMESPACE"` ก่อนคำสั่งแรก
- [ ] **Step 3: zizmor + gitleaks ผ่านใน PR** (`docker run ... zizmor`)
- [ ] **Step 4: เปิด PR** → Expected: `lint` ผ่าน, `plan` ผ่าน, comment = `No changes.`; เปิด log ของ job `plan` แล้ว `grep -E 'ocid1|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'` ต้องไม่เจอ (ยกเว้น `<ip>`/`<ocid>`)
- [ ] **Step 5: 👤 merge + approve `production`** → Expected: `apply` ผ่าน (0 resources) และ state object `live/terraform.tfstate` ถูกสร้าง
- [ ] **Step 6: 👤 ยืนยันว่า state ถูกเข้ารหัส** (Cloud Shell, admin): `oci os object get -bn tofu-state --name live/terraform.tfstate --file - | head -c 300` → Expected: JSON ที่มี `"encrypted_data"` และไม่มี `"resources"`. ตรวจว่ามี lock object หรือไม่ระหว่าง apply (Review Focus #3) — ถ้า `use_lockfile` error ให้ปิดแล้วเขียน ADR สั้น
- [ ] **Step 7: Commit** ผ่าน PR — `ci(infra): add plan/apply workflow`

---

### Task 4: OIDC spike → ADR 0001 (🤖👤, time-box 2 ชม.)

**Files:**
- Create: `docs/adr/0001-ci-authentication-to-oci.md`

**Interfaces:**
- Produces: การตัดสินใจ `api-key` (ปัจจุบัน) หรือ `oidc` — ถ้า `oidc` ได้ จะเป็น task แยกใน Phase 1.x ที่ย้าย `plan`/`apply` ไปใช้ `auth = "SecurityToken"`; Phase นี้ **ไม่เปลี่ยน** workflow

- [ ] **Step 1: 🤖 ค้น primary source** — OCI Identity Domains token exchange (JWT → UPST) กับ GitHub Actions OIDC (`token.actions.githubusercontent.com`), สิ่งที่ต้องตั้งใน domain (Identity Propagation Trust), การผูก subject (`repo:bookvt/vaewprach-lab:environment:production`) และวิธีที่ provider ใช้ token (`SecurityToken`)
- [ ] **Step 2: 🤖👤 ทดลองจริงด้วย workflow_dispatch แยก** (ไม่แตะ `infra.yml`) — สำเร็จ = `oci os ns get` ผ่านด้วย UPST โดยไม่มี API key
- [ ] **Step 3: เขียน ADR** (Context / Options / Decision / Consequences) — ถ้าไม่สำเร็จภายใน time-box: Decision = API key + rotate 90 วัน พร้อมเหตุผลที่ติด
- [ ] **Step 4: Commit** ผ่าน PR — `docs(adr): decide CI authentication to OCI`

---

### Task 5: Module `network` (🤖)

**Files:**
- Create: `infra/modules/network/{main.tf,variables.tf,outputs.tf,versions.tf}`, `infra/modules/network/tests/network.tftest.hcl`
- Modify: `infra/live/main.tf`

**Interfaces:**
- Consumes: `compartment_ocid`, `common_tags`
- Produces: `module.network` outputs `vcn_id`, `public_subnet_id`, `private_subnet_id`, `nsg_cluster_id`, `nsg_nlb_id`, `private_subnet_cidr` (`10.0.1.0/24`), `public_subnet_cidr` (`10.0.0.0/24`)

- [ ] **Step 1: เขียน test ที่ fail** (`mock_provider`) assert:
  - VCN `10.0.0.0/16`; public subnet `10.0.0.0/24` (`prohibit_public_ip_on_vnic = false`); private subnet `10.0.1.0/24` (`prohibit_public_ip_on_vnic = true`)
  - route table ของ private subnet มีแค่ NAT (`0.0.0.0/0`) + Service Gateway — **ไม่มี** Internet Gateway
  - NSG `cluster`: ingress ภายใน NSG เดียวกันเฉพาะ `6443/tcp`, `10250/tcp`, `8472/udp`; ingress `30080/tcp`, `30443/tcp` จาก `0.0.0.0/0` (Review Focus #7); ไม่มี ingress `22`
  - NSG `nlb`: ingress `80/tcp`, `443/tcp` จาก `0.0.0.0/0`
  - default security list ของ VCN ไม่มี ingress rule
- [ ] **Step 2: รันให้ fail**
- [ ] **Step 3: เขียน module** + เรียกใน `infra/live/main.tf`
- [ ] **Step 4: รัน test ให้ผ่าน + lint**
- [ ] **Step 5: PR → plan comment** แสดง add เฉพาะ network resources → 👤 merge + approve → **ยืนยัน NAT Gateway สร้างได้ใน Always Free** (ถ้าไม่ได้: หยุด, ledger + ถามก่อนใช้ fallback "node ใน public subnet + NSG ปิดขาเข้า" ตาม README)
- [ ] **Step 6: Commit** — `feat(infra): add network module`

---

### Task 6: Module `k3s-cluster` — 3 × A1 VM (🤖, 👤 approve)

**Files:**
- Create: `infra/modules/k3s-cluster/{main.tf,variables.tf,outputs.tf,versions.tf,cloud-init/base.yaml}`, `infra/modules/k3s-cluster/tests/cluster.tftest.hcl`
- Modify: `infra/live/main.tf`

**Interfaces:**
- Consumes: `private_subnet_id`, `nsg_cluster_id`, `compartment_ocid`, `common_tags`
- Produces: variable `nodes = map(object({ ocpus = number, memory_gb = number, boot_gb = number, role = string }))` ค่า default ตาม README (`k3s-server` 1/6/60 server, `k3s-worker-1|2` 1.5/9/60 worker); outputs `worker_instance_ids` (map), `server_instance_id`, `node_private_ips` (sensitive)

- [ ] **Step 1: เขียน test ที่ fail** assert:
  - ทุก instance: shape `VM.Standard.A1.Flex`, `assign_public_ip = false`, ไม่มี `ssh_authorized_keys` ใน metadata, มี `user_data`
  - validation ของ `nodes`: รวม OCPU > 4 → fail; memory > 24 → fail; boot > 200 → fail; shape อื่น → fail (`expect_failures`)
  - image มาจาก data source Ubuntu 24.04 aarch64 และ instance มี `lifecycle.ignore_changes` ครอบ `source_details` + `metadata["user_data"]` (Review Focus #4 — ทดสอบด้วยการเปลี่ยน mock image id แล้ว plan ต้องไม่ replace; ถ้า `tofu test` ทดสอบ lifecycle ไม่ได้ ให้ตรวจด้วย `grep` ใน test script แล้ว ledger ruling)
- [ ] **Step 2: รันให้ fail**
- [ ] **Step 3: เขียน module** — cloud-init `base.yaml`: `package_update: true`, `package_upgrade: true`, `ssh_pwauth: false`, `disable_root: true`; ไม่มีการติดตั้ง K3s (Phase 2)
- [ ] **Step 4: รัน test ให้ผ่าน + lint**
- [ ] **Step 5: PR → plan comment** = add 3 instances (+ data) → 👤 merge + approve. ถ้า `Out of host capacity`: rerun `apply` (Actions → Re-run failed jobs) — Expected: รอบหลังสร้างเฉพาะตัวที่ขาด ไม่ซ้ำ
- [ ] **Step 6: 👤 ยืนยัน** (Console หรือ Cloud Shell): instance 3 ตัว `RUNNING`, ไม่มี public IP (`oci compute instance list-vnics ... --query 'data[].\"public-ip\"'` → ว่าง)
- [ ] **Step 7: Commit** — `feat(infra): add k3s-cluster VMs`

---

### Task 7: Module `load-balancer` + DuckDNS (🤖, 👤 สมัคร DuckDNS)

**Files:**
- Create: `infra/modules/load-balancer/{main.tf,variables.tf,outputs.tf,versions.tf}`, `infra/modules/load-balancer/tests/nlb.tftest.hcl`
- Modify: `infra/live/main.tf`, `infra/live/outputs.tf`, `.github/workflows/infra.yml`, `docs/runbooks/oci-bootstrap.md` (เพิ่มหัวข้อ DuckDNS)

**Interfaces:**
- Consumes: `public_subnet_id`, `nsg_nlb_id`, `worker_instance_ids`
- Produces: output `nlb_public_ip` (ไม่ sensitive — เป็น IP สาธารณะที่ DNS ประกาศอยู่แล้ว); NodePort `30080` (http) / `30443` (https) — **Phase 3 ต้องตั้ง Traefik ให้ตรง**; GitHub secret `DUCKDNS_TOKEN` ใน Environment `production`, domain `vaewlab`

- [ ] **Step 1: 👤 สมัคร DuckDNS** (login ด้วย GitHub) → สร้าง subdomain `vaewlab` → `gh secret set DUCKDNS_TOKEN --env production` (เพิ่มขั้นตอนใน runbook)
- [ ] **Step 2: เขียน test ที่ fail** assert: NLB `is_private = false` ใน public subnet + `nsg_nlb_id`; listener `80→30080`, `443→30443` TCP; backend set ละ 2 backend (worker เท่านั้น ไม่มี server); health check TCP; `is_preserve_source = true`
- [ ] **Step 3: รันให้ fail → เขียน module → รันให้ผ่าน + lint**
- [ ] **Step 4: เพิ่ม step ใน job `apply`** (หลัง apply สำเร็จ): `IP=$(tofu output -raw nlb_public_ip)` → `curl -fsS "https://www.duckdns.org/update?domains=vaewlab&token=${DUCKDNS_TOKEN}&ip=${IP}"` ต้องตอบ `OK` (token ส่งผ่าน env, ห้าม `set -x`)
- [ ] **Step 5: PR → merge → approve** → Expected: `dig +short vaewlab.duckdns.org` = IP ของ NLB; NLB health = critical (ยังไม่มี Traefik — คาดไว้)
- [ ] **Step 6: Commit** — `feat(infra): add network load balancer and DuckDNS update`

---

### Task 8: Rebuild test — checkpoint จบ Phase 1 (👤 approve)

- [ ] **Step 1:** Actions → `infra` → Run workflow `action=destroy` → approve → Expected: 0 resources (bucket `tofu-state` ไม่ถูกแตะ — อยู่นอก state)
- [ ] **Step 2:** Run workflow `action=apply` → approve → Expected: สร้างครบ, DuckDNS ชี้ IP ใหม่
- [ ] **Step 3:** ปิด Phase 1 — อัปเดต roadmap (✅ Phase 1) + ledger; เขียน plan Phase 2

## Checkpoint จบ Phase 1

- `tofu destroy` แล้ว `apply` จาก CI ได้ครบ (rebuild test)
- PR ทุกอันที่แตะ `infra/` ได้ plan summary เป็น comment และ log ไม่มี OCID/IP
- 3 VM ไม่มี public IP, NLB รับ 80/443, `vaewlab.duckdns.org` ชี้ NLB
- ADR 0001 บันทึกวิธี CI auth
