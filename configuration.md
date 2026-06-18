# Configuration Reference

This document covers all CLI arguments, flags, and environment variables for the PostgreSQL MCP Server.

---

## Command-Line Arguments

### Positional

| Argument | Type | Description | Example |
|---|---|---|---|
| `database_url` | `string` | PostgreSQL connection URL. Can be omitted if `DATABASE_URI` is set. | `postgresql://user:pass@host:5432/dbname` |

---

### Server Behavior

| Flag | Type | Default | Possible Values | Description |
|---|---|---|---|---|
| `--server-mode` | `string` | `admin` (or `$MCP_SERVER_MODE`) | `admin`, `tenant` | Top-level operating mode. `admin` exposes full database introspection and query tools. `tenant` exposes a restricted, row-level-security–enforced query surface for multi-tenant deployments. |
| `--access-mode` | `string` | `unrestricted` (admin) / `restricted` (tenant) | `unrestricted`, `restricted` | SQL access level within admin mode. `unrestricted` allows all SQL including writes; `restricted` wraps queries in a `SafeSqlDriver` with a 30-second timeout and read-only enforcement. Tenant mode always uses `restricted` regardless of this flag. |
| `--tenant-config` | `string` | `$TENANT_CONFIG` | File path | Path to the tenant-mode JSON configuration file. Required when `--server-mode tenant` is set. |

---

### Transport

| Flag | Type | Default | Possible Values | Description |
|---|---|---|---|---|
| `--transport` | `string` | `stdio` | `stdio`, `sse`, `streamable-http` | MCP transport protocol. `stdio` is used by local MCP clients (e.g. Claude Desktop). `sse` and `streamable-http` expose an HTTP server. Tenant mode requires `streamable-http`. |
| `--sse-host` | `string` | `localhost` | Any valid hostname or IP | Bind host for the SSE HTTP server. |
| `--sse-port` | `integer` | `8000` | Any valid port | Port for the SSE HTTP server. |
| `--streamable-http-host` | `string` | `localhost` | Any valid hostname or IP | Bind host for the streamable HTTP server. |
| `--streamable-http-port` | `integer` | `8000` | Any valid port | Port for the streamable HTTP server. |

---

### Authentication

| Flag | Type | Default | Description |
|---|---|---|---|
| `--api-key` | `string` | `$MCP_API_KEY` | Static API key required in the configured HTTP header for admin-mode SSE and streamable-HTTP transports. Ignored for `stdio`. Has no effect in tenant mode (use tenant config principals instead). |
| `--api-key-header` | `string` | `x-api-key` (or `$MCP_API_KEY_HEADER`) | HTTP header name that must carry the API key. |

---

### AWS / RDS IAM Auth

| Flag | Type | Default | Description |
|---|---|---|---|
| `--rds-iam-auth` | `bool` flag | Enabled if `DATABASE_IAM_AUTH` is set | Use short-lived AWS IAM tokens as the database password instead of the static password embedded in the connection URL. Tokens are refreshed automatically before expiry. |
| `--no-rds-iam-auth` | `bool` flag | — | Explicitly disable RDS IAM auth even if `DATABASE_IAM_AUTH` is set in the environment. |
| `--aws-region` | `string` | `$DATABASE_AWS_REGION` or `$AWS_REGION` | AWS region used to generate RDS IAM auth tokens. Required when `--rds-iam-auth` is active and cannot be inferred from the RDS hostname. |

---

### DNS Rebinding Protection

| Flag | Type | Default | Description |
|---|---|---|---|
| `--allow-host` | `string` (repeatable) | `$MCP_ALLOWED_HOSTS` (CSV) | Allowed `Host` header value for DNS rebinding protection. Pass the flag multiple times to allow multiple hosts (e.g. `--allow-host example.com:8000 --allow-host api.example.com`). When `localhost` / `127.0.0.1` / `::1` is the bind host and no overrides are given, common localhost patterns are pre-allowed. |
| `--allow-origin` | `string` (repeatable) | `$MCP_ALLOWED_ORIGINS` (CSV) | Allowed `Origin` header value. Repeat to allow multiple origins. |
| `--disable-dns-rebinding-protection` | `bool` flag | Enabled by default for non-localhost; `$MCP_DISABLE_DNS_REBINDING_PROTECTION` | Disable the Host/Origin header check entirely. Useful behind a trusted reverse proxy that strips or rewrites headers. |
| `--enable-dns-rebinding-protection` | `bool` flag | — | Explicitly re-enable DNS rebinding protection (overrides env variable). |

