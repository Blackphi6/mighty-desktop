#!/usr/bin/env python3
"""Anthropic Messages API -> OpenAI Chat Completions proxy (for Claude Code + mlx_lm.server).

Claude Code  --/v1/messages-->  this proxy  --/v1/chat/completions-->  mlx_lm.server
"""
import json
import os
import sys
import uuid

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
import uvicorn

BACKEND = os.environ.get("BACKEND_URL", "http://127.0.0.1:8080").rstrip("/")
BACKEND_MODEL = os.environ.get("BACKEND_MODEL", "default_model")
# Qwen3.5 thinking is slow for an agent loop; disable by default (THINKING=1 to enable).
THINKING = os.environ.get("THINKING", "0") == "1"
MAX_TOKENS_CAP = int(os.environ.get("MAX_TOKENS_CAP", "8192"))

# --- EoCC (End-of-Conversation Compaction), arXiv:2611.05306 ---------------------
# Estimated total prompt tokens (system + tools + messages) above which the history is
# replaced by [system, original task, model-written recap]. Claude Code's own system
# prompt + tool schemas are ~15-20K tokens, so keep this well above that. 0 disables.
COMPACT_THRESHOLD = int(os.environ.get("COMPACT_THRESHOLD", "48000"))
CHARS_PER_TOKEN = 3.5
COMPACT_PROMPT = (
    "You are pausing an ongoing coding-agent session. Your context is about to be reset. "
    "Write a recap so that you can continue seamlessly from a fresh conversation. Do NOT call tools. "
    "Use exactly these sections:\n"
    "1. OBJECTIVE: the user's task in your own words.\n"
    "2. ESTABLISHED FACTS: exact file paths, values, commands, error messages discovered.\n"
    "3. CHANGES MADE: files edited/created and whether each was verified.\n"
    "4. DEAD ENDS: approaches that failed and why.\n"
    "5. REMAINING PLAN: the very next command/tool call to make, and the completion condition.\n"
    "Be concise but keep every exact path, identifier and number needed to continue."
)
_compactions = {}  # first-user-text -> {"n": messages covered, "recap": str}

app = FastAPI()
client = httpx.AsyncClient(timeout=httpx.Timeout(None, connect=10))


def _text_of(content):
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text", ""))
    return "\n".join(out)


def convert_messages(system, messages):
    out = []
    sys_text = _text_of(system) if system else ""
    if sys_text:
        out.append({"role": "system", "content": sys_text})
    for m in messages:
        role, content = m["role"], m["content"]
        if isinstance(content, str):
            out.append({"role": role, "content": content})
            continue
        texts, tool_calls, tool_msgs = [], [], []
        for b in content:
            t = b.get("type")
            if t == "text":
                texts.append(b.get("text", ""))
            elif t == "tool_use":
                tool_calls.append({
                    "id": b["id"], "type": "function",
                    "function": {"name": b["name"], "arguments": json.dumps(b.get("input", {}), ensure_ascii=False)},
                })
            elif t == "tool_result":
                c = b.get("content", "")
                txt = _text_of(c) if not isinstance(c, str) else c
                if b.get("is_error"):
                    txt = "[error] " + txt
                tool_msgs.append({"role": "tool", "tool_call_id": b["tool_use_id"], "content": txt})
            elif t == "image":
                texts.append("[image omitted: model is text-only]")
            # thinking / redacted_thinking blocks are dropped
        if role == "assistant":
            msg = {"role": "assistant", "content": "\n".join(texts) or None}
            if tool_calls:
                msg["tool_calls"] = tool_calls
            if msg["content"] or tool_calls:
                out.append(msg)
        else:
            out.extend(tool_msgs)  # tool results must directly follow the assistant tool_calls
            if texts:
                out.append({"role": "user", "content": "\n".join(texts)})
    return out


