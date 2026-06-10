enable_demo_postgres_mcp_database        = true
demo_postgres_mcp_publicly_accessible    = true
demo_postgres_mcp_allowed_cidr_blocks    = ["86.92.160.166/32", "35.151.254.85/32"]
demo_postgres_mcp_schema_initializer     = "docker"
demo_postgres_mcp_seed_scale_factor      = 2
demo_postgres_mcp_run_schema_initializer = true

demo_postgres_mcp_subnet_ids = [
  "subnet-055e78fe02d648191",
  "subnet-09d5131dc6363f613",
  "subnet-0d9c57c0d0892ec8d",
  "subnet-0c1b89aba4b234aa9",
  "subnet-073367497c300306b",
  "subnet-04a19e1c54a45a181",
]
