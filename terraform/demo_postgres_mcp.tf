locals {
  demo_postgres_mcp_db_identifier = lower(replace("${local.name_prefix}-demo-postgres-mcp", "_", "-"))
  demo_postgres_mcp_db_name       = replace(var.demo_postgres_mcp_database_name, "-", "_")
  demo_postgres_mcp_endpoint      = var.enable_demo_postgres_mcp_database ? aws_db_instance.demo_postgres_mcp[0].address : ""
  demo_postgres_mcp_port          = var.enable_demo_postgres_mcp_database ? aws_db_instance.demo_postgres_mcp[0].port : 5432

  demo_postgres_mcp_admin_uri = var.enable_demo_postgres_mcp_database ? "postgresql://${var.demo_postgres_mcp_master_username}:${random_password.demo_postgres_mcp_master[0].result}@${local.demo_postgres_mcp_endpoint}:${local.demo_postgres_mcp_port}/${local.demo_postgres_mcp_db_name}" : ""
  demo_postgres_mcp_raw_uri   = var.enable_demo_postgres_mcp_database ? "postgresql://${var.demo_postgres_mcp_raw_role_name}:${random_password.demo_postgres_mcp_raw_role[0].result}@${local.demo_postgres_mcp_endpoint}:${local.demo_postgres_mcp_port}/${local.demo_postgres_mcp_db_name}" : ""
  demo_postgres_mcp_views_uri = var.enable_demo_postgres_mcp_database ? "postgresql://${var.demo_postgres_mcp_views_role_name}:${random_password.demo_postgres_mcp_views_role[0].result}@${local.demo_postgres_mcp_endpoint}:${local.demo_postgres_mcp_port}/${local.demo_postgres_mcp_db_name}" : ""
}

data "aws_vpc" "demo_postgres_mcp_default" {
  count = var.enable_demo_postgres_mcp_database && var.demo_postgres_mcp_vpc_id == null ? 1 : 0

  default = true
}

data "aws_subnets" "demo_postgres_mcp_default" {
  count = var.enable_demo_postgres_mcp_database && length(var.demo_postgres_mcp_subnet_ids) == 0 ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [coalesce(var.demo_postgres_mcp_vpc_id, data.aws_vpc.demo_postgres_mcp_default[0].id)]
  }
}

resource "random_password" "demo_postgres_mcp_master" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  length  = 32
  special = false
}

resource "random_password" "demo_postgres_mcp_raw_role" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  length  = 32
  special = false
}

resource "random_password" "demo_postgres_mcp_views_role" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  length  = 32
  special = false
}

resource "aws_security_group" "demo_postgres_mcp_db" {
  count = var.enable_demo_postgres_mcp_database && var.demo_postgres_mcp_create_security_group ? 1 : 0

  name        = "${local.name_prefix}-demo-postgres-mcp-db"
  description = "Postgres access for the demo Postgres MCP database"
  vpc_id      = coalesce(var.demo_postgres_mcp_vpc_id, try(data.aws_vpc.demo_postgres_mcp_default[0].id, null))

  dynamic "ingress" {
    for_each = var.demo_postgres_mcp_allowed_cidr_blocks
    content {
      description = "Postgres demo access"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_db_subnet_group" "demo_postgres_mcp" {
  count = var.enable_demo_postgres_mcp_database && length(var.demo_postgres_mcp_subnet_ids) > 0 ? 1 : 0

  name       = "${local.name_prefix}-demo-postgres-mcp"
  subnet_ids = var.demo_postgres_mcp_subnet_ids
  tags       = local.tags
}

resource "aws_db_instance" "demo_postgres_mcp" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  identifier              = local.demo_postgres_mcp_db_identifier
  engine                  = "postgres"
  engine_version          = var.demo_postgres_mcp_engine_version
  instance_class          = var.demo_postgres_mcp_instance_class
  allocated_storage       = var.demo_postgres_mcp_allocated_storage
  db_name                 = local.demo_postgres_mcp_db_name
  username                = var.demo_postgres_mcp_master_username
  password                = random_password.demo_postgres_mcp_master[0].result
  db_subnet_group_name    = length(var.demo_postgres_mcp_subnet_ids) > 0 ? aws_db_subnet_group.demo_postgres_mcp[0].name : null
  vpc_security_group_ids  = concat(var.demo_postgres_mcp_vpc_security_group_ids, var.demo_postgres_mcp_create_security_group ? [aws_security_group.demo_postgres_mcp_db[0].id] : [])
  publicly_accessible     = var.demo_postgres_mcp_publicly_accessible
  backup_retention_period = var.demo_postgres_mcp_backup_retention_days
  deletion_protection     = var.demo_postgres_mcp_deletion_protection
  skip_final_snapshot     = var.demo_postgres_mcp_skip_final_snapshot
  apply_immediately       = true

  tags = local.tags

  lifecycle {
    precondition {
      condition     = !var.demo_postgres_mcp_publicly_accessible || var.demo_postgres_mcp_create_security_group || length(var.demo_postgres_mcp_vpc_security_group_ids) > 0
      error_message = "Public demo Postgres MCP RDS requires a Terraform-managed security group or explicit existing security groups."
    }
  }
}

resource "aws_secretsmanager_secret" "demo_postgres_mcp_admin_database_uri" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  name                    = "${local.name_prefix}/demo-postgres-mcp/admin-database-uri"
  recovery_window_in_days = var.demo_postgres_mcp_secret_recovery_window_days
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "demo_postgres_mcp_admin_database_uri" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  secret_id     = aws_secretsmanager_secret.demo_postgres_mcp_admin_database_uri[0].id
  secret_string = local.demo_postgres_mcp_admin_uri
}

