# SQL Assets

## `demo_postgres_mcp_schema.sql`

Initializes the optional text-to-SQL demo database.

It creates three schemas:

- `raw_app`: normalized ecommerce base tables for the difficult text-to-SQL
  scenario.
- `analytics_app`: business-grain views for the improved text-to-SQL scenario.
- `demo_app`: comparison metrics and example workload prompts.

It also creates two database roles:

- `text_to_sql_raw_ro`: can read `raw_app` plus the demo metric views.
- `text_to_sql_views_ro`: can read `analytics_app` plus the demo metric views.

Tenant isolation is enforced in both scenarios:

- `raw_app` uses PostgreSQL RLS policies for `text_to_sql_raw_ro`.
- `analytics_app` views filter on `current_setting('app.tenant_id', true)` for
  `text_to_sql_views_ro`.

Callers should set the active tenant before querying:

```sql
SELECT set_config('app.tenant_id', 'tenant-a', false);
```

Terraform runs this file through `psql` when
`enable_demo_postgres_mcp_database = true` and
`demo_postgres_mcp_run_schema_initializer = true`.
