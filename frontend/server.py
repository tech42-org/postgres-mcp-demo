#!/usr/bin/env python3
"""
Text-to-SQL Agent — Local Web Server
─────────────────────────────────────
Serves the chatbot frontend (index.html) and streams AgentCore events to the
browser via Server-Sent Events.

Usage:
    pip install fastapi uvicorn boto3
    python server.py            # reads config from env vars below

Required environment variables (or edit the defaults directly):
    AGENTCORE_RUNTIME_ARN   — e.g. arn:aws:bedrock-agentcore:us-east-1:...:runtime/...
    VIEWS_MCP_URL           — http://...elb.amazonaws.com/mcp
    VIEWS_MCP_API_KEY       — secret key for the Views MCP server
    ADMIN_MCP_URL           — http://...elb.amazonaws.com/mcp
    ADMIN_MCP_API_KEY       — secret key for the Admin MCP server

Optional:
    AWS_PROFILE             — boto3 named profile  (default: sandbox)
    AWS_REGION              — AWS region           (default: us-east-1)
    MODEL_ID                — Bedrock model ID     (default: haiku-4-5)
    PORT                    — HTTP port            (default: 8000)
"""

import asyncio
import json
import logging
import os
import threading
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

import boto3
from botocore.config import Config
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("sql-agent")

# ── Configuration ────────────────────────────────────────────────────────────
AWS_PROFILE           = os.getenv("AWS_PROFILE",           "")
AWS_REGION            = os.getenv("AWS_REGION",            "us-east-1")
AGENTCORE_RUNTIME_ARN = os.getenv("AGENTCORE_RUNTIME_ARN", "")
VIEWS_MCP_URL         = os.getenv("VIEWS_MCP_URL",         "")
VIEWS_MCP_API_KEY     = os.getenv("VIEWS_MCP_API_KEY",     "")
ADMIN_MCP_URL         = os.getenv("ADMIN_MCP_URL",         "")
ADMIN_MCP_API_KEY     = os.getenv("ADMIN_MCP_API_KEY",     "")
DEFAULT_MODEL_ID      = os.getenv(
    "MODEL_ID",
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
)
MEMORY_ID             = os.getenv("AGENTCORE_MEMORY_ID", "")
SELECTABLE_MODELS = [
    "us.amazon.nova-2-lite-v1:0",
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
]
PORT     = int(os.getenv("PORT", "8000"))
APP_NAME = os.getenv("APP_NAME", "sqlagent")


def _ssm_param(name: str, default: str) -> str:
    try:
        cfg = Config(connect_timeout=0.5, read_timeout=0.5, retries={"max_attempts": 1})
        client = boto3.client("ssm", region_name=AWS_REGION, config=cfg)
        return client.get_parameter(Name=name)["Parameter"]["Value"]
    except Exception as exc:
        log.warning("SSM param %s unavailable (%s), using default %s", name, exc, default)
        return default


# Use env vars when available; fall back to SSM only at startup (non-blocking via lifespan).
_RL_REQ_ENV = os.getenv("RATE_LIMIT_REQUESTS", "")
_RL_WIN_ENV = os.getenv("RATE_LIMIT_WINDOW", "")

# Start with safe defaults so the server is ready immediately; if env vars are
# absent, SSM values are fetched in the background lifespan task and the
# callable-based limiter picks them up on the next request.
RATE_LIMIT_REQUESTS = int(_RL_REQ_ENV) if _RL_REQ_ENV else 10
RATE_LIMIT_WINDOW   = int(_RL_WIN_ENV) if _RL_WIN_ENV else 60

# ── FastAPI app ───────────────────────────────────────────────────────────────

def _composite_key(request: Request) -> str:
    """Rate-limit key: IP + User-Agent so devices behind the same NAT get separate buckets."""
    ip = get_remote_address(request)
    ua = request.headers.get("user-agent", "")
    return f"{ip}|{ua}"


limiter = Limiter(key_func=_composite_key)


async def _fetch_ssm_rate_limits():
    """Fetch rate-limit params from SSM in a thread after startup (non-blocking)."""
    global RATE_LIMIT_REQUESTS, RATE_LIMIT_WINDOW
    loop = asyncio.get_event_loop()
    if not _RL_REQ_ENV:
        val = await loop.run_in_executor(
            None, lambda: _ssm_param(f"/{APP_NAME}/rate_limit_requests", str(RATE_LIMIT_REQUESTS))
        )
        RATE_LIMIT_REQUESTS = int(val)
        log.info("Rate limit requests from SSM: %d", RATE_LIMIT_REQUESTS)
    if not _RL_WIN_ENV:
        val = await loop.run_in_executor(
            None, lambda: _ssm_param(f"/{APP_NAME}/rate_limit_window", str(RATE_LIMIT_WINDOW))
        )
        RATE_LIMIT_WINDOW = int(val)
        log.info("Rate limit window from SSM: %ds", RATE_LIMIT_WINDOW)


