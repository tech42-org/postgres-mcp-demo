variable "project" {
  description = "Project name used in resource names."
  type        = string
  default     = "agentcore-strands"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "enable_demo_postgres_mcp_database" {
  description = "Create an RDS PostgreSQL demo database for text-to-SQL raw-tables-vs-views comparisons."
  type        = bool
  default     = true
}

variable "demo_postgres_mcp_database_name" {
  description = "Database name for the text-to-SQL demo database."
  type        = string
  default     = "demo_postgres_mcp"
}

variable "demo_postgres_mcp_master_username" {
  description = "Master username for the text-to-SQL demo RDS instance."
  type        = string
  default     = "demo_admin"
}

variable "demo_postgres_mcp_engine_version" {
  description = "PostgreSQL engine version for the text-to-SQL demo RDS instance."
  type        = string
  default     = "16"
}

variable "demo_postgres_mcp_instance_class" {
  description = "RDS instance class for the text-to-SQL demo database."
  type        = string
  default     = "db.t4g.micro"
}

variable "demo_postgres_mcp_allocated_storage" {
  description = "Allocated storage in GB for the text-to-SQL demo database."
  type        = number
  default     = 20
}

variable "demo_postgres_mcp_backup_retention_days" {
  description = "Backup retention days for the text-to-SQL demo database."
  type        = number
  default     = 0
}

variable "demo_postgres_mcp_deletion_protection" {
  description = "Enable deletion protection for the text-to-SQL demo database."
  type        = bool
  default     = false
}

variable "demo_postgres_mcp_skip_final_snapshot" {
  description = "Skip final snapshot when destroying the text-to-SQL demo database."
  type        = bool
  default     = true
}

variable "demo_postgres_mcp_publicly_accessible" {
  description = "Whether the text-to-SQL demo RDS instance is publicly accessible. Public access is convenient for demos but should be CIDR-restricted."
  type        = bool
  default     = false
}

variable "demo_postgres_mcp_vpc_id" {
  description = "VPC ID for the text-to-SQL demo database security group. Defaults to the account default VPC when a security group is created."
  type        = string
  default     = null
}

variable "demo_postgres_mcp_subnet_ids" {
  description = "Optional subnet IDs for a text-to-SQL demo DB subnet group. Empty uses the account default DB subnet group."
  type        = list(string)
  default     = []
}

variable "demo_postgres_mcp_vpc_security_group_ids" {
  description = "Existing security group IDs attached to the text-to-SQL demo RDS instance."
  type        = list(string)
  default     = []
}

variable "demo_postgres_mcp_create_security_group" {
  description = "Create a security group for the text-to-SQL demo RDS instance."
  type        = bool
  default     = true
}

variable "demo_postgres_mcp_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to connect to the text-to-SQL demo RDS instance when Terraform creates the security group."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.demo_postgres_mcp_allowed_cidr_blocks : !contains(["0.0.0.0/0", "::/0"], cidr)
    ])
    error_message = "demo_postgres_mcp_allowed_cidr_blocks must not include 0.0.0.0/0 or ::/0."
  }
}

variable "demo_postgres_mcp_raw_role_name" {
  description = "Read-only role that can query the complex raw schema only."
  type        = string
  default     = "text_to_sql_raw_ro"
}

variable "demo_postgres_mcp_views_role_name" {
  description = "Read-only role that can query the simplified analytics view schema only."
  type        = string
  default     = "text_to_sql_views_ro"
}

variable "demo_postgres_mcp_seed_scale_factor" {
  description = "Scale factor for deterministic demo data generation. 1 creates hundreds of rows; larger values create more synthetic volume."
  type        = number
  default     = 1

  validation {
    condition     = var.demo_postgres_mcp_seed_scale_factor >= 1 && var.demo_postgres_mcp_seed_scale_factor <= 20
    error_message = "demo_postgres_mcp_seed_scale_factor must be between 1 and 20."
  }
}

variable "demo_postgres_mcp_run_schema_initializer" {
  description = "Run the local psql schema initializer after creating the RDS instance. Requires psql and network access from the Terraform runner to the database."
  type        = bool
  default     = true
}

variable "demo_postgres_mcp_schema_initializer" {
  description = "Local command style used to run the text-to-SQL demo schema initializer. Use psql when psql is installed locally, or docker to run psql from postgres:16-alpine."
  type        = string
  default     = "psql"

  validation {
    condition     = contains(["psql", "docker"], var.demo_postgres_mcp_schema_initializer)
    error_message = "demo_postgres_mcp_schema_initializer must be psql or docker."
  }
}

variable "demo_postgres_mcp_secret_recovery_window_days" {
  description = "Secrets Manager recovery window for generated text-to-SQL demo database URI secrets. Use 0 for immediate deletion in disposable demos."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}
