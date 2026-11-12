#!/usr/bin/env bash
# Verify ci-plan / ci-apply have exactly the intended rights. Run in OCI Cloud Shell.
#
# Expects ~/ci-secrets/{ci-plan,ci-apply}.{user,fingerprint,pem,s3.json}
# (created by docs/runbooks/oci-bootstrap.md §4). Prints PASS/FAIL per check.
#
# Every command runs as the CI user via --auth api_key (Cloud Shell otherwise
# runs as the logged-in admin). "CANNOT" checks are chosen so that, if they did
# run as admin, they would only create a harmless probe resource — never delete.
set -uo pipefail
D=${CI_SECRETS_DIR:-$HOME/ci-secrets}
R=${OCI_REGION:-ap-singapore-1}
T=${OCI_TENANCY:?run in OCI Cloud Shell (OCI_TENANCY not set)}
cd "$D" || exit 1

NS=$(oci os ns get --query data --raw-output)
LAB_C=$(oci iam compartment list --compartment-id "$T" --name vaewprach-lab --query 'data[0].id' --raw-output)
for N in ci-plan ci-apply; do
  printf '[%s]\nuser=%s\nfingerprint=%s\nkey_file=%s\ntenancy=%s\nregion=%s\n\n' \
    "$N" "$(cat $N.user)" "$(cat $N.fingerprint)" "$D/$N.pem" "$T" "$R"
done > ci-test.config
chmod 600 ci-test.config

ci() { local p=$1; shift; OCI_CLI_AUTH=api_key oci --auth api_key --config-file "$D/ci-test.config" --profile "$p" "$@"; }
fails=0
check() {
  local want=$1 name=$2 got; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=fail; fi
  if [ "$got" = "$want" ]; then echo "PASS  $name"; else echo "FAIL  $name (got $got, want $want)"; fails=1; fi
}

echo "== identity"
check ok   "ci-plan  api key works"             ci ci-plan  os ns get
check ok   "ci-apply api key works"             ci ci-apply os ns get
echo "== state bucket"
check ok   "ci-plan  can list tofu-state"       ci ci-plan  os object list -bn tofu-state
check fail "ci-plan  CANNOT write tofu-state"   ci ci-plan  os object put -bn tofu-state --file /etc/hostname --name probe --force
check ok   "ci-apply can write tofu-state"      ci ci-apply os object put -bn tofu-state --file /etc/hostname --name probe --force
check ok   "ci-apply can delete its object"     ci ci-apply os object delete -bn tofu-state --object-name probe --force
echo "== scope"
check fail "ci-plan  CANNOT create in lab"      ci ci-plan  os bucket create --compartment-id "$LAB_C" --name probe-plan
check fail "ci-apply CANNOT create policy@root" ci ci-apply iam policy create --compartment-id "$T" --name probe --description probe --statements '["Allow group Administrators to read buckets in tenancy"]'
check fail "ci-apply CANNOT create in root"     ci ci-apply os bucket create --compartment-id "$T" --name probe-root
echo "== S3 compat keys (new keys can take ~10 min to work)"
for N in ci-plan ci-apply; do
  s=$(python3 "$(dirname "$0")/s3-probe.py" "$N.s3.json" "$NS" "$R" 2>&1 | head -c 80)
  if [ "${s%% *}" = "200" ]; then echo "PASS  $N S3 list"; else echo "FAIL  $N S3 list ($s)"; fails=1; fi
done
rm -f ci-test.config
exit $fails