@asynccontextmanager
async def lifespan(app: FastAPI):
    asyncio.create_task(_fetch_ssm_rate_limits())
    yield


app = FastAPI(title="Text-to-SQL Agent", lifespan=lifespan)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

_static_dir = Path(__file__).parent / "static"
if _static_dir.exists():
    app.mount("/static", StaticFiles(directory=_static_dir), name="static")


# ── Helpers ───────────────────────────────────────────────────────────────────

def _get_client():
    """Return a bedrock-agentcore boto3 client."""
    session = boto3.Session(**({} if not AWS_PROFILE else {"profile_name": AWS_PROFILE}), region_name=AWS_REGION)
    return session.client("bedrock-agentcore", region_name=AWS_REGION)


def _build_payload(query: str, mode: str, tenant_id: str, session_id: str, model_id: str = DEFAULT_MODEL_ID) -> dict:
    if mode == "admin":
        mcp_config = {
            "postgres": {
                "transport": "streamable_http",
                "url": ADMIN_MCP_URL,
                "headers": {"x-api-key": ADMIN_MCP_API_KEY},
            }
        }
    else:
        mcp_config = {
            "postgres": {
                "transport": "streamable_http",
                "url": VIEWS_MCP_URL,
                "headers": {
                    "x-api-key": VIEWS_MCP_API_KEY,
                    "x-tenant-id": tenant_id,
                },
            }
        }

    model_config: dict = {
        "model_id":    model_id,
        "region_name": AWS_REGION,
        "temperature": 0,
        "max_tokens":  4096,
    }

    payload: dict = {
        "query":        query,
        "model_config": model_config,
        "mcp_config":   mcp_config,
        "session_id":   session_id,
        "actor_id":     "user-1",
        "user_id":      "demo",
    }
    if MEMORY_ID:
        payload["memory_id"] = MEMORY_ID
    return payload


def _stream_events(payload: dict, q: asyncio.Queue, loop: asyncio.AbstractEventLoop):
    """
    Blocking function (runs in a thread):
    calls AgentCore, parses each NDJSON line, puts parsed dicts onto the queue.
    Puts None as a sentinel when done.
    """
    session_id = payload["session_id"]
    log.info("[%s] _stream_events: starting AgentCore call (arn=%s)", session_id, AGENTCORE_RUNTIME_ARN[:60] + "…" if len(AGENTCORE_RUNTIME_ARN) > 60 else AGENTCORE_RUNTIME_ARN)
    event_count = 0
    try:
        client   = _get_client()
        log.debug("[%s] boto3 client created", session_id)
        response = client.invoke_agent_runtime(
            agentRuntimeArn  = AGENTCORE_RUNTIME_ARN,
            runtimeSessionId = payload["session_id"],
            payload          = json.dumps(payload).encode("utf-8"),
        )
        log.info("[%s] AgentCore responded — HTTP status: %s", session_id, response.get("ResponseMetadata", {}).get("HTTPStatusCode"))

        for raw in response["response"].iter_lines(chunk_size=1):
            if not raw:
                continue
            line = raw.decode("utf-8")
            log.debug("[%s] raw line: %s", session_id, line[:200])
            if line.startswith("data: "):
                line = line[6:]
            try:
                parsed = json.loads(line)
                # AgentCore double-encodes: outer JSON is a string containing "data: {...}"
                if isinstance(parsed, str):
                    inner = parsed.strip()
                    if inner.startswith("data: "):
                        inner = inner[6:]
                    parsed = json.loads(inner)
                event = parsed
            except json.JSONDecodeError:
                log.warning("[%s] non-JSON line: %s", session_id, line[:200])
                event = {"type": "raw", "content": line}
            event_count += 1
            log.debug("[%s] event #%d type=%s", session_id, event_count, event.get("type", "?"))
            asyncio.run_coroutine_threadsafe(q.put(event), loop)

        log.info("[%s] stream finished — %d events total", session_id, event_count)
    except Exception as exc:
        log.exception("[%s] AgentCore call failed: %s", session_id, exc)
        asyncio.run_coroutine_threadsafe(
            q.put({"type": "error", "message": str(exc)}),
            loop,
        )
    finally:
        asyncio.run_coroutine_threadsafe(q.put(None), loop)


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/")
async def serve_index():
    html_path = Path(__file__).parent / "index.html"
    if not html_path.exists():
        return HTMLResponse("<h1>index.html not found — make sure it's in the same directory.</h1>", status_code=404)
    return HTMLResponse(html_path.read_text(encoding="utf-8"))


