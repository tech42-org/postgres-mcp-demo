# postgres-mcp-demo

Demo of AWS AgentCore invoking a PostgreSQL database through the Postgres MCP server using text-to-SQL. The agent runs on AWS Bedrock AgentCore and queries a multi-tenant analytics database via two MCP server deployments — one tenant-scoped (Views) and one unrestricted (Admin).

## Architecture

```
Jupyter Notebook
      │
      ▼
AWS Bedrock AgentCore Runtime  (deploy_agentcore_agent_cf.sh)
      │
      ├──▶  Views MCP Server  (deploy_views_mcp_cf.sh)   — tenant mode, read-only views
      └──▶  Admin MCP Server  (deploy_admin_mcp_cf.sh)   — admin mode, full DB access
                    │
                    ▼
            PostgreSQL (RDS)  (terraform/)
```

## Prerequisites

### 1. Subscribe on AWS Marketplace

Before deploying, subscribe to both Tech 42 products in your AWS account:

- **Tech 42 AgentCore** — required for `deploy_agentcore_agent_cf.sh`
- **Tech 42 Text-to-SQL MCP Server** — required for `deploy_views_mcp_cf.sh` and `deploy_admin_mcp_cf.sh`

Search for both products at [AWS Marketplace](https://aws.amazon.com/marketplace) and click **Subscribe** on each.

### 2. Requirements

- AWS CLI v2 configured with a profile that has CloudFormation, ECS, ECR, RDS, Secrets Manager, and Bedrock permissions
- Terraform >= 1.5
- Docker (used by the schema initializer to run `psql` without a local install)
- Python 3 with `psycopg[binary]` (`pip install "psycopg[binary]"`)
- `boto3` installed (`pip install boto3`)

## Deploy

### Step 1 — Deploy the demo database

The RDS PostgreSQL instance, subnet group, security group, and Secrets Manager URIs are all managed by Terraform.

```bash
cd terraform
terraform init
terraform apply -var-file=demo.tfvars
```

`demo.tfvars` is pre-configured with the sandbox account defaults. The apply takes ~5 minutes (RDS creation) and runs the schema initializer automatically via Docker on completion.

Key outputs written to state:

| Output | Description |
|---|---|
| `demo_postgres_mcp_database_endpoint` | RDS hostname:port |
| `demo_postgres_mcp_admin_database_uri_secret_arn` | Admin URI in Secrets Manager |
| `demo_postgres_mcp_raw_database_uri_secret_arn` | Raw read-only role URI |
| `demo_postgres_mcp_views_database_uri_secret_arn` | Views read-only role URI |

### Step 2 — Seed the database schema

If you need to re-seed (e.g. after a data reset), fetch the admin URI and run the schema SQL via Docker:

```bash
ADMIN_URI=$(aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw demo_postgres_mcp_admin_database_uri_secret_arn) \
  --query SecretString --output text)

RAW_URI=$(aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw demo_postgres_mcp_raw_database_uri_secret_arn) \
  --query SecretString --output text)

VIEWS_URI=$(aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw demo_postgres_mcp_views_database_uri_secret_arn) \
  --query SecretString --output text)

RAW_PASS=$(python3 -c "from urllib.parse import urlparse; print(urlparse('$RAW_URI').password)")
VIEWS_PASS=$(python3 -c "from urllib.parse import urlparse; print(urlparse('$VIEWS_URI').password)")

docker run --rm -i postgres:16-alpine psql "$ADMIN_URI" \
  -v ON_ERROR_STOP=1 \
  -v raw_role=text_to_sql_raw_ro \
  -v raw_role_password="$RAW_PASS" \
  -v views_role=text_to_sql_views_ro \
  -v views_role_password="$VIEWS_PASS" \
  -v seed_scale_factor=2 \
  < sql/demo_postgres_mcp_schema.sql
```

This creates three schemas:

- **`raw_app`** — normalized ecommerce base tables (customers, orders, payments, shipments, etc.) with row-level security
- **`analytics_app`** — business-grain views (`customer_revenue_summary`, `daily_sales_summary`, `executive_kpis`, etc.)
- **`demo_app`** — scenario comparison metrics and example query workload

### Step 3 — Apply tenant views and seed marker users

Run the three scripts in order from the repo root. Each reads `ADMIN_DATABASE_URI` from the environment.

```bash
cd ..  # back to repo root

ADMIN_URI=$(aws secretsmanager get-secret-value \
  --secret-id $(cd terraform && terraform output -raw demo_postgres_mcp_admin_database_uri_secret_arn) \
  --query SecretString --output text)
```

**3a. Create the `tenant_app` schema and `tenant_app_ro` role:**

```bash
TENANT_ROLE_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")

ADMIN_DATABASE_URI="$ADMIN_URI" \
TENANT_ROLE_PASSWORD="$TENANT_ROLE_PASSWORD" \
python3 scripts/apply_tenant_views.py
```

This creates tenant-scoped views over `raw_app` (e.g. `tenant_app.customers`, `tenant_app.orders`) and a least-privilege `tenant_app_ro` role that can only read through those views. Output shows the customer count per tenant.

**3b. Seed deterministic marker users for isolation checks:**

```bash
ADMIN_DATABASE_URI="$ADMIN_URI" python3 scripts/seed_tenant_isolation_users.py
```

Inserts two marker customers with known emails (`daan.tenant-a@example.test` and `michael.tenant-b@example.test`), each with an order, order line, and payment, assigned to their respective tenants.

**3c. Verify tenant isolation:**

Build the tenant role URI and run the verifier:

```bash
HOST=$(python3 -c "from urllib.parse import urlparse; u=urlparse('$ADMIN_URI'); print(u.hostname)")
PORT=$(python3 -c "from urllib.parse import urlparse; u=urlparse('$ADMIN_URI'); print(u.port or 5432)")
DBNAME=$(python3 -c "from urllib.parse import urlparse; u=urlparse('$ADMIN_URI'); print(u.path.lstrip('/'))")

DATABASE_URI="postgresql://tenant_app_ro:${TENANT_ROLE_PASSWORD}@${HOST}:${PORT}/${DBNAME}" \
python3 scripts/verify_tenant_views.py
```

Expected output:

```
tenant-a customers: 161
tenant-a orders:    641
tenant-b customers: 161
tenant-b orders:    641
tenant-a markers: ['daan.tenant-a@example.test']
tenant-b markers: ['michael.tenant-b@example.test']
raw_app.customers blocked: InsufficientPrivilege
```

### Step 4 — Look up the database VPC info

The MCP deploy scripts need the RDS VPC ID, CIDR, and security group ID. Use `find_db_vpc_cidr.sh` to retrieve them:

```bash
./find_db_vpc_cidr.sh agentcore-strands-dev-demo-postgres-mcp
```

Example output:

```
DB Instance:  agentcore-strands-dev-demo-postgres-mcp
VPC ID:       vpc-0f9c8a9f812ceda37
VPC CIDR:     172.31.0.0/16
Security GID: sg-0643065955d9a5d86
```

Update the defaults in both deploy scripts with these values:

```bash
# In deploy_views_mcp_cf.sh and deploy_admin_mcp_cf.sh:
PEER_VPC_ID="<VPC ID>"
PEER_VPC_CIDR="<VPC CIDR>"
RDS_SECURITY_GROUP_ID="<Security GID>"
```

Also update `DATABASE_URI` in each script with the appropriate role URI from Secrets Manager:
- `deploy_views_mcp_cf.sh` → use the **views** role URI (`text_to_sql_views_ro`)
- `deploy_admin_mcp_cf.sh` → use the **admin** URI (`demo_admin`)

### Step 5 — Deploy the MCP servers

**Views MCP server** (tenant-scoped, read-only analytics views):

```bash
./deploy_views_mcp_cf.sh
```

**Admin MCP server** (unrestricted, full database access):

```bash
./deploy_admin_mcp_cf.sh
```

Both scripts handle create vs. update automatically and delete/recreate if the stack is in `ROLLBACK_COMPLETE`. Stack outputs including the MCP endpoint URL are printed on completion.

### Step 6 — Deploy the AgentCore agent runtime

```bash
./deploy_agentcore_agent_cf.sh
```

## Test

Open and run `agentcore_tutorial.ipynb` in Jupyter. The notebook automatically resolves all endpoints and API keys from the CloudFormation stack outputs — no manual configuration required.

The notebook runs the following test cases:

| Example | MCP | Expected |
|---|---|---|
| V1. KPI query — tenant-a | Views | ✅ pass |
| V2. KPI query — tenant-z | Views | ❌ fail (tenant not allowed) |
| V3. List accessible tables | Views | ✅ pass (approved views only) |
| V4. INSERT / DELETE | Views | ❌ fail (read-only user) |
| A1. List all tables | Admin | ✅ pass (full schema) |
| A2. Same KPI query as V1 | Admin | ✅ pass (all tenants visible) |

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
