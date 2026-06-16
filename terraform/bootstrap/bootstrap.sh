#!/usr/bin/env bash
# Creates the S3 remote-state bucket and DynamoDB lock table in the current
# AWS account. Idempotent — safe to run more than once.
#
# Usage:
#   AWS_PROFILE=my-profile ./terraform/bootstrap/bootstrap.sh
#   AWS_PROFILE=my-profile REGION=us-west-2 ./terraform/bootstrap/bootstrap.sh
#
# Environment variables:
#   AWS_PROFILE   AWS credentials profile (optional)
#   REGION        AWS region (default: us-east-1)
#   PROJECT       Resource name prefix (default: postgres-mcp-demo)
#   ENVIRONMENT   Deployment environment, used in state key (default: dev)
#
# Requirements: AWS CLI v2

set -euo pipefail

PROJECT="${PROJECT:-postgres-mcp-demo}"
REGION="${REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

BUCKET_NAME="${PROJECT}-tfstate-${ACCOUNT_ID}"
LOCK_TABLE="${PROJECT}-tfstate-lock"

echo "Bootstrap: Terraform S3 remote state"
echo "  Account  : ${ACCOUNT_ID}"
echo "  Region   : ${REGION}"
echo "  Bucket   : ${BUCKET_NAME}"
echo "  DynamoDB : ${LOCK_TABLE}"
echo ""

# ── S3 bucket ─────────────────────────────────────────────────────────────────

if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "S3 bucket already exists: ${BUCKET_NAME}"
else
  echo "Creating S3 bucket: ${BUCKET_NAME} in ${REGION}..."
  if [ "${REGION}" = "us-east-1" ]; then
    # LocationConstraint must be omitted for us-east-1 — AWS rejects it otherwise
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
fi

echo "Enabling versioning..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

echo "Enabling SSE-S3 encryption..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

echo "Blocking public access..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# ── DynamoDB lock table ────────────────────────────────────────────────────────

if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${REGION}" 2>/dev/null; then
  echo "DynamoDB table already exists: ${LOCK_TABLE}"
else
  echo "Creating DynamoDB table: ${LOCK_TABLE}..."
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  echo "Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "${LOCK_TABLE}" --region "${REGION}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Done. Copy the following into terraform/backend.hcl:"
echo ""
echo "  bucket         = \"${BUCKET_NAME}\""
echo "  key            = \"${PROJECT}/${ENVIRONMENT}/terraform.tfstate\""
echo "  region         = \"${REGION}\""
echo "  dynamodb_table = \"${LOCK_TABLE}\""
echo "  encrypt        = true"
echo ""
echo "Then run: terraform init -backend-config=terraform/backend.hcl"
echo "  (or just run ./deploy_demo_db_tf.sh)"
