#!/bin/bash
# Deploy (create or update) the AgentCore agent CloudFormation stack.
#
# Usage:
#   ./deploy_agentcore_agent_cf.sh
#
# Override any variable inline:
#   STACK_NAME=my-stack ./deploy_agentcore_agent_cf.sh

set -e

# ── Stack identity ─────────────────────────────────────────────────────────────
STACK_NAME="${STACK_NAME:-demo-postgres-mcp-agent}"
AWS_PROFILE="${AWS_PROFILE:-sandbox}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TEMPLATE_URL="${TEMPLATE_URL:-https://s3.amazonaws.com/tech42-agentcore-deployment-assets/tech-42-agentcore-deployment.yaml}"

# ── Agent ──────────────────────────────────────────────────────────────────────
PROJECT_NAME="${PROJECT_NAME:-demo-mcp-agent}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AGENT_NAME="${AGENT_NAME:-demo_postgres_mcp_agent}"
ECR_IMAGE_URI="${ECR_IMAGE_URI:-008701887645.dkr.ecr.us-east-1.amazonaws.com/agent42-base-dev:v0.2.2.langfuse}"
NETWORK_MODE="${NETWORK_MODE:-PUBLIC}"
VPC_SECURITY_GROUP_IDS="${VPC_SECURITY_GROUP_IDS:-}"
VPC_SUBNET_IDS="${VPC_SUBNET_IDS:-}"

# ── Memory ─────────────────────────────────────────────────────────────────────
MEMORY_NAME="${MEMORY_NAME:-AgentCoreMemory}"
MEMORY_EVENT_EXPIRY_DAYS="${MEMORY_EVENT_EXPIRY_DAYS:-30}"

# ── Guardrail ──────────────────────────────────────────────────────────────────
ENABLE_GUARDRAIL="${ENABLE_GUARDRAIL:-true}"
GUARDRAIL_DESCRIPTION="${GUARDRAIL_DESCRIPTION:-Guardrail for AgentCore runtime with content filtering}"

# ── Observability ──────────────────────────────────────────────────────────────
DISABLE_ADOT_OBSERVABILITY="${DISABLE_ADOT_OBSERVABILITY:-true}"
LANGFUSE_BASE_URL="${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-}"

# ── Deploy ─────────────────────────────────────────────────────────────────────
echo "Deploying stack '${STACK_NAME}' in region '${AWS_REGION}' using profile '${AWS_PROFILE}'..."
echo "Template: ${TEMPLATE_URL}"

PARAMS_FILE="$(mktemp /tmp/cf-params-XXXXXX)"
trap 'rm -f "$PARAMS_FILE"' EXIT

cat > "$PARAMS_FILE" << EOF
[
  {"ParameterKey": "ProjectName",              "ParameterValue": "${PROJECT_NAME}"},
  {"ParameterKey": "Environment",              "ParameterValue": "${ENVIRONMENT}"},
  {"ParameterKey": "AgentName",                "ParameterValue": "${AGENT_NAME}"},
  {"ParameterKey": "ECRImageUri",              "ParameterValue": "${ECR_IMAGE_URI}"},
  {"ParameterKey": "NetworkMode",              "ParameterValue": "${NETWORK_MODE}"},
  {"ParameterKey": "VpcSecurityGroupIds",      "ParameterValue": "${VPC_SECURITY_GROUP_IDS}"},
  {"ParameterKey": "VpcSubnetIds",             "ParameterValue": "${VPC_SUBNET_IDS}"},
  {"ParameterKey": "MemoryName",               "ParameterValue": "${MEMORY_NAME}"},
  {"ParameterKey": "MemoryEventExpiryDays",    "ParameterValue": "${MEMORY_EVENT_EXPIRY_DAYS}"},
  {"ParameterKey": "EnableGuardrail",          "ParameterValue": "${ENABLE_GUARDRAIL}"},
  {"ParameterKey": "GuardrailDescription",     "ParameterValue": "${GUARDRAIL_DESCRIPTION}"},
  {"ParameterKey": "DisableADOTObservability", "ParameterValue": "${DISABLE_ADOT_OBSERVABILITY}"},
  {"ParameterKey": "LangfuseBaseUrl",          "ParameterValue": "${LANGFUSE_BASE_URL}"},
  {"ParameterKey": "LangfusePublicKey",        "ParameterValue": "${LANGFUSE_PUBLIC_KEY}"},
  {"ParameterKey": "LangfuseSecretKey",        "ParameterValue": "${LANGFUSE_SECRET_KEY}"}
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