@app.get("/api/config")
async def get_config():
    """Let the frontend know which fields are configured."""
    return {
        "agentcore_configured":  bool(AGENTCORE_RUNTIME_ARN),
        "views_mcp_configured":  bool(VIEWS_MCP_URL and VIEWS_MCP_API_KEY),
        "admin_mcp_configured":  bool(ADMIN_MCP_URL and ADMIN_MCP_API_KEY),
        "model_id":              DEFAULT_MODEL_ID,
        "selectable_models":     SELECTABLE_MODELS,
        "aws_region":            AWS_REGION,
        "aws_profile":           AWS_PROFILE,
        "rate_limit_requests":   RATE_LIMIT_REQUESTS,
        "rate_limit_window":     RATE_LIMIT_WINDOW,
        "memory_configured":     bool(MEMORY_ID),
    }


@app.post("/api/chat")
@limiter.limit(f"{RATE_LIMIT_REQUESTS}/{RATE_LIMIT_WINDOW} seconds")
async def chat(request: Request):
    """
    POST body: { query, mode, tenant_id }
    Streams Server-Sent Events back to the browser.
    Each event is a JSON-encoded dict with a `type` field.
    """
    body      = await request.json()
    query     = body.get("query", "").strip()
    mode      = body.get("mode", "views")          # "views" | "admin"
    tenant_id = body.get("tenant_id", "tenant-a")
    model_id   = body.get("model_id", DEFAULT_MODEL_ID)
    if model_id not in SELECTABLE_MODELS:
        model_id = DEFAULT_MODEL_ID
    session_id = body.get("session_id") or f"session_{uuid.uuid4().hex}_{int(time.time())}"

    log.info("/api/chat  mode=%s  tenant_id=%s  session_id=%s  query=%r", mode, tenant_id, session_id, query[:120])

    if mode == "views":
        log.debug("views config — VIEWS_MCP_URL=%s  key_set=%s", VIEWS_MCP_URL or "(not set)", bool(VIEWS_MCP_API_KEY))
    else:
        log.debug("admin config — ADMIN_MCP_URL=%s  key_set=%s", ADMIN_MCP_URL or "(not set)", bool(ADMIN_MCP_API_KEY))

    if not query:
        log.warning("empty query received")
        async def empty():
            yield 'data: {"type":"error","message":"Empty query"}\n\n'
        return StreamingResponse(empty(), media_type="text/event-stream")

    payload    = _build_payload(query, mode, tenant_id, session_id, model_id)
    log.debug("[%s] payload built (model=%s, memory_id=%s)", session_id, payload["model_config"]["model_id"], payload.get("memory_id", "<not set>"))

    async def event_stream():
        # First: emit session metadata so the UI can display it immediately
        yield f"data: {json.dumps({'type': 'session', 'session_id': session_id, 'mode': mode, 'tenant_id': tenant_id})}\n\n"

        loop = asyncio.get_event_loop()
        q: asyncio.Queue = asyncio.Queue()

        # Run the blocking boto3 call in a thread
        thread = threading.Thread(target=_stream_events, args=(payload, q, loop), daemon=True)
        thread.start()

        while True:
            event = await q.get()
            if event is None:
                yield "data: {\"type\":\"done\"}\n\n"
                break
            yield f"data: {json.dumps(event, default=str)}\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control":    "no-cache",
            "X-Accel-Buffering": "no",
            "Connection":        "keep-alive",
        },
    )


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    print(f"🚀  SQL Agent starting at http://localhost:{PORT}")
    print(f"   AWS profile : {AWS_PROFILE}  |  region : {AWS_REGION}")
    print(f"   AgentCore   : {'✓ configured' if AGENTCORE_RUNTIME_ARN else '✗ AGENTCORE_RUNTIME_ARN not set'}")
    print(f"   Memory ID   : {'✓ ' + MEMORY_ID if MEMORY_ID else '✗ AGENTCORE_MEMORY_ID not set — cross-session memory disabled'}")
    print(f"   Views MCP   : {'✓ configured' if VIEWS_MCP_URL else '✗ VIEWS_MCP_URL not set'}")
    print(f"   Admin MCP   : {'✓ configured' if ADMIN_MCP_URL else '✗ ADMIN_MCP_URL not set'}")
    uvicorn.run(app, host="0.0.0.0", port=PORT, reload=False)
