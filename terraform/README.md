# AgentCore Strands Terraform

This stack keeps the deployment intentionally small:

- one AgentCore runtime for the containerized Strands app
- one AgentCore runtime endpoint
- one AgentCore Memory store
- one Lambda proxy with a Lambda Function URL
- optional static React frontend on private S3 behind CloudFront
- optional text-to-SQL demo Postgres database
- IAM roles and CloudWatch logs needed by those resources

Build and push the Docker image from `../docker` first, then pass the image URI:

```bash
terraform init
terraform apply -var='container_image_uri=123456789012.dkr.ecr.us-east-1.amazonaws.com/agentcore-strands:latest'
```

The Lambda proxy accepts the same JSON payload as the runtime. It adds a runtime session ID when one is not supplied, injects the Terraform-created `memory_id`, and invokes AgentCore with IAM.

## Lambda Proxy Template

The default proxy source lives in `lambda_stream/` and is intended to be reusable
across AgentCore chat apps. A frontend can send a minimal body:

```json
{
  "prompt": "Show daily revenue",
  "sessionId": "browser-session-id",
  "userId": "daan",
  "tenantId": "tenant-a"
}
```

The proxy fills in model defaults, AgentCore Memory, optional MCP config, and
optional DynamoDB conversation history config before invoking the runtime. The
main template knobs are:

- `lambda_proxy_auth_mode`
- `lambda_api_key`, `lambda_api_key_header`, `lambda_api_key_query_param`
- `lambda_jwt_issuer`, `lambda_jwt_audience`, `lambda_jwt_jwks_uri`
- `lambda_jwt_user_id_claims`, `lambda_jwt_tenant_id_claims`
- `lambda_enable_sessions_api`, `lambda_enable_history_api`
- `lambda_enable_usage_limits`, `lambda_rate_limit_per_minute`, `lambda_daily_token_budget`
- `lambda_cors_allowed_origins`, `lambda_cors_allowed_headers`
- `lambda_extra_environment_variables`
- `user_tenant_map`
- `enable_conversation_history`
- `enable_postgres_mcp`

See `lambda_stream/README.md` for the route and environment contract.

## Python FastAPI Proxy Option

This stack also includes an optional Python implementation in
`lambda_fastapi/`. It uses FastAPI plus AWS Lambda Web Adapter, so it keeps the
Lambda Function URL deployment shape while making the proxy code portable to a
future ECS/App Runner service.

The Node proxy remains the default:

```hcl
lambda_proxy_implementation = "node"
```

To switch the Function URL to the FastAPI proxy, build and push the image from
`lambda_fastapi/`, then set:

```hcl
lambda_proxy_implementation = "fastapi"
lambda_fastapi_image_uri    = "<account>.dkr.ecr.<region>.amazonaws.com/agentcore-proxy-fastapi:<tag>"
```

See `lambda_fastapi/README.md` for build notes.

## Static Frontend Hosting

Terraform can also publish the Vite frontend as a static site. Build the
frontend first:

```bash
cd ../frontend
npm run build
```

Then enable hosting:

```hcl
enable_frontend = true
frontend_dist_path = "../frontend/dist"
```

Terraform creates:

- a private S3 bucket for the static assets
- a CloudFront distribution with Origin Access Control
- a generated `config.json` containing the Lambda Function URL and frontend
  defaults
- Lambda Function URL CORS entries for the CloudFront origin

For quick demos, set `frontend_include_lambda_api_key = true` to prefill the
browser API key. This makes the key public in `config.json`, so use JWT/Cognito
or another real auth layer for production.

## Text-To-SQL Demo Database

Terraform can create a disposable RDS PostgreSQL database specifically for
showing why a view layer improves text-to-SQL reliability.

Enable it with:

```hcl
enable_demo_postgres_mcp_database = true

# Required when the Terraform runner connects over the public internet.
demo_postgres_mcp_publicly_accessible = true
demo_postgres_mcp_allowed_cidr_blocks = ["203.0.113.10/32"]
```

The initializer creates:

- `raw_app.*`: a deliberately normalized ecommerce schema with customers,
  orders, order lines, payments, shipments, products, categories, suppliers,
  inventory, support tickets, marketing events, and web sessions
- `analytics_app.*`: simplified business-grain views such as
  `customer_revenue_summary`, `daily_sales_summary`,
  `product_sales_summary`, `monthly_product_sales_summary`, `payment_health_daily`,
  `fulfillment_health_daily`, and `executive_kpis`
- `demo_app.text_to_sql_scenario_metrics`: comparison metrics for raw tables
  versus analytics views
- `demo_app.text_to_sql_workload`: example business questions with expected
  chart type and raw-vs-view query shape
- `text_to_sql_raw_ro`: read-only role for the complex raw-table scenario
- `text_to_sql_views_ro`: read-only role for the optimized view scenario

Both scenarios are multi-tenant. The raw role is protected by PostgreSQL RLS on
`raw_app` tables. The view role only sees tenant-filtered `analytics_app` views.
Both use `current_setting('app.tenant_id', true)`, so callers must set
`app.tenant_id` for the active tenant before querying.

Terraform stores separate database URI secrets for both scenarios:

```txt
demo_postgres_mcp_raw_database_uri_secret_arn
demo_postgres_mcp_views_database_uri_secret_arn
```

Use the raw secret for the "hard mode" MCP/database connection and the views
secret for the improved version. That demonstrates both schema design and
database authentication boundaries: the raw role cannot read `analytics_app`,
and the view role cannot read `raw_app`.

The schema initializer can use local `psql` or Docker:

```hcl
demo_postgres_mcp_schema_initializer = "psql"
# or
demo_postgres_mcp_schema_initializer = "docker"
```

The machine running Terraform must have the selected tool installed and network
access to the DB endpoint. Set `demo_postgres_mcp_run_schema_initializer = false`
if you want Terraform to create only the RDS instance and secrets, then run
`sql/demo_postgres_mcp_schema.sql` manually later.
