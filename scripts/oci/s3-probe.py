#!/usr/bin/env python3
"""List the tofu-state bucket through the OCI S3-compatible API (SigV4, stdlib only).

Usage: s3-probe.py CRED_JSON NAMESPACE REGION
  CRED_JSON: {"id": "<access key id>", "key": "<secret key>"}  (output of
             `oci iam customer-secret-key create --query 'data.{id:id,key:key}'`)
Prints the HTTP status (200 = keys work) or the status + start of the error body.
Cloud Shell's curl lacks --aws-sigv4, hence this script.
"""
import datetime
import hashlib
import hmac
import json
import sys
import urllib.error
import urllib.request

cred, ns, region = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cred) as f:
    c = json.load(f)
ak, sk = c["id"], c["key"]

host = f"{ns}.compat.objectstorage.{region}.oraclecloud.com"
now = datetime.datetime.now(datetime.timezone.utc)
amz, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
payload_hash = hashlib.sha256(b"").hexdigest()
signed = "host;x-amz-content-sha256;x-amz-date"
canonical = (
    f"GET\n/tofu-state\nlist-type=2\n"
    f"host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz}\n\n"
    f"{signed}\n{payload_hash}"
)
scope = f"{day}/{region}/s3/aws4_request"
to_sign = f"AWS4-HMAC-SHA256\n{amz}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
k = ("AWS4" + sk).encode()
for part in (day, region, "s3", "aws4_request"):
    k = hmac.new(k, part.encode(), hashlib.sha256).digest()
sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()

req = urllib.request.Request(
    f"https://{host}/tofu-state?list-type=2",
    headers={
        "x-amz-date": amz,
        "x-amz-content-sha256": payload_hash,
        "Authorization": f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, SignedHeaders={signed}, Signature={sig}",
    },
)
try:
    print(urllib.request.urlopen(req, timeout=15).status)
except urllib.error.HTTPError as e:
    print(e.code, e.read()[:200].decode(errors="replace"))
