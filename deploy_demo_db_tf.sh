#!/bin/bash
# Deploy (or update) the demo PostgreSQL database using Terraform.
# Runs terraform init, plan, and apply in terraform/ using demo.tfvars.
#
# Usage:
#   ./deploy_demo_db_tf.sh
#
# Override any variable inline:
#   AWS_PROFILE=my-profile AWS_REGION=us-west-2 ./deploy_demo_db_tf.sh
#   TFVARS_FILE=custom.tfvars ./deploy_demo_db_tf.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"

AWS_PROFILE="${AWS_PROFILE:-sandbox}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TFVARS_FILE="${TFVARS_FILE:-${TF_DIR}/demo.tfvars}"

export AWS_PROFILE AWS_REGION

# ── Preflight checks ───────────────────────────────────────────────────────────
if ! command -v terraform &> /dev/null; then
  echo "Error: terraform is not installed or not on PATH." >&2
  exit 1
fi

if [ ! -f "$TFVARS_FILE" ]; then
  echo "Error: tfvars file not found: ${TFVARS_FILE}" >&2
  echo "Copy terraform/terraform.tfvars.example to terraform/demo.tfvars and fill in your values." >&2
  exit 1
fi

# ── Deploy ─────────────────────────────────────────────────────────────────────
echo "Deploying demo database using Terraform..."
echo "  Directory : ${TF_DIR}"
echo "  Vars file : ${TFVARS_FILE}"
echo "  Profile   : ${AWS_PROFILE}"
echo "  Region    : ${AWS_REGION}"
echo ""

terraform -chdir="$TF_DIR" init -upgrade

terraform -chdir="$TF_DIR" apply \
  -var-file="$TFVARS_FILE" \
  -var="region=${AWS_REGION}" \
  -auto-approve

echo ""
echo "Outputs:"
terraform -chdir="$TF_DIR" output
