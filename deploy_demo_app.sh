#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$SCRIPT_DIR/frontend"

# ── Required configuration ────────────────────────────────────────────────────
export AGENTCORE_RUNTIME_ARN="arn:aws:bedrock-agentcore:us-east-1:008701887645:runtime/demo_mcp_agent_dev_a86e3650-EFclBj4xvn"
export VIEWS_MCP_URL="http://demo-p-LoadB-dNPu6rTqpsLI-1934868064.us-east-1.elb.amazonaws.com/mcp"
export VIEWS_MCP_API_KEY="8P624Amc1ky7TvSxivG624NHZz6BGUFsOHtKneAUyuD9H2Xh"
export ADMIN_MCP_URL="http://demo-p-LoadB-FxFz6BxZjB4g-1519957086.us-east-1.elb.amazonaws.com/mcp"
export ADMIN_MCP_API_KEY="mObfhB3j8eGyZ6KHtBCZ3wP3diIx3o3tb5hdw99OEvmIxtjH"

# ── Optional overrides (defaults match server.py) ─────────────────────────────
export AWS_PROFILE="${AWS_PROFILE:-sandbox}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export MODEL_ID="${MODEL_ID:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"
export PORT="${PORT:-8000}"

: "${AGENTCORE_RUNTIME_ARN:?AGENTCORE_RUNTIME_ARN is required}"
: "${VIEWS_MCP_URL:?VIEWS_MCP_URL is required}"
: "${VIEWS_MCP_API_KEY:?VIEWS_MCP_API_KEY is required}"
: "${ADMIN_MCP_URL:?ADMIN_MCP_URL is required}"
: "${ADMIN_MCP_API_KEY:?ADMIN_MCP_API_KEY is required}"

# ── Install dependencies ──────────────────────────────────────────────────────
echo "Installing dependencies..."
pip install -r "$FRONTEND_DIR/requirements.txt" --quiet

# ── Launch ────────────────────────────────────────────────────────────────────
echo "Starting demo app → http://localhost:${PORT}"
cd "$FRONTEND_DIR"
python server.py

