#!/bin/bash
# Deploy (create or update) the postgres-mcp ECS CloudFormation stack.
# Deploys into an existing VPC; VPC ID and RDS security group are auto-discovered
# from the RDS instance specified by DB_IDENTIFIER.
#
# Usage:
#   ./deploy_postgres_mcp_ecs_cf.sh
#
# Override any variable inline:
#   DB_IDENTIFIER=my-db DATABASE_URI="postgresql://..." ./deploy_postgres_mcp_ecs_cf.sh
#
# Subnets are auto-discovered from the DB subnet group; override if needed:
#   SUBNET_ID1=subnet-aaa SUBNET_ID2=subnet-bbb ./deploy_postgres_mcp_ecs_cf.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Stack identity ─────────────────────────────────────────────────────────────
STACK_NAME="${STACK_NAME:-demo-postgres-mcp-views}"
AWS_PROFILE="${AWS_PROFILE:-sandbox}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TEMPLATE_URL="${TEMPLATE_URL:-https://tech42-text2sql-mcp-deployment-asset.s3.amazonaws.com/postgres-mcp-ecs.yaml}"

# ── Required parameters ────────────────────────────────────────────────────────
PROJECT_NAME="${PROJECT_NAME:-demo-mcp-views}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
CONTAINER_IMAGE_URI="${CONTAINER_IMAGE_URI:-709825985650.dkr.ecr.us-east-1.amazonaws.com/tech-42/postgres-text2sql-mcp:v1.0.0}"
DB_IDENTIFIER="${DB_IDENTIFIER:-postgres-mcp-demo-dev-demo-postgres-mcp}"
DB_URI_SECRET_ARN="${DB_URI_SECRET_ARN:-arn:aws:secretsmanager:us-east-1:008701887645:secret:postgres-mcp-demo-dev/demo-postgres-mcp/views-database-uri-rkPjrU}"

# ── Networking ─────────────────────────────────────────────────────────────────
# DB_IDENTIFIER is required — VPC_ID, RDS_SECURITY_GROUP_ID, and subnets are all
# auto-discovered from it. Override SUBNET_ID1/SUBNET_ID2 to use specific subnets.
SUBNET_ID1="${SUBNET_ID1:-}"
SUBNET_ID2="${SUBNET_ID2:-}"

DOMAIN="${DOMAIN:-}"
CERTIFICATE_ARN="${CERTIFICATE_ARN:-}"
ALB_IDLE_TIMEOUT="${ALB_IDLE_TIMEOUT:-3600}"

# ── Container ──────────────────────────────────────────────────────────────────
MCP_TRANSPORT="${MCP_TRANSPORT:-streamable-http}"
CONTAINER_CPU="${CONTAINER_CPU:-512}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-1024}"
DESIRED_COUNT="${DESIRED_COUNT:-1}"

# ── Tenant / Server Mode ───────────────────────────────────────────────────────
MCP_SERVER_MODE="${MCP_SERVER_MODE:-tenant}"
TENANT_ALLOWED_RELATIONS="${TENANT_ALLOWED_RELATIONS:-analytics_app.customer_revenue_summary,analytics_app.daily_sales_summary,analytics_app.product_sales_summary,analytics_app.monthly_product_sales_summary,analytics_app.category_performance,analytics_app.payment_health_daily,analytics_app.fulfillment_health_daily,analytics_app.customer_support_summary,analytics_app.executive_kpis,demo_app.text_to_sql_scenario_metrics,demo_app.text_to_sql_workload}"
TENANT_ALLOWED_TENANT_IDS="${TENANT_ALLOWED_TENANT_IDS:-tenant-a,tenant-b}"
TENANT_MAX_ROW_LIMIT="${TENANT_MAX_ROW_LIMIT:-100}"
TENANT_PRINCIPAL_ID="${TENANT_PRINCIPAL_ID:-lambda-agent}"
TENANT_CONTEXT_GUC="${TENANT_CONTEXT_GUC:-}"
TENANT_HEADER_NAME="${TENANT_HEADER_NAME:-}"
DISABLE_DNS_REBINDING_PROTECTION="${DISABLE_DNS_REBINDING_PROTECTION:-true}"
MCP_ALLOWED_HOSTS="${MCP_ALLOWED_HOSTS:-}"
MCP_ALLOWED_ORIGINS="${MCP_ALLOWED_ORIGINS:-}"

# ── RDS IAM Authentication ─────────────────────────────────────────────────────
ENABLE_RDS_IAM_AUTH="${ENABLE_RDS_IAM_AUTH:-false}"
RDS_IAM_CONNECT_ARN="${RDS_IAM_CONNECT_ARN:-}"

# ── VPC Endpoints ──────────────────────────────────────────────────────────────
# The VPC already has interface endpoints for Secrets Manager, ECR, and CloudWatch
# Logs (CreateVpcEndpoints=false avoids DNS conflicts). Instead, we add an ingress
# rule to the existing shared endpoint SG so ECS tasks can reach those endpoints.
# VPC_ENDPOINT_SECURITY_GROUP_ID is auto-discovered from the existing Secrets Manager
# endpoint in the VPC; override it if your setup uses a different security group.
CREATE_VPC_ENDPOINTS="${CREATE_VPC_ENDPOINTS:-false}"
VPC_ENDPOINT_SECURITY_GROUP_ID="${VPC_ENDPOINT_SECURITY_GROUP_ID:-}"
VPC_ENDPOINT_SECURITY_GROUP_ID2="${VPC_ENDPOINT_SECURITY_GROUP_ID2:-}"


# ── Validation ─────────────────────────────────────────────────────────────────
if [ -z "$DB_IDENTIFIER" ]; then
  echo "ERROR: DB_IDENTIFIER is required (used to auto-discover VPC_ID and RDS_SECURITY_GROUP_ID)." >&2
  exit 1
fi

# ── Auto-discover VPC ID, subnets, and RDS security group from DB instance ──────
echo "Looking up VPC info for RDS instance '${DB_IDENTIFIER}'..."
DB_INFO=$(AWS_PROFILE="$AWS_PROFILE" aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION" \
  --query "DBInstances[0].{VpcId:DBSubnetGroup.VpcId,SgId:VpcSecurityGroups[0].VpcSecurityGroupId,Subnets:DBSubnetGroup.Subnets[*].SubnetIdentifier}" \
  --output json)

VPC_ID=$(echo "$DB_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['VpcId'])")
RDS_SECURITY_GROUP_ID=$(echo "$DB_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['SgId'])")
_SUBNET1=$(echo "$DB_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['Subnets'][0])")
_SUBNET2=$(echo "$DB_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['Subnets'][1])")
# Fetch DATABASE_URI from Terraform-managed Secrets Manager secret if not explicitly set
if [ -z "$DATABASE_URI" ] && [ -n "$DB_URI_SECRET_ARN" ]; then
  echo "Fetching DATABASE_URI from Secrets Manager..."
  DATABASE_URI=$(AWS_PROFILE="$AWS_PROFILE" aws secretsmanager get-secret-value \
    --secret-id "$DB_URI_SECRET_ARN" \
    --region "$AWS_REGION" \
    --query "SecretString" --output text 2>/dev/null)
fi
# Append sslmode=require for RDS (required by pg_hba.conf hostssl rules)
if [ -n "$DATABASE_URI" ] && ! echo "$DATABASE_URI" | grep -q "sslmode"; then
  DATABASE_URI="${DATABASE_URI}?sslmode=require"
fi
if [ -z "$DATABASE_URI" ]; then
  echo "ERROR: Could not resolve DATABASE_URI — set DATABASE_URI or DB_URI_SECRET_ARN." >&2
  exit 1
fi

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "ERROR: Could not find VPC for DB instance '${DB_IDENTIFIER}'." >&2
  exit 1
fi
if [ -z "$RDS_SECURITY_GROUP_ID" ] || [ "$RDS_SECURITY_GROUP_ID" = "None" ]; then
  echo "ERROR: Could not find security group for DB instance '${DB_IDENTIFIER}'." >&2
  exit 1
fi
if [ -z "$_SUBNET1" ] || [ -z "$_SUBNET2" ] || [ "$_SUBNET1" = "None" ] || [ "$_SUBNET2" = "None" ]; then
  echo "ERROR: DB instance '${DB_IDENTIFIER}' subnet group has fewer than 2 subnets." >&2
  exit 1
fi

SUBNET_ID1="${SUBNET_ID1:-$_SUBNET1}"
SUBNET_ID2="${SUBNET_ID2:-$_SUBNET2}"

# Auto-discover existing VPC endpoint security groups (used when CreateVpcEndpoints=false).
# Queries the Secrets Manager endpoint SG and the ECR endpoint SG separately because
# they may differ. Override either variable to skip auto-discovery.
if [ -z "$VPC_ENDPOINT_SECURITY_GROUP_ID" ]; then
  VPC_ENDPOINT_SECURITY_GROUP_ID=$(AWS_PROFILE="$AWS_PROFILE" aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=service-name,Values=com.amazonaws.${AWS_REGION}.secretsmanager" \
              "Name=vpc-endpoint-state,Values=available" \
    --query "VpcEndpoints[0].Groups[0].GroupId" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  [ "$VPC_ENDPOINT_SECURITY_GROUP_ID" = "None" ] && VPC_ENDPOINT_SECURITY_GROUP_ID=""
fi

if [ -z "$VPC_ENDPOINT_SECURITY_GROUP_ID2" ]; then
  VPC_ENDPOINT_SECURITY_GROUP_ID2=$(AWS_PROFILE="$AWS_PROFILE" aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=service-name,Values=com.amazonaws.${AWS_REGION}.ecr.api" \
              "Name=vpc-endpoint-state,Values=available" \
    --query "VpcEndpoints[0].Groups[0].GroupId" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  [ "$VPC_ENDPOINT_SECURITY_GROUP_ID2" = "None" ] && VPC_ENDPOINT_SECURITY_GROUP_ID2=""
  # If ECR SG matches Secrets Manager SG, no need for a second rule
  [ "$VPC_ENDPOINT_SECURITY_GROUP_ID2" = "$VPC_ENDPOINT_SECURITY_GROUP_ID" ] && VPC_ENDPOINT_SECURITY_GROUP_ID2=""
fi

echo "  VPC ID:             ${VPC_ID}"
echo "  Subnet 1:           ${SUBNET_ID1}"
echo "  Subnet 2:           ${SUBNET_ID2}"
echo "  RDS Security Group: ${RDS_SECURITY_GROUP_ID}"
[ -n "$VPC_ENDPOINT_SECURITY_GROUP_ID" ]  && echo "  VPC Endpoint SG:    ${VPC_ENDPOINT_SECURITY_GROUP_ID}"
[ -n "$VPC_ENDPOINT_SECURITY_GROUP_ID2" ] && echo "  VPC Endpoint SG2:   ${VPC_ENDPOINT_SECURITY_GROUP_ID2}"

# ── Deploy ─────────────────────────────────────────────────────────────────────
echo "Deploying stack '${STACK_NAME}' in region '${AWS_REGION}' using profile '${AWS_PROFILE}'..."

PARAMS_FILE="$(mktemp /tmp/cf-params-XXXXXX)"
trap 'rm -f "$PARAMS_FILE"' EXIT

cat > "$PARAMS_FILE" << EOF
[
  {"ParameterKey": "ProjectName",                   "ParameterValue": "${PROJECT_NAME}"},
  {"ParameterKey": "Environment",                   "ParameterValue": "${ENVIRONMENT}"},
  {"ParameterKey": "DatabaseUri",                   "ParameterValue": "${DATABASE_URI}"},
  {"ParameterKey": "ContainerImageUri",             "ParameterValue": "${CONTAINER_IMAGE_URI}"},
  {"ParameterKey": "VpcId",                         "ParameterValue": "${VPC_ID}"},
  {"ParameterKey": "SubnetId1",                     "ParameterValue": "${SUBNET_ID1}"},
  {"ParameterKey": "SubnetId2",                     "ParameterValue": "${SUBNET_ID2}"},
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
  {"ParameterKey": "RdsIamConnectArn",              "ParameterValue": "${RDS_IAM_CONNECT_ARN}"},
  {"ParameterKey": "CreateVpcEndpoints",            "ParameterValue": "${CREATE_VPC_ENDPOINTS}"},
  {"ParameterKey": "VpcEndpointSecurityGroupId",    "ParameterValue": "${VPC_ENDPOINT_SECURITY_GROUP_ID}"},
  {"ParameterKey": "VpcEndpointSecurityGroupId2",   "ParameterValue": "${VPC_ENDPOINT_SECURITY_GROUP_ID2}"}
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

LOCAL_TEMPLATE="${SCRIPT_DIR}/postgres-mcp-ecs.yaml"
if [ -f "$LOCAL_TEMPLATE" ]; then
  TEMPLATE_ARG="--template-body file://${LOCAL_TEMPLATE}"
  echo "Using local template: ${LOCAL_TEMPLATE}"
else
  TEMPLATE_ARG="--template-url ${TEMPLATE_URL}"
  echo "Using S3 template: ${TEMPLATE_URL}"
fi

set +e
RESULT=$(AWS_PROFILE="$AWS_PROFILE" aws cloudformation "$ACTION" \
  --stack-name "$STACK_NAME" \
  $TEMPLATE_ARG \
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
