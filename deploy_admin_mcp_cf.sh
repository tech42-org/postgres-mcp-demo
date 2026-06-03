#!/bin/bash
# Deploy (create or update) the postgres-mcp ECS CloudFormation stack in admin mode.
# Admin mode has no multi-tenant restrictions — full database access.
#
# Usage:
#   ./deploy_admin_mcp_cf.sh
#
# Override any variable inline:
#   STACK_NAME=my-stack ./deploy_admin_mcp_cf.sh

set -e

# ── Stack identity ─────────────────────────────────────────────────────────────
STACK_NAME="${STACK_NAME:-demo-postgres-mcp-admin}"
AWS_PROFILE="${AWS_PROFILE:-sandbox}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TEMPLATE_URL="${TEMPLATE_URL:-https://tech42-text2sql-mcp-deployment-asset.s3.amazonaws.com/postgres-mcp-ecs.yaml}"

# ── Required parameters ────────────────────────────────────────────────────────
PROJECT_NAME="${PROJECT_NAME:-demo-mcp-admin}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
CONTAINER_IMAGE_URI="${CONTAINER_IMAGE_URI:-008701887645.dkr.ecr.us-east-1.amazonaws.com/postgres-mcp:v0.1.0}"
DB_IDENTIFIER="${DB_IDENTIFIER:-postgres-mcp-demo-dev-demo-postgres-mcp}"
DATABASE_URI="${DATABASE_URI:-postgresql://demo_admin:V6tcY5bhyA1yho4rvJSfhKWXlYcH7PQD@postgres-mcp-demo-dev-demo-postgres-mcp.cdzohpfba5bv.us-east-1.rds.amazonaws.com:5432/demo_postgres_mcp}"

# ── Networking ─────────────────────────────────────────────────────────────────
# Use a different CIDR block to avoid conflicts with the views stack (10.42.x.x)
VPC_CIDR="${VPC_CIDR:-10.43.0.0/16}"
PUBLIC_SUBNET_1_CIDR="${PUBLIC_SUBNET_1_CIDR:-10.43.1.0/24}"
PUBLIC_SUBNET_2_CIDR="${PUBLIC_SUBNET_2_CIDR:-10.43.2.0/24}"
PEER_VPC_ROUTE_TABLE_IDS="${PEER_VPC_ROUTE_TABLE_IDS:-}"

# ── RDS VPC lookup ─────────────────────────────────────────────────────────────
if [ -n "$DB_IDENTIFIER" ]; then
  echo "Looking up VPC info for RDS instance '${DB_IDENTIFIER}'..."
  DB_INFO=$(AWS_PROFILE="$AWS_PROFILE" aws rds describe-db-instances \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query "DBInstances[0].{VpcId:DBSubnetGroup.VpcId,SgIds:VpcSecurityGroups[*].VpcSecurityGroupId}" \
    --output json)

  _PEER_VPC_ID=$(echo "$DB_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['VpcId'])")
  _RDS_SG_ID=$(echo "$DB_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['SgIds'][0])")

  if [ -z "$_PEER_VPC_ID" ] || [ "$_PEER_VPC_ID" = "None" ]; then
    echo "ERROR: Could not find VPC for DB instance '${DB_IDENTIFIER}'." >&2
    exit 1
  fi

  _PEER_VPC_CIDR=$(AWS_PROFILE="$AWS_PROFILE" aws ec2 describe-vpcs \
    --vpc-ids "$_PEER_VPC_ID" \
    --region "$AWS_REGION" \
    --query "Vpcs[0].CidrBlock" \
    --output text)

  PEER_VPC_ID="${PEER_VPC_ID:-$_PEER_VPC_ID}"
  PEER_VPC_CIDR="${PEER_VPC_CIDR:-$_PEER_VPC_CIDR}"
  RDS_SECURITY_GROUP_ID="${RDS_SECURITY_GROUP_ID:-$_RDS_SG_ID}"
  echo "  VPC ID:       ${PEER_VPC_ID}"
  echo "  VPC CIDR:     ${PEER_VPC_CIDR}"
  echo "  Security GID: ${RDS_SECURITY_GROUP_ID}"
else
  PEER_VPC_ID="${PEER_VPC_ID:-}"
  PEER_VPC_CIDR="${PEER_VPC_CIDR:-}"
  RDS_SECURITY_GROUP_ID="${RDS_SECURITY_GROUP_ID:-}"
fi
DOMAIN="${DOMAIN:-}"
CERTIFICATE_ARN="${CERTIFICATE_ARN:-}"
ALB_IDLE_TIMEOUT="${ALB_IDLE_TIMEOUT:-300}"

# ── Container ──────────────────────────────────────────────────────────────────
MCP_TRANSPORT="${MCP_TRANSPORT:-streamable-http}"
CONTAINER_CPU="${CONTAINER_CPU:-512}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-1024}"
DESIRED_COUNT="${DESIRED_COUNT:-1}"

# ── Admin Server Mode — no tenant restrictions ─────────────────────────────────
MCP_SERVER_MODE="${MCP_SERVER_MODE:-admin}"
TENANT_ALLOWED_RELATIONS="${TENANT_ALLOWED_RELATIONS:-}"
TENANT_ALLOWED_TENANT_IDS="${TENANT_ALLOWED_TENANT_IDS:-}"
TENANT_MAX_ROW_LIMIT="${TENANT_MAX_ROW_LIMIT:-100}"
TENANT_PRINCIPAL_ID="${TENANT_PRINCIPAL_ID:-}"
TENANT_CONTEXT_GUC="${TENANT_CONTEXT_GUC:-}"
TENANT_HEADER_NAME="${TENANT_HEADER_NAME:-}"
DISABLE_DNS_REBINDING_PROTECTION="${DISABLE_DNS_REBINDING_PROTECTION:-true}"
MCP_ALLOWED_HOSTS="${MCP_ALLOWED_HOSTS:-}"
MCP_ALLOWED_ORIGINS="${MCP_ALLOWED_ORIGINS:-}"

# ── RDS IAM Authentication ─────────────────────────────────────────────────────
ENABLE_RDS_IAM_AUTH="${ENABLE_RDS_IAM_AUTH:-false}"
RDS_IAM_CONNECT_ARN="${RDS_IAM_CONNECT_ARN:-}"

# ── Deploy ─────────────────────────────────────────────────────────────────────
echo "Deploying stack '${STACK_NAME}' in region '${AWS_REGION}' using profile '${AWS_PROFILE}'..."
echo "Template: ${TEMPLATE_URL}"

PARAMS_FILE="$(mktemp /tmp/cf-params-XXXXXX)"
trap 'rm -f "$PARAMS_FILE"' EXIT

cat > "$PARAMS_FILE" << EOF
[
  {"ParameterKey": "ProjectName",                   "ParameterValue": "${PROJECT_NAME}"},
  {"ParameterKey": "Environment",                   "ParameterValue": "${ENVIRONMENT}"},
  {"ParameterKey": "DatabaseUri",                   "ParameterValue": "${DATABASE_URI}"},
  {"ParameterKey": "ContainerImageUri",             "ParameterValue": "${CONTAINER_IMAGE_URI}"},
  {"ParameterKey": "VpcCidr",                       "ParameterValue": "${VPC_CIDR}"},
  {"ParameterKey": "PublicSubnet1Cidr",             "ParameterValue": "${PUBLIC_SUBNET_1_CIDR}"},
  {"ParameterKey": "PublicSubnet2Cidr",             "ParameterValue": "${PUBLIC_SUBNET_2_CIDR}"},
  {"ParameterKey": "PeerVpcId",                     "ParameterValue": "${PEER_VPC_ID}"},
  {"ParameterKey": "PeerVpcCidr",                   "ParameterValue": "${PEER_VPC_CIDR}"},
  {"ParameterKey": "PeerVpcRouteTableIds",          "ParameterValue": "${PEER_VPC_ROUTE_TABLE_IDS}"},
  {"ParameterKey": "RdsSecurityGroupId",            "ParameterValue": "${RDS_SECURITY_GROUP_ID}"},
  {"ParameterKey": "Domain",                        "ParameterValue": "${DOMAIN}"},
  {"ParameterKey": "CertificateArn",                "ParameterValue": "${CERTIFICATE_ARN}"},
  {"ParameterKey": "AlbIdleTimeout",                "ParameterValue": "${ALB_IDLE_TIMEOUT}"},
  {"ParameterKey": "McpTransport",                  "ParameterValue": "${MCP_TRANSPORT}"},
  {"ParameterKey": "ContainerCpu",                  "ParameterValue": "${CONTAINER_CPU}"},
  {"ParameterKey": "ContainerMemory",               "ParameterValue": "${CONTAINER_MEMORY}"},
  {"ParameterKey": "DesiredCount",                  "ParameterValue": "${DESIRED_COUNT}"},
  {"ParameterKey": "McpServerMode",                 "ParameterValue": "${MCP_SERVER_MODE}"},
  {"ParameterKey": "TenantAllowedRelations",        "ParameterValue": "${TENANT_ALLOWED_RELATIONS}"},
  {"ParameterKey": "TenantAllowedTenantIds",        "ParameterValue": "${TENANT_ALLOWED_TENANT_IDS}"},
  {"ParameterKey": "TenantMaxRowLimit",             "ParameterValue": "${TENANT_MAX_ROW_LIMIT}"},
  {"ParameterKey": "TenantPrincipalId",             "ParameterValue": "${TENANT_PRINCIPAL_ID}"},
  {"ParameterKey": "TenantContextGuc",              "ParameterValue": "${TENANT_CONTEXT_GUC}"},
  {"ParameterKey": "TenantHeaderName",              "ParameterValue": "${TENANT_HEADER_NAME}"},
  {"ParameterKey": "DisableDnsRebindingProtection", "ParameterValue": "${DISABLE_DNS_REBINDING_PROTECTION}"},
  {"ParameterKey": "McpAllowedHosts",               "ParameterValue": "${MCP_ALLOWED_HOSTS}"},
  {"ParameterKey": "McpAllowedOrigins",             "ParameterValue": "${MCP_ALLOWED_ORIGINS}"},
  {"ParameterKey": "EnableRdsIamAuth",              "ParameterValue": "${ENABLE_RDS_IAM_AUTH}"},
  {"ParameterKey": "RdsIamConnectArn",              "ParameterValue": "${RDS_IAM_CONNECT_ARN}"}
]
EOF

# Determine create vs update; delete first if stuck in ROLLBACK_COMPLETE
STACK_STATUS=$(AWS_PROFILE="$AWS_PROFILE" aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "ROLLBACK_COMPLETE" ]; then
  echo "Stack is in ROLLBACK_COMPLETE — deleting before recreating..."
  AWS_PROFILE="$AWS_PROFILE" aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" --region "$AWS_REGION"
  AWS_PROFILE="$AWS_PROFILE" aws cloudformation wait stack-delete-complete \
    --stack-name "$STACK_NAME" --region "$AWS_REGION"
  STACK_STATUS="DOES_NOT_EXIST"
fi

if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
  ACTION="create-stack"
  WAIT_ACTION="stack-create-complete"
else
  ACTION="update-stack"
  WAIT_ACTION="stack-update-complete"
fi

set +e
RESULT=$(AWS_PROFILE="$AWS_PROFILE" aws cloudformation "$ACTION" \
  --stack-name "$STACK_NAME" \
  --template-url "$TEMPLATE_URL" \
  --region "$AWS_REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters "file://${PARAMS_FILE}" 2>&1)
CF_EXIT=$?
set -e

if [ $CF_EXIT -ne 0 ]; then
  if echo "$RESULT" | grep -q "No updates are to be performed"; then
    echo "Stack is already up to date."
  else
    echo "$RESULT" >&2
    exit 1
  fi
else
  echo "Waiting for stack operation to complete..."
  AWS_PROFILE="$AWS_PROFILE" aws cloudformation wait "$WAIT_ACTION" \
    --stack-name "$STACK_NAME" --region "$AWS_REGION"
  echo "Successfully deployed stack - ${STACK_NAME}"
fi

echo ""
echo "Stack outputs:"
AWS_PROFILE="$AWS_PROFILE" aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}" \
  --output table
