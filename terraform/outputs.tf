output "demo_postgres_mcp_database_endpoint" {
  description = "Endpoint for the text-to-SQL demo database."
  value       = var.enable_demo_postgres_mcp_database ? aws_db_instance.demo_postgres_mcp[0].endpoint : null
}

output "demo_postgres_mcp_admin_database_uri_secret_arn" {
  description = "Secrets Manager ARN for the text-to-SQL demo admin database URI."
  value       = var.enable_demo_postgres_mcp_database ? aws_secretsmanager_secret.demo_postgres_mcp_admin_database_uri[0].arn : null
}

output "demo_postgres_mcp_raw_database_uri_secret_arn" {
  description = "Secrets Manager ARN for the raw complex-table read-only role database URI."
  value       = var.enable_demo_postgres_mcp_database ? aws_secretsmanager_secret.demo_postgres_mcp_raw_database_uri[0].arn : null
}

output "demo_postgres_mcp_views_database_uri_secret_arn" {
  description = "Secrets Manager ARN for the analytics-view read-only role database URI."
  value       = var.enable_demo_postgres_mcp_database ? aws_secretsmanager_secret.demo_postgres_mcp_views_database_uri[0].arn : null
}

output "demo_postgres_mcp_raw_role_name" {
  description = "Database role name for the raw complex-table scenario."
  value       = var.enable_demo_postgres_mcp_database ? var.demo_postgres_mcp_raw_role_name : null
}

output "demo_postgres_mcp_views_role_name" {
  description = "Database role name for the simplified analytics-view scenario."
  value       = var.enable_demo_postgres_mcp_database ? var.demo_postgres_mcp_views_role_name : null
}
