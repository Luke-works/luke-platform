#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# provision-docstore.sh — create + configure ONE AWS S3 document-store bucket for
# the DOCUMENTS layer (luke-core-engine S3DocumentStore). Idempotent: safe to
# re-run; each step is guarded so it converges rather than erroring on re-apply.
#
# Creates / enforces:
#   • bucket with Object Lock ENABLED (no default retention — app sets per-object)
#   • versioning ENABLED (required by Object Lock)
#   • Block Public Access = ALL ON (objects are reached ONLY via the core proxy; never public, never presigned)
#   • default SSE (AES256 / SSE-S3; pass --kms <keyId> for SSE-KMS)
#   • lifecycle: noncurrent + cold tiering to STANDARD_IA→GLACIER, abort stale MPU
#   • NO bucket CORS (the browser never talks to S3 — bytes are proxied through core, DOC-3)
#   • a least-privilege IAM policy scoped to THIS bucket (printed; attach to a
#     user/role you control — this script does NOT mint long-lived keys for you)
#
# Usage:
#   ./provision-docstore.sh --env dev   --bucket luke-docstore-dev
#   ./provision-docstore.sh --env qa    --bucket luke-docstore-qa
#   ./provision-docstore.sh --env prod  --bucket luke-docstore-prod  [--kms <kmsKeyId>]
#
# Flags:
#   --env <dev|qa|prod>   logical env (labels the bucket + IAM policy name)
#   --bucket <name>       globally-unique S3 bucket name
#   --region <r>          default: us-east-2 (matches Render "ohio")
#   --kms <keyId>         optional: use SSE-KMS with this key instead of SSE-S3
#   --profile <p>         optional: AWS CLI profile
#   --dry-run             print the commands without executing
#
# Prereqs: awscli v2, valid creds with S3 + IAM permissions. `aws sts
# get-caller-identity` must succeed before running.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REGION="us-east-2"
KMS_KEY=""
PROFILE=""
DRY=0
ENV=""
BUCKET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)     ENV="$2"; shift 2;;
    --bucket)  BUCKET="$2"; shift 2;;
    --region)  REGION="$2"; shift 2;;
    --kms)     KMS_KEY="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -z "$ENV" || -z "$BUCKET" ]] && { echo "ERROR: --env and --bucket are required" >&2; exit 2; }
[[ "$ENV" =~ ^(dev|qa|prod)$ ]] || { echo "ERROR: --env must be dev|qa|prod" >&2; exit 2; }

AWS=(aws)
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")
AWS+=(--region "$REGION")

run() {
  echo "+ ${AWS[*]} $*"
  [[ "$DRY" -eq 1 ]] && return 0
  "${AWS[@]}" "$@"
}

# NOTE: the bucket is FULLY PRIVATE and the browser NEVER talks to S3 (bytes are proxied + streamed through
# core, DOC-3). So NO bucket CORS is configured here — it isn't needed and leaving it off shrinks attack surface.

echo "==> Identity check"
"${AWS[@]}" sts get-caller-identity >/dev/null || { echo "ERROR: invalid AWS creds" >&2; exit 1; }
ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
echo "    account=$ACCOUNT_ID region=$REGION bucket=$BUCKET env=$ENV"

echo "==> 1/7 create bucket (Object Lock enabled at creation — cannot be added later)"
if "${AWS[@]}" s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "    bucket exists — skipping create (verify Object Lock was enabled at its creation)"
else
  if [[ "$REGION" == "us-east-1" ]]; then
    run s3api create-bucket --bucket "$BUCKET" --object-lock-enabled-for-bucket
  else
    run s3api create-bucket --bucket "$BUCKET" --object-lock-enabled-for-bucket \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
fi

echo "==> 2/7 enable versioning (required by Object Lock)"
run s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

echo "==> 3/7 block ALL public access"
run s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "==> 4/7 default encryption"
if [[ -n "$KMS_KEY" ]]; then
  run s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$KMS_KEY\"},\"BucketKeyEnabled\":true}]}"
else
  run s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
fi

echo "==> 5/7 Object Lock config (ENABLED, NO default retention — app sets per-object retain-until)"
run s3api put-object-lock-configuration --bucket "$BUCKET" \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled"}'

echo "==> 6/7 lifecycle (tier cold objects + noncurrent versions; abort stale multipart uploads)"
run s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [
    { "ID": "tier-cold-current", "Status": "Enabled", "Filter": {"Prefix": ""},
      "Transitions": [ {"Days": 30, "StorageClass": "STANDARD_IA"}, {"Days": 90, "StorageClass": "GLACIER"} ] },
    { "ID": "tier-noncurrent", "Status": "Enabled", "Filter": {"Prefix": ""},
      "NoncurrentVersionTransitions": [ {"NoncurrentDays": 30, "StorageClass": "STANDARD_IA"} ],
      "NoncurrentVersionExpiration": {"NoncurrentDays": 365} },
    { "ID": "abort-incomplete-mpu", "Status": "Enabled", "Filter": {"Prefix": ""},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7} }
  ]
}'

echo "==> 7/7 least-privilege IAM policy (scoped to this bucket) — review + attach to the engine's user/role"
POLICY_NAME="luke-docstore-${ENV}"
POLICY_JSON="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ObjectRW", "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject",
                 "s3:PutObjectRetention","s3:GetObjectRetention","s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::${BUCKET}/*" },
    { "Sid": "BucketList", "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${BUCKET}" }
  ]
}
JSON
)"
echo "$POLICY_JSON" > "/tmp/${POLICY_NAME}.json"
echo "    policy document written to /tmp/${POLICY_NAME}.json"
echo "    Create + attach (run yourself, choosing a user OR an instance role):"
echo "      ${AWS[*]} iam create-policy --policy-name ${POLICY_NAME} --policy-document file:///tmp/${POLICY_NAME}.json"
echo "      # then attach the returned policy ARN to the IAM user/role the engine runs as,"
echo "      # and (for a user) mint an access key for LUKE_DOCSTORE_ACCESS_KEY/SECRET_KEY."

echo
echo "✅ Bucket $BUCKET provisioned. Render env vars for this engine:"
echo "   LUKE_DOCSTORE_PROVIDER=s3"
echo "   LUKE_DOCSTORE_BUCKET=$BUCKET"
echo "   LUKE_DOCSTORE_REGION=$REGION"
[[ -n "$KMS_KEY" ]] && echo "   LUKE_DOCSTORE_KMS_KEY=$KMS_KEY"
echo "   LUKE_DOCSTORE_ACCESS_KEY / LUKE_DOCSTORE_SECRET_KEY  (sync:false — from the IAM user)"
echo "   (then remove the LUKE_DOCSTORE_LOCAL_DIR var + the persistent disk for this service)"
