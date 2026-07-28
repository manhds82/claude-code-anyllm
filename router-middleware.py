#!/usr/bin/env python3
"""
router-middleware.py — Token-aware routing middleware for claude-code-anyllm.

Sits between Claude Code (port 4001) and the LiteLLM proxy (port 4000).
Estimates the token count of each chat-completion request and rewrites
the 'model' field to steer the call to the right model tier:

  fast   (≤ 500 tok)  — quick questions, short edits
  medium (≤ 2000 tok) — normal coding tasks
  heavy  (> 2000 tok) — long context, architecture review

Called automatically by start-claude.ps1 / start-claude.sh with -Route / --route.

Usage:
  python router-middleware.py \
    --tier fast:500:model-fast \
    --tier medium:2000:model-medium \
    --tier heavy:inf:model-heavy \
    --port 4001 --litellm-port 4000
"""
import json
import argparse
from fastapi import FastAPI, Request
from fastapi.responses import Response, StreamingResponse
import httpx
import uvicorn

app = FastAPI(docs_url=None, redoc_url=None)

_tiers: list = []   # [(max_tokens: float, model_name: str), ...]  sorted ascending
_litellm_port: int = 4000


# ── Token estimation ────────────────────────────────────────────────────────

def _estimate_tokens(messages: list) -> int:
    """Rough estimate: 4 chars ≈ 1 token, 4-token overhead per message."""
    total = 0
    for msg in messages:
        content = msg.get("content", "")
        if isinstance(content, str):
            total += len(content) // 4 + 4
        elif isinstance(content, list):
            for part in content:
                if isinstance(part, dict):
                    total += len(part.get("text", "")) // 4 + 4
    return total


def _classify(body_bytes: bytes) -> tuple[bytes, str | None]:
    """Return (possibly modified body, chosen model_name or None)."""
    if not body_bytes or not _tiers:
        return body_bytes, None
    try:
        body = json.loads(body_bytes)
        msgs = body.get("messages")
        if not msgs:
            return body_bytes, None
        n_tok = _estimate_tokens(msgs)
        for max_tok, model_name in _tiers:
            if n_tok <= max_tok:
                body["model"] = model_name
                return json.dumps(body, ensure_ascii=False).encode(), model_name
    except Exception:
        pass
    return body_bytes, None


# ── Proxy handler ────────────────────────────────────────────────────────────

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"])
async def proxy(request: Request, path: str):
    body_bytes = await request.body()
    chosen_model = None

    if "chat/completions" in path:
        body_bytes, chosen_model = _classify(body_bytes)

    headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length")
    }
    url = f"http://localhost:{_litellm_port}/{path}"

    is_streaming = False
    if body_bytes:
        try:
            is_streaming = bool(json.loads(body_bytes).get("stream"))
        except Exception:
            pass

    async with httpx.AsyncClient(timeout=300.0) as client:
        if is_streaming:
            async def _stream():
                async with client.stream(
                    method=request.method,
                    url=url,
                    headers=headers,
                    content=body_bytes,
                    params=dict(request.query_params),
                ) as resp:
                    async for chunk in resp.aiter_bytes():
                        yield chunk
            return StreamingResponse(_stream(), media_type="text/event-stream")

        resp = await client.request(
            method=request.method,
            url=url,
            headers=headers,
            content=body_bytes,
            params=dict(request.query_params),
        )
        resp_headers = {
            k: v for k, v in resp.headers.items()
            if k.lower() not in ("transfer-encoding",)
        }
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            headers=resp_headers,
        )


# ── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Token-aware routing middleware")
    parser.add_argument("--port", type=int, default=4001, help="Middleware listen port")
    parser.add_argument("--litellm-port", type=int, default=4000, dest="litellm_port")
    parser.add_argument(
        "--tier", action="append", metavar="NAME:MAX_TOKENS:MODEL",
        help="Routing tier, e.g. fast:500:model-fast  (repeatable; use 'inf' for last tier)"
    )
    args = parser.parse_args()
    _litellm_port = args.litellm_port

    for spec in (args.tier or []):
        try:
            name, max_tok_str, model_name = spec.split(":", 2)
            max_tok = float("inf") if max_tok_str == "inf" else int(max_tok_str)
            _tiers.append((max_tok, model_name))
        except ValueError:
            print(f"[router] WARNING: bad tier spec '{spec}', skipped")

    _tiers.sort(key=lambda x: x[0])

    print(f"[router] Token-aware routing middleware — port {args.port} → LiteLLM :{_litellm_port}")
    for max_tok, model_name in _tiers:
        label = "∞" if max_tok == float("inf") else f"≤{max_tok}"
        print(f"[router]   {label:>8} tokens  →  {model_name}")

    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
