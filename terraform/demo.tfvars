enable_demo_postgres_mcp_database        = true
demo_postgres_mcp_publicly_accessible    = true
demo_postgres_mcp_allowed_cidr_blocks    = ["86.92.160.166/32", "35.151.254.85/32"]
demo_postgres_mcp_schema_initializer     = "docker"
demo_postgres_mcp_seed_scale_factor      = 2
demo_postgres_mcp_run_schema_initializer = true

demo_postgres_mcp_subnet_ids = [
  "subnet-0ba2b443ef38fb51c",
  "subnet-0153e9727904b13c8",
  "subnet-0fbbd905df79e993c",
  "subnet-0b3efce2530da1e6f",
  "subnet-09f33d9fd40d6e6de",
  "subnet-0fb84a013043c65cc",
  "subnet-0d535227c4b323bc9",
  "subnet-07508893604fd8f70",
  "subnet-00b878b8ab2dd3b56",
  "subnet-0386c2e4f76eff6a0",
  "subnet-0c410b2a24e741075",
]
