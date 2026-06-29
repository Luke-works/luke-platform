# S3 document store — provisioning (DOC-10)

Provisions the AWS S3 bucket(s) backing the **DOCUMENTS** layer (`luke-core-engine`
`S3DocumentStore`). Bytes for signatures, email attachments, and form file fields live here;
core keeps only tenant-isolated metadata. **The browser never talks to S3** — bytes are **proxied
and streamed through the auth gateway → core** (`POST /api/documents`, `GET /api/documents/{id}/content`);
no bucket/region/key/signature ever reaches the client. Bytes never touch Postgres or Camunda. See
`DOCUMENTS_V1_BACKLOG.md` (luke-core-engine).

## Design decisions
- **One bucket per env** (`luke-docstore-dev` / `-qa` / `-prod`) — *not* a shared bucket with
  prefixes. Object Lock **COMPLIANCE** mode (signed PDFs) is irreversible; isolating envs prevents
  a dev object from ever landing under a multi-year compliance lock next to prod data, and keeps
  IAM / lifecycle / blast-radius separate. (Deliberately unlike the shared-Postgres-with-schemas model.)
- **Object Lock enabled, no _default_ retention.** The app sets a per-object `retain-until` only on
  signature objects (DOC-5, COMPLIANCE), so form/email attachments are not force-locked.
- **Block Public Access = ALL on, and NO bucket CORS.** Objects are reached only by core streaming
  them server-side *after* a tenant + capability authZ check (DOC-3/DOC-4). The browser never hits the
  bucket, so CORS is unnecessary — omitting it shrinks the attack surface.
- **Region `us-east-2`** = Render `ohio`. Same region → no cross-region egress engine↔bucket.
- **Default SSE-S3 (AES256).** Pass `--kms <keyId>` for SSE-KMS (per-tenant KMS keys are OUT of V1).
- Within a bucket, the key layout is `{tenantId}/{processRef}/{docId}-{file}` (process-centric case
  file) — defense-in-depth only; the engine's authZ check is the real gate.

## Prerequisites
- AWS CLI v2 + valid creds: `aws sts get-caller-identity` must succeed.
- Permissions to create S3 buckets + IAM policies in the target account.

## Provision a bucket
```bash
cd infra/s3
./provision-docstore.sh --env dev   --bucket luke-docstore-dev
./provision-docstore.sh --env qa    --bucket luke-docstore-qa
./provision-docstore.sh --env prod  --bucket luke-docstore-prod          # optionally: --kms <kmsKeyId>
```
Add `--dry-run` to preview every command without executing. The script is idempotent — re-running
converges configuration. **Object Lock can only be enabled at bucket creation**, so a pre-existing
bucket created without it must be recreated.

The script configures the bucket (versioning, public-access-block, SSE, Object Lock, lifecycle)
and writes a least-privilege IAM policy doc to `/tmp/luke-docstore-<env>.json`. It does **not**
mint long-lived keys — you attach the policy to the IAM user/role the engine runs as and create the
access key yourself (least surprise, no secrets in logs). Template: `docstore-iam-policy.template.json`.

### Create + attach the IAM principal
```bash
ENV=prod; BUCKET=luke-docstore-prod
aws iam create-policy --policy-name luke-docstore-$ENV \
  --policy-document file:///tmp/luke-docstore-$ENV.json          # note the ARN it returns
aws iam create-user --user-name luke-docstore-$ENV
aws iam attach-user-policy --user-name luke-docstore-$ENV --policy-arn <policyArn>
aws iam create-access-key --user-name luke-docstore-$ENV         # capture AccessKeyId + SecretAccessKey
```

## Wire into Render (per engine service in `render.yaml`)
Replace the local-disk doc store with S3 and drop the persistent disk (a disk pins the service to a
single instance; S3 frees it to scale horizontally):
```yaml
    envVars:
      - key: LUKE_DOCSTORE_PROVIDER
        value: s3
      - key: LUKE_DOCSTORE_BUCKET
        value: luke-docstore-dev          # per env
      - key: LUKE_DOCSTORE_REGION
        value: us-east-2
      - key: LUKE_DOCSTORE_ACCESS_KEY
        sync: false                        # set in the dashboard from the IAM user
      - key: LUKE_DOCSTORE_SECRET_KEY
        sync: false
      # remove: LUKE_DOCSTORE_LOCAL_DIR  and the `disk:` block for this service
```
Keeping `LUKE_DOCSTORE_PROVIDER=local` + the disk is still valid for non-prod if you'd rather defer
the cutover; the engine's `S3DocumentStore` (DOC-1) is selected only when `provider=s3`.

## Verify a provisioned bucket
```bash
B=luke-docstore-dev
aws s3api get-bucket-versioning        --bucket $B          # Status: Enabled
aws s3api get-object-lock-configuration --bucket $B         # ObjectLockEnabled: Enabled
aws s3api get-public-access-block      --bucket $B          # all four true
aws s3api get-bucket-encryption        --bucket $B          # AES256 or aws:kms
aws s3api get-bucket-cors              --bucket $B          # expect: NoSuchCORSConfiguration (none — proxied)
```

## Teardown (dev/qa only — prod is Object-Lock protected)
Compliance-locked objects **cannot** be deleted before their retain-until, by design. For a dev
bucket with no locked objects: `aws s3 rb s3://luke-docstore-dev --force`.