---

## Environment Variables

### Database

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `DATABASE_URI` | `string` | Yes (if no positional arg) | — | PostgreSQL connection URL. Takes precedence over the positional `database_url` argument. Example: `postgresql://app:secret@db.example.com:5432/mydb` |
| `DATABASE_IAM_AUTH` | `string` (truthy) | No | — | Set to `1`, `true`, `yes`, or `on` to enable AWS RDS IAM token authentication. Equivalent to passing `--rds-iam-auth`. |
| `DATABASE_AWS_REGION` | `string` | Conditional | — | AWS region for RDS IAM token generation. Used when `DATABASE_IAM_AUTH` is set. Falls back to `AWS_REGION` if unset. Example: `us-east-1` |
| `AWS_REGION` | `string` | Conditional | — | Fallback AWS region when `DATABASE_AWS_REGION` is not set. |

---

### Server Mode

| Variable | Type | Default | Possible Values | Description |
|---|---|---|---|---|
| `MCP_SERVER_MODE` | `string` | `admin` | `admin`, `tenant` | Sets the default server mode. Overridden by `--server-mode`. |
| `TENANT_CONFIG` | `string` | — | File path | Default path to the tenant-mode JSON config file. Overridden by `--tenant-config`. |

---

### HTTP Auth

| Variable | Type | Default | Description |
|---|---|---|---|
| `MCP_API_KEY` | `string` | — | Static API key for admin-mode HTTP transports. Equivalent to `--api-key`. |
| `MCP_API_KEY_HEADER` | `string` | `x-api-key` | HTTP header name that must carry `MCP_API_KEY`. Equivalent to `--api-key-header`. |

---

### DNS Rebinding Protection

| Variable | Type | Default | Truthy Values | Description |
|---|---|---|---|---|
| `MCP_ALLOWED_HOSTS` | `string` (CSV) | — | — | Comma-separated list of allowed `Host` header values. Example: `example.com:8000,api.example.com` |
| `MCP_ALLOWED_ORIGINS` | `string` (CSV) | — | — | Comma-separated list of allowed `Origin` header values. Example: `https://example.com,https://app.example.com` |
| `MCP_DISABLE_DNS_REBINDING_PROTECTION` | `string` (truthy) | — | `1`, `true`, `yes`, `on` | Disable the Host/Origin check for HTTP transports. Equivalent to `--disable-dns-rebinding-protection`. |

---

### AWS Marketplace (Advanced)

| Variable | Type | Default | Description |
|---|---|---|---|
| `AWS_MARKETPLACE_PUBLIC_KEY_VERSION` | `integer` | `1` | Override the public key version sent during AWS Marketplace container usage registration. Only relevant when deploying via the AWS Marketplace listing. |

---

## Mode Constraints

| Server Mode | Allowed Transport | Allowed Access Mode | Notes |
|---|---|---|---|
| `admin` | `stdio`, `sse`, `streamable-http` | `unrestricted` (default), `restricted` | Full database tooling surface. |
| `tenant` | `streamable-http` only | `restricted` (always) | Requires `--tenant-config`. API key auth is ignored; use tenant config principals instead. |

---

## Examples

### Restricted admin mode over SSE

```bash
postgres-mcp \
  --transport sse \
  --sse-host 0.0.0.0 \
  --sse-port 8000 \
  --access-mode restricted \
  --api-key supersecret \
  postgresql://user:pass@db:5432/mydb
```

### Tenant mode with streamable HTTP

```bash
postgres-mcp \
  --server-mode tenant \
  --transport streamable-http \
  --streamable-http-host 0.0.0.0 \
  --streamable-http-port 8000 \
  --tenant-config /etc/mcp/tenant.json \
  postgresql://readonly_user@db:5432/mydb
```

### RDS with IAM authentication

```bash
DATABASE_URI="postgresql://app@mydb.cluster-xyz.us-east-1.rds.amazonaws.com:5432/prod" \
DATABASE_IAM_AUTH=true \
DATABASE_AWS_REGION=us-east-1 \
postgres-mcp --transport streamable-http --streamable-http-host 0.0.0.0
```

### Environment-only configuration (e.g. Docker / ECS)

```bash
DATABASE_URI=postgresql://app:secret@db:5432/mydb
MCP_SERVER_MODE=admin
MCP_API_KEY=supersecret
MCP_ALLOWED_HOSTS=mcp.internal:8000
MCP_ALLOWED_ORIGINS=https://mcp.internal
```
