#!/usr/bin/env bash
# Verifies .gitignore blocks dangerous files and keeps files that must be committed.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
for f in infra/live/terraform.tfstate infra/live/terraform.tfstate.backup infra/live/tfplan \
         infra/live/.terraform/x prod.tfvars .env .env.local kubeconfig x.kubeconfig \
         keys.txt my.agekey oci_api_key.pem bin/x obj/x .DS_Store .idea/x; do
  if git check-ignore -q --no-index "$f"; then echo "PASS ignored: $f"; else echo "FAIL NOT IGNORED: $f"; fail=1; fi
done
for f in infra/live/.terraform.lock.hcl .sops.yaml cluster/x.sops.yaml; do
  if git check-ignore -q --no-index "$f"; then echo "FAIL WRONGLY IGNORED: $f"; fail=1; else echo "PASS tracked: $f"; fi
done
exit $fail
