#!/usr/bin/env bash
# Fail if any SOPS secret file is not actually encrypted.
#
# Usage: check-sops-encrypted.sh [FILE...]
#   No arguments: checks every tracked *.sops.yaml / *.sops.yml / *.sops.json.
#
# A file counts as encrypted when it has a top-level `sops:` block (YAML) or
# "sops": key (JSON) AND an encrypted MAC (`mac: ENC[` / "mac": "ENC[").
# YAML files are also checked leaf by leaf: every scalar outside the `sops:`
# block must be `ENC[...]` unless its key ends in `_unencrypted` — this catches
# plaintext added to an encrypted file by hand. JSON gets the structural check only.
# `.sops.yaml` (SOPS creation-rules config) is skipped: it is not a secret file.
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

# Print every plaintext leaf of a SOPS YAML file (outside the sops: block).
plaintext_yaml_leaves() {
  awk '
    /^sops:/                 { in_sops = 1; next }
    in_sops && /^[^ \t#]/    { in_sops = 0 }
    in_sops                  { next }
    /^[ \t]*(#|$)/ || /^---/ { next }
    {
      line = $0
      sub(/^[ \t]*/, "", line)
      sub(/^- */, "", line)
      val = line
      if (match(line, /^[^:]*:([ \t]|$)/)) {
        key = substr(line, 1, RLENGTH); sub(/:[ \t]*$/, "", key)
        val = substr(line, RLENGTH + 1); sub(/^[ \t]*/, "", val)
        if (key ~ /_unencrypted$/ || val == "") next
      }
      if (val !~ /^ENC\[/) print FILENAME ":" NR
    }' "$1"
}

status=0
for f in "$@"; do
  if [[ $(basename "$f") == .sops.yaml ]]; then
    echo "skip (sops config): $f"
    continue
  fi
  if [[ -f $f ]] \
    && grep -Eq '^(sops:|[[:space:]]*"sops":)' "$f" \
    && grep -Eq '(mac:[[:space:]]*ENC\[|"mac":[[:space:]]*"ENC\[)' "$f" \
    && { [[ $f == *.json ]] || [[ -z $(plaintext_yaml_leaves "$f") ]]; }; then
    echo "ok: $f"
  else
    echo "NOT ENCRYPTED: $f"
    status=1
  fi
done
exit $status
