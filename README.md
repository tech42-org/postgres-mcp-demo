# postgres-mcp-demo

**Live demo: [sqlagent.tech42demo.com](https://sqlagent.tech42demo.com/)**

Demo of AWS AgentCore invoking a PostgreSQL database through the Postgres MCP server using text-to-SQL. The agent runs on AWS Bedrock AgentCore and queries a multi-tenant analytics database via two MCP server deployments — one tenant-scoped (Views) and one unrestricted (Admin).

## Architecture

```
Browser / Demo App  (deploy_demo_app.sh)
      │
      ▼
AWS Bedrock AgentCore Runtime  (deploy_agentcore_agent_cf.sh)
      │
      ├──▶  Views MCP Server  (deploy_views_mcp_cf.sh)   — tenant mode, read-only views
      └──▶  Admin MCP Server  (deploy_admin_mcp_cf.sh)   — admin mode, full DB access
                    │
                    ▼
            PostgreSQL (RDS)  (deploy_demo_db_tf.sh)
```

## Demo

**Business query** — ask a natural-language question, get SQL-generated results:

![Business query](assets/business_query.png)

**DB optimization** — inspect and optimize queries across the full schema:

![DB optimization](assets/db_optimization.png)

## Prerequisites

### 1. Subscribe on AWS Marketplace

Before deploying, subscribe to both Tech 42 products in your AWS account:

- **[Tech 42 AgentCore](https://aws.amazon.com/marketplace/pp/prodview-qizrc6sk6fb7a)** — required for `deploy_agentcore_agent_cf.sh`
- **[Tech 42 PostgreSQL Text-to-SQL MCP Server](https://aws.amazon.com/marketplace/pp/prodview-upn53f2cj47ds)** — required for `deploy_views_mcp_cf.sh` and `deploy_admin_mcp_cf.sh`

Click **Subscribe** on each product page before deploying.

### 2. Requirements

- AWS CLI v2 configured with a profile that has CloudFormation, ECS, ECR, RDS, Secrets Manager, and Bedrock permissions
- Terraform >= 1.5
- Docker (used by the schema initializer to run `psql` without a local install)

## Deploy

### Step 1 — Deploy the demo database

```bash
./deploy_demo_db_tf.sh
```

This provisions the RDS PostgreSQL instance, subnet group, security group, and Secrets Manager URIs via Terraform, then automatically runs the schema initializer via Docker. The apply takes ~5 minutes (RDS creation).

Override defaults inline if needed:

```bash
AWS_PROFILE=my-profile AWS_REGION=us-west-2 ./deploy_demo_db_tf.sh
TFVARS_FILE=terraform/custom.tfvars ./deploy_demo_db_tf.sh
```

Key outputs written to state:

| Output | Description |
|---|---|
| `demo_postgres_mcp_database_endpoint` | RDS hostname:port |
| `demo_postgres_mcp_admin_database_uri_secret_arn` | Admin URI in Secrets Manager |
| `demo_postgres_mcp_raw_database_uri_secret_arn` | Raw read-only role URI |
| `demo_postgres_mcp_views_database_uri_secret_arn` | Views read-only role URI |

### Step 2 — Deploy the MCP servers

Both scripts automatically look up the RDS VPC ID, VPC CIDR, and security group from the deployed RDS instance. You must supply `DATABASE_URI` by fetching the connection string from Secrets Manager first.

Retrieve the URIs from the Terraform outputs:

```bash
VIEWS_DATABASE_URI=$(aws secretsmanager get-secret-value \
  --secret-id $(terraform -chdir=terraform output -raw demo_postgres_mcp_views_database_uri_secret_arn) \
  --query SecretString --output text)

ADMIN_DATABASE_URI=$(aws secretsmanager get-secret-value \
  --secret-id $(terraform -chdir=terraform output -raw demo_postgres_mcp_admin_database_uri_secret_arn) \
  --query SecretString --output text)
```

**Views MCP server** (tenant-scoped, read-only analytics views):

```bash
DATABASE_URI="$VIEWS_DATABASE_URI" ./deploy_views_mcp_cf.sh
```

**Admin MCP server** (unrestricted, full database access):

```bash
DATABASE_URI="$ADMIN_DATABASE_URI" ./deploy_admin_mcp_cf.sh
```

Both scripts handle create vs. update automatically and delete/recreate if the stack is in `ROLLBACK_COMPLETE`. Stack outputs including the MCP endpoint URL are printed on completion.

### Step 3 — Deploy the AgentCore agent runtime

```bash
./deploy_agentcore_agent_cf.sh
```

### Step 4 — Run the demo app

The demo app is a local web UI that streams AgentCore responses via Server-Sent Events. It requires Python 3.9+ and the values output by the previous steps.

Retrieve the AgentCore runtime ARN and MCP endpoints from the CloudFormation stacks:

```bash
AGENTCORE_RUNTIME_ARN=$(aws cloudformation describe-stacks \
  --stack-name demo-postgres-mcp-agent \
  --query 'Stacks[0].Outputs[?OutputKey==`AgentCoreRuntimeArn`].OutputValue' \
  --output text)

VIEWS_MCP_URL=$(aws cloudformation describe-stacks \
  --stack-name demo-postgres-mcp-views \
  --query 'Stacks[0].Outputs[?OutputKey==`McpEndpointUrl`].OutputValue' \
  --output text)

VIEWS_MCP_API_KEY=$(aws cloudformation describe-stacks \
  --stack-name demo-postgres-mcp-views \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiKey`].OutputValue' \
  --output text)

ADMIN_MCP_URL=$(aws cloudformation describe-stacks \
  --stack-name demo-postgres-mcp-admin \
  --query 'Stacks[0].Outputs[?OutputKey==`McpEndpointUrl`].OutputValue' \
  --output text)

ADMIN_MCP_API_KEY=$(aws cloudformation describe-stacks \
  --stack-name demo-postgres-mcp-admin \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiKey`].OutputValue' \
  --output text)
```

Open `deploy_demo_app.sh`, fill in the five exported variables at the top with the values above, then run:

```bash
./deploy_demo_app.sh
# → open http://localhost:8000
```

The script installs `fastapi`, `uvicorn`, and `boto3` from `frontend/requirements.txt`, then starts the server. Optional overrides:

| Variable | Default | Description |
|---|---|---|
| `AWS_PROFILE` | `sandbox` | boto3 named profile |
| `AWS_REGION` | `us-east-1` | AWS region |
| `MODEL_ID` | `claude-haiku-4-5` | Bedrock model ID |
| `PORT` | `8000` | HTTP port |

## Test (Jupyter)

Open and run `text2sql_postgres_mcp_example.ipynb` in Jupyter. The notebook automatically resolves all endpoints and API keys from the CloudFormation stack outputs — no manual configuration required.

## Tear Down

Delete the MCP and AgentCore stacks:

```bash
for stack in demo-postgres-mcp-views demo-postgres-mcp-admin demo-postgres-mcp-agent; do
  AWS_PROFILE=sandbox aws cloudformation delete-stack --stack-name $stack --region us-east-1
done
```

Destroy the RDS database and supporting infrastructure:

```bash
cd terraform
terraform destroy -var-file=demo.tfvars
```