def convert_request(body):
    req = {
        "model": BACKEND_MODEL,
        "messages": convert_messages(body.get("system"), body["messages"]),
        "max_tokens": min(body.get("max_tokens", 4096), MAX_TOKENS_CAP),
        "stream": bool(body.get("stream")),
        "chat_template_kwargs": {"enable_thinking": THINKING},
    }
    for k in ("temperature", "top_p", "top_k"):
        if k in body:
            req[k] = body[k]
    if body.get("stop_sequences"):
        req["stop"] = body["stop_sequences"]
    if body.get("tools"):
        req["tools"] = [{
            "type": "function",
            "function": {"name": t["name"], "description": t.get("description", ""),
                         "parameters": t.get("input_schema", {"type": "object", "properties": {}})},
        } for t in body["tools"]]
        tc = body.get("tool_choice") or {}
        if tc.get("type") == "any":
            req["tool_choice"] = "required"
        elif tc.get("type") == "tool":
            req["tool_choice"] = {"type": "function", "function": {"name": tc["name"]}}
    return req


STOP = {"stop": "end_turn", "length": "max_tokens", "tool_calls": "tool_use"}


def _args(s):
    try:
        return json.loads(s) if isinstance(s, str) else (s or {})
    except Exception:
        return {"_raw": s}


def sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode()


