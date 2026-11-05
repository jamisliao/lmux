#!/usr/bin/env python3
"""A minimal fake Anthropic Messages API for capture.py: the first turn gets a Write tool_use
(MOCK_TOOL=Write) or a Read then an Edit (MOCK_TOOL=Edit), anything else a short text.
Streaming (SSE) and not. Listens on 127.0.0.1 only."""
import json, os, sys, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOL = os.environ.get("MOCK_TOOL", "Write")
CWD = os.environ["MOCK_CWD"]
LOG = open(os.environ.get("MOCK_LOG", "/dev/null"), "a")

PY = '''import dataclasses
from pathlib import Path


@dataclasses.dataclass
class Invoice:
    """One customer invoice."""
    customer: str
    amount_cents: int = 0
    paid: bool = False

    def total(self, tax_rate: float = 0.1) -> float:
        # Tax is applied on the full amount.
        subtotal = self.amount_cents / 100
        return round(subtotal * (1 + tax_rate), 2)


def load(path: Path) -> list[Invoice]:
    rows = path.read_text().splitlines()
    return [Invoice(customer=r, amount_cents=len(r) * 250) for r in rows if r]
'''


MARKDOWN = """## Freeing disk space

uv keeps every wheel it ever built in `~/.cache/uv`. Run `uv cache clean` to drop it, or **`uv cache prune`** to keep what's in use.

| Cache | Path | Clean with |
|---|---|---|
| uv | `~/.cache/uv` | `uv cache clean` |
| pip | `~/Library/Caches/pip` | `pip cache purge` |

- **Bold** and *italic* and `inline code` in a bullet
- A link: [uv docs](https://docs.astral.sh/uv/concepts/cache/)
  1. nested step with `--dry-run`

> Note: `uv cache clean` can't run while another `uv` process holds the lock.

### Next
Re-run `du -sh ~/.cache/*` to confirm. Done."""


def tool_input():
    if TOOL == "Write":
        return {"file_path": os.path.join(CWD, "invoice.py"), "content": PY}
    return {"file_path": os.path.join(CWD, "invoice.py"),
            "old_string": "        subtotal = self.amount_cents / 100\n        return round(subtotal * (1 + tax_rate), 2)",
            "new_string": "        subtotal = self.amount_cents / 100\n        if self.paid:\n            return 0.0\n        total = subtotal * (1 + tax_rate)\n        return round(total, 2)"}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        LOG.write(f"GET {self.path}\n"); LOG.flush()
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers()
        self.wfile.write(b"{}")

    def do_HEAD(self):
        self.send_response(200); self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        LOG.write(f"POST {self.path} model={body.get('model')} stream={body.get('stream')} tools={len(body.get('tools') or [])} msgs={len(body.get('messages') or [])}\n"); LOG.flush()
        if "count_tokens" in self.path:
            return self.json({"input_tokens": 10})
        if not self.path.startswith("/v1/messages"):
            return self.json({})
        msgs = body.get("messages") or []
        tools = [t.get("name") for t in body.get("tools") or []]
        results = sum(1 for m in msgs if isinstance(m.get("content"), list) for c in m["content"] if c.get("type") == "tool_result")
        plan = {"Write": ["Write"], "Edit": ["Read", "Edit"]}.get(TOOL, [])
        if TOOL in tools and results < len(plan):
            name = plan[results]
            inp = {"file_path": os.path.join(CWD, "invoice.py")} if name == "Read" else tool_input()
            content = [{"type": "text", "text": "Creating it now." if results == 0 else "Updating total()."},
                       {"type": "tool_use", "id": "toolu_" + uuid.uuid4().hex[:20], "name": name, "input": inp}]
            stop = "tool_use"
        else:
            content = [{"type": "text", "text": MARKDOWN if TOOL == "Markdown" and results == 0 and "Write" in tools else "Done."}]
            stop = "end_turn"
        msg = {"id": "msg_" + uuid.uuid4().hex[:20], "type": "message", "role": "assistant", "model": body.get("model", "x"),
               "content": content, "stop_reason": stop, "stop_sequence": None,
               "usage": {"input_tokens": 10, "output_tokens": 10}}
        if not body.get("stream"):
            return self.json(msg)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        def ev(name, data):
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
        ev("message_start", {"type": "message_start", "message": {**msg, "content": [], "stop_reason": None}})
        for i, c in enumerate(content):
            if c["type"] == "text":
                ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}})
                ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": c["text"]}})
            else:
                ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": {**c, "input": {}}})
                ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "input_json_delta", "partial_json": json.dumps(c["input"])}})
            ev("content_block_stop", {"type": "content_block_stop", "index": i})
        ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 10}})
        ev("message_stop", {"type": "message_stop"})
        self.wfile.flush()

    def json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)


srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.serve_forever()
