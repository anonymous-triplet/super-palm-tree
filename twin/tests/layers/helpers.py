"""Shared set-up for the layer tests: paths, a throw-away key directory, and a tiny MCP session handler."""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

TESTS = Path(__file__).resolve().parent
TWIN = TESTS.parents[1]
SRC = TWIN / "src"
MCP = SRC / "tools" / "mcp"
for path in (MCP, SRC / "scripts", SRC / "tools", TWIN / "mocks", TESTS.parent / "mcp"):
    sys.path.insert(0, str(path))


def make_keys(identities: list[str], directory: Path | None = None) -> Path:
    directory = directory or Path(tempfile.mkdtemp(prefix="cgz-keys-"))
    arguments = [sys.executable, str(MCP / "make_keys.py"), "--dir", str(directory)]
    for identity in identities:
        arguments += ["--identity", identity]
    subprocess.run(arguments, check=True, capture_output=True)
    return directory


class EchoProtocol:
    """A minimal MCP session: initialize, ping, tools/list (two tools), tools/call that counts calls and can stream progress."""

    calls: list[str] = []

    def __init__(self, identity: str) -> None:
        self.identity = identity
        self.notify = lambda message: None
        self.cancelled: set = set()

    def handle(self, message: dict) -> dict | None:
        method, message_id, params = message.get("method"), message.get("id"), message.get("params") or {}
        if message_id is None:
            return None
        if method == "initialize":
            return {"jsonrpc": "2.0", "id": message_id, "result": {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "echo"}}}
        if method == "ping":
            return {"jsonrpc": "2.0", "id": message_id, "result": {}}
        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": message_id, "result": {"tools": [{"name": "echo"}, {"name": "secret"}]}}
        if method == "tools/call":
            EchoProtocol.calls.append(params.get("name"))
            token = (params.get("_meta") or {}).get("progressToken")
            if token is not None:
                for step in range(3):
                    self.notify({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": token, "progress": step + 1}})
            data = {"echo": params.get("arguments"), "caller": self.identity}
            return {"jsonrpc": "2.0", "id": message_id, "result": {"content": [{"type": "text", "text": "x"}], "structuredContent": data, "isError": False}}
        return {"jsonrpc": "2.0", "id": message_id, "error": {"code": -32601, "message": "no"}}