resource "aws_secretsmanager_secret" "demo_postgres_mcp_raw_database_uri" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  name                    = "${local.name_prefix}/demo-postgres-mcp/raw-database-uri"
  recovery_window_in_days = var.demo_postgres_mcp_secret_recovery_window_days
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "demo_postgres_mcp_raw_database_uri" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  secret_id     = aws_secretsmanager_secret.demo_postgres_mcp_raw_database_uri[0].id
  secret_string = local.demo_postgres_mcp_raw_uri
}

resource "aws_secretsmanager_secret" "demo_postgres_mcp_views_database_uri" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  name                    = "${local.name_prefix}/demo-postgres-mcp/views-database-uri"
  recovery_window_in_days = var.demo_postgres_mcp_secret_recovery_window_days
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "demo_postgres_mcp_views_database_uri" {
  count = var.enable_demo_postgres_mcp_database ? 1 : 0

  secret_id     = aws_secretsmanager_secret.demo_postgres_mcp_views_database_uri[0].id
  secret_string = local.demo_postgres_mcp_views_uri
}

resource "terraform_data" "demo_postgres_mcp_schema" {
  count = var.enable_demo_postgres_mcp_database && var.demo_postgres_mcp_run_schema_initializer ? 1 : 0

  triggers_replace = {
    schema_sha        = filesha256("${path.module}/sql/demo_postgres_mcp_schema.sql")
    db_instance_id    = aws_db_instance.demo_postgres_mcp[0].id
    raw_role_name     = var.demo_postgres_mcp_raw_role_name
    views_role_name   = var.demo_postgres_mcp_views_role_name
    seed_scale_factor = tostring(var.demo_postgres_mcp_seed_scale_factor)
    initializer       = var.demo_postgres_mcp_schema_initializer
  }

  provisioner "local-exec" {
    command = <<-EOT
      if [ "$SCHEMA_INITIALIZER" = "docker" ]; then
        docker run --rm -i postgres:16-alpine \
          psql "$DATABASE_URL" \
          -v ON_ERROR_STOP=1 \
          -v raw_role="$RAW_ROLE" \
          -v raw_role_password="$RAW_ROLE_PASSWORD" \
          -v views_role="$VIEWS_ROLE" \
          -v views_role_password="$VIEWS_ROLE_PASSWORD" \
          -v seed_scale_factor="$SEED_SCALE_FACTOR" \
          < "${path.module}/sql/demo_postgres_mcp_schema.sql"
      else
        psql "$DATABASE_URL" \
          -v ON_ERROR_STOP=1 \
          -v raw_role="$RAW_ROLE" \
          -v raw_role_password="$RAW_ROLE_PASSWORD" \
          -v views_role="$VIEWS_ROLE" \
          -v views_role_password="$VIEWS_ROLE_PASSWORD" \
          -v seed_scale_factor="$SEED_SCALE_FACTOR" \
          -f "${path.module}/sql/demo_postgres_mcp_schema.sql"
      fi
    EOT

    environment = {
      DATABASE_URL        = local.demo_postgres_mcp_admin_uri
      RAW_ROLE            = var.demo_postgres_mcp_raw_role_name
      RAW_ROLE_PASSWORD   = random_password.demo_postgres_mcp_raw_role[0].result
      SCHEMA_INITIALIZER  = var.demo_postgres_mcp_schema_initializer
      VIEWS_ROLE          = var.demo_postgres_mcp_views_role_name
      VIEWS_ROLE_PASSWORD = random_password.demo_postgres_mcp_views_role[0].result
      SEED_SCALE_FACTOR   = tostring(var.demo_postgres_mcp_seed_scale_factor)
    }
  }

  depends_on = [
    aws_db_instance.demo_postgres_mcp,
    aws_secretsmanager_secret_version.demo_postgres_mcp_admin_database_uri,
    aws_secretsmanager_secret_version.demo_postgres_mcp_raw_database_uri,
    aws_secretsmanager_secret_version.demo_postgres_mcp_views_database_uri
  ]
}
