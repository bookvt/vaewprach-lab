#!/usr/bin/env bash
# Fail if any SOPS secret file is not actually encrypted.
#
# Usage: check-sops-encrypted.sh [FILE...]
#   No arguments: checks every tracked *.sops.yaml / *.sops.yml / *.sops.json.
#
# A file counts as encrypted when it has a top-level `sops:` block (YAML) or
# "sops": key (JSON) AND an encrypted MAC (`mac: ENC[` / "mac": "ENC[").
# Exit 0 = all encrypted (or no files); exit 1 = at least one is not.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  cd "$(git rev-parse --show-toplevel)"
  files=()
  while IFS= read -r f; do files+=("$f"); done \
    < <(git ls-files -- '*.sops.yaml' '*.sops.yml' '*.sops.json')
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No SOPS files found."
    exit 0
  fi
  set -- "${files[@]}"
fi

status=0
for f in "$@"; do
  if [[ -f $f ]] \
    && grep -Eq '^(sops:|[[:space:]]*"sops":)' "$f" \
    && grep -Eq '(mac:[[:space:]]*ENC\[|"mac":[[:space:]]*"ENC\[)' "$f"; then
    echo "ok: $f"
  else
    echo "NOT ENCRYPTED: $f"
    status=1
  fi
done
exit $status