def _clip(t, n):
    return t if len(t) <= n else t[: n // 2] + "\n...[clipped]...\n" + t[-n // 2:]


def render_transcript(messages):
    out = []
    for m in messages:
        c = m["content"]
        if isinstance(c, str):
            out.append(f"[{m['role']}] {_clip(c, 3000)}")
            continue
        for b in c:
            t = b.get("type")
            if t == "text":
                out.append(f"[{m['role']}] {_clip(b.get('text', ''), 3000)}")
            elif t == "tool_use":
                out.append(f"[tool_call] {b['name']} {_clip(json.dumps(b.get('input', {}), ensure_ascii=False), 1500)}")
            elif t == "tool_result":
                cc = b.get("content", "")
                out.append(f"[tool_result] {_clip(cc if isinstance(cc, str) else _text_of(cc), 1500)}")
    return "\n".join(out)


def _est_tokens(obj):
    return int(len(json.dumps(obj, ensure_ascii=False)) / CHARS_PER_TOKEN)


def _first_text(messages):
    c = messages[0]["content"]
    return c if isinstance(c, str) else _text_of(c)


async def compact_if_needed(body):
    """Apply EoCC to body['messages'] (Anthropic format). Returns possibly-rewritten messages."""
    msgs = body["messages"]
    if COMPACT_THRESHOLD <= 0 or not msgs:
        return msgs
    key = _first_text(msgs)
    st = _compactions.get(key)
    if st and st["n"] > len(msgs):  # client started over / rewound
        st = _compactions.pop(key, None) and None
    base = []
    if st:
        base = [{"role": "user", "content": _recap_message(msgs[0], st["recap"])}] + msgs[st["n"]:]
    else:
        base = msgs
    fixed = _est_tokens({"s": body.get("system"), "t": body.get("tools")})
    if fixed + _est_tokens(base) < COMPACT_THRESHOLD or len(base) < 3:
        return base
    # Compact: ask the model for a recap of everything so far.
    transcript = render_transcript(base)
    creq = {
        "model": BACKEND_MODEL, "stream": False, "max_tokens": 1500, "temperature": 0.3,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [
            {"role": "system", "content": "You summarize agent sessions faithfully."},
            {"role": "user", "content": "SESSION TRANSCRIPT:\n" + _clip(transcript, 90000) + "\n\n" + COMPACT_PROMPT},
        ],
    }
    r = await client.post(f"{BACKEND}/v1/chat/completions", json=creq)
    if r.status_code != 200:
        return base  # fall back to full history
    recap = (r.json()["choices"][0]["message"].get("content") or "").strip()
    if not recap:
        return base
    _compactions[key] = {"n": len(msgs), "recap": recap}
    print(f"[EoCC] compacted {len(msgs)} msgs -> recap ({len(recap)} chars)", file=sys.stderr, flush=True)
    return [{"role": "user", "content": _recap_message(msgs[0], recap)}]


def _recap_message(first, recap):
    return ("ORIGINAL TASK:\n" + _first_text([first]) + "\n\nRECAP OF PROGRESS SO FAR "
            "(your earlier context was reset; trust this recap):\n" + recap +
            "\n\nContinue the task from the REMAINING PLAN.")


@app.post("/v1/messages")
async def messages(request: Request):
    body = await request.json()
    body["messages"] = await compact_if_needed(body)
    req = convert_request(body)
    model = body.get("model", "local")
    mid = "msg_" + uuid.uuid4().hex[:24]

    if not req["stream"]:
        r = await client.post(f"{BACKEND}/v1/chat/completions", json=req)
        if r.status_code != 200:
            return JSONResponse({"type": "error", "error": {"type": "api_error", "message": r.text}}, status_code=r.status_code)
        d = r.json()
        ch = d["choices"][0]
        msg = ch["message"]
        content = []
        if msg.get("content"):
            content.append({"type": "text", "text": msg["content"]})
        for tc in msg.get("tool_calls") or []:
            content.append({"type": "tool_use", "id": tc.get("id") or "toolu_" + uuid.uuid4().hex[:16],
                            "name": tc["function"]["name"], "input": _args(tc["function"].get("arguments"))})
        stop = "tool_use" if any(c["type"] == "tool_use" for c in content) else STOP.get(ch.get("finish_reason"), "end_turn")
        u = d.get("usage", {})
        return {"id": mid, "type": "message", "role": "assistant", "model": model, "content": content or [{"type": "text", "text": ""}],
                "stop_reason": stop, "stop_sequence": None,
                "usage": {"input_tokens": u.get("prompt_tokens", 0), "output_tokens": u.get("completion_tokens", 0)}}

    async def gen():
        yield sse("message_start", {"type": "message_start", "message": {
            "id": mid, "type": "message", "role": "assistant", "model": model, "content": [],
            "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 0, "output_tokens": 0}}})
        idx = -1
        text_open = False
        saw_tool = False
        finish = None
        usage = {}
        async with client.stream("POST", f"{BACKEND}/v1/chat/completions", json=req) as r:
            if r.status_code != 200:
                err = (await r.aread()).decode(errors="replace")
                yield sse("error", {"type": "error", "error": {"type": "api_error", "message": err}})
                return
            async for line in r.aiter_lines():
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    d = json.loads(payload)
                except Exception:
                    continue
                if d.get("usage"):
                    usage = d["usage"]
                if not d.get("choices"):
                    continue
                ch = d["choices"][0]
                delta = ch.get("delta") or {}
                if delta.get("content"):
                    if not text_open:
                        idx += 1
                        text_open = True
                        yield sse("content_block_start", {"type": "content_block_start", "index": idx, "content_block": {"type": "text", "text": ""}})
                    yield sse("content_block_delta", {"type": "content_block_delta", "index": idx, "delta": {"type": "text_delta", "text": delta["content"]}})
                for tc in delta.get("tool_calls") or []:
                    if text_open:
                        yield sse("content_block_stop", {"type": "content_block_stop", "index": idx})
                        text_open = False
                    saw_tool = True
                    idx += 1
                    fn = tc.get("function", {})
                    args = fn.get("arguments", "")
                    if not isinstance(args, str):
                        args = json.dumps(args, ensure_ascii=False)
                    yield sse("content_block_start", {"type": "content_block_start", "index": idx, "content_block": {
                        "type": "tool_use", "id": tc.get("id") or "toolu_" + uuid.uuid4().hex[:16], "name": fn.get("name", ""), "input": {}}})
                    yield sse("content_block_delta", {"type": "content_block_delta", "index": idx, "delta": {"type": "input_json_delta", "partial_json": args or "{}"}})
                    yield sse("content_block_stop", {"type": "content_block_stop", "index": idx})
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
        if text_open:
            yield sse("content_block_stop", {"type": "content_block_stop", "index": idx})
        if idx < 0:  # empty reply: emit an empty text block so clients don't choke
            yield sse("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            yield sse("content_block_stop", {"type": "content_block_stop", "index": 0})
        stop = "tool_use" if saw_tool else STOP.get(finish, "end_turn")
        yield sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                    "usage": {"input_tokens": usage.get("prompt_tokens", 0), "output_tokens": usage.get("completion_tokens", 0)}})
        yield sse("message_stop", {"type": "message_stop"})

    return StreamingResponse(gen(), media_type="text/event-stream")


@app.post("/v1/messages/count_tokens")
async def count_tokens(request: Request):
    body = await request.json()
    n = len(json.dumps(body, ensure_ascii=False)) // 3
    return {"input_tokens": n}


@app.get("/health")
async def health():
    return {"ok": True}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("PROXY_PORT", "8082")), log_level="warning")
