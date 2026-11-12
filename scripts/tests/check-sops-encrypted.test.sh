#!/usr/bin/env bash
# Tests for scripts/check-sops-encrypted.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
SCRIPT=scripts/check-sops-encrypted.sh
FX=scripts/tests/fixtures/sops
fail=0

# run_case NAME EXPECTED_EXIT [EXPECTED_STDOUT_SUBSTRING] -- ARGS...
run_case() {
  local name=$1 want=$2 needle=$3; shift 4
  local out code=0
  out=$(bash "$SCRIPT" "$@" 2>&1) || code=$?
  if [[ $code -ne $want ]]; then
    echo "FAIL $name: exit $code, want $want"; echo "$out" | sed 's/^/    /'; fail=1; return
  fi
  if [[ -n $needle && $out != *"$needle"* ]]; then
    echo "FAIL $name: output missing '$needle'"; echo "$out" | sed 's/^/    /'; fail=1; return
  fi
  echo "PASS $name"
}

run_case encrypted-file-passes   0 ""                                   -- "$FX/encrypted.yaml"
run_case plaintext-file-fails    1 "NOT ENCRYPTED: $FX/plaintext.yaml"  -- "$FX/plaintext.yaml"
run_case one-bad-file-fails-all  1 "NOT ENCRYPTED: $FX/plaintext.yaml"  -- "$FX/encrypted.yaml" "$FX/plaintext.yaml"
run_case no-args-no-sops-files   0 ""                                   --

# sops: block without an encrypted MAC is not encrypted
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
printf 'password: hunter2\nsops:\n    mac: ""\n' > "$tmp"
run_case sops-block-without-mac  1 "NOT ENCRYPTED: $tmp"                -- "$tmp"

run_case sops-config-is-skipped     0 "skip (sops config): $FX/config/.sops.yaml" -- "$FX/config/.sops.yaml"
run_case plaintext-value-added-fails 1 "NOT ENCRYPTED: $FX/partially-plaintext.yaml" -- "$FX/partially-plaintext.yaml"
run_case nested-plaintext-fails      1 "NOT ENCRYPTED: $FX/nested-plaintext.yaml"    -- "$FX/nested-plaintext.yaml"

run_case missing-file-fails      1 "NOT ENCRYPTED: does/not/exist.yaml" -- does/not/exist.yaml

exit $fail
