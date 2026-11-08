"""What both stand-in layers share: their configuration (standins.conf), their MCP endpoint and their link to the twin.

A stand-in is a small but real layer: it runs as its own process, serves its own MCP tools over mutually authenticated TLS,
and calls the twin's (and the other partner's) tools the same way the real team's layer would. Only its decision logic is
simple. The transport is the twin's own (twin/src/tools/mcp/mcp_https.py), so the connection is the same standard one a
partner team would use with any MCP library.
"""
from __future__ import annotations

import datetime
import json
import signal
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src" / "tools" / "mcp"))

import layer_config  # noqa: E402
from mcp_https import McpError, McpHttpsClient, McpHttpsServer, client_context, server_context  # noqa: E402

CONFIG = HERE / "standins.conf"


def log(name: str, text: str) -> None:
    print(f"{datetime.datetime.now().strftime('%H:%M:%S.%f')[:-3]}  {name:<9} {text}", flush=True)


class ToolSpec:
    def __init__(self, name: str, description: str, schema: dict, handler: Callable[[dict, dict], dict], read_only: bool = False) -> None:
        self.name, self.description, self.schema, self.handler, self.read_only = name, description, schema, handler, read_only


class Protocol:
    """MCP over one session: initialize, ping, tools/list, tools/call (results as one JSON object, text and structured)."""

    def __init__(self, server_name: str, tools: dict[str, ToolSpec], instructions: str) -> None:
        self.server_name = server_name
        self.tools = tools
        self.instructions = instructions
        self.notify: Callable[[dict], None] = lambda message: None
        self.cancelled: set = set()

    def handle(self, message: dict) -> dict | None:
        method, message_id, params = message.get("method"), message.get("id"), message.get("params") or {}
        if message_id is None:
            return None
        if method == "initialize":
            return self._ok(message_id, {"protocolVersion": params.get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {"listChanged": False}},
                                         "serverInfo": {"name": self.server_name, "version": "1.0.0"}, "instructions": self.instructions})
        if method == "ping":
            return self._ok(message_id, {})
        if method == "tools/list":
            return self._ok(message_id, {"tools": [{"name": tool.name, "description": tool.description, "inputSchema": tool.schema,
                                                    "annotations": {"readOnlyHint": tool.read_only}} for tool in self.tools.values()]})
        if method == "tools/call":
            tool = self.tools.get(str(params.get("name", "")))
            if tool is None:
                return {"jsonrpc": "2.0", "id": message_id, "error": {"code": -32602, "message": f"Unknown tool: {params.get('name')}"}}
            arguments = params.get("arguments") or {}
            missing = [key for key in tool.schema.get("required", []) if key not in arguments]
            if missing or not isinstance(arguments, dict):
                return self._ok(message_id, self._result({"error": {"code": "invalid_arguments", "message": f"missing {', '.join(missing)}"}}, True))
            try:
                return self._ok(message_id, self._result(tool.handler(arguments, params.get("_meta") or {}), False))
            except Exception as error:  # a stand-in bug must answer, not hang the caller
                return self._ok(message_id, self._result({"error": {"code": "internal", "message": str(error)[:300]}}, True))
        return {"jsonrpc": "2.0", "id": message_id, "error": {"code": -32601, "message": f"Method not found: {method}"}}

    @staticmethod
    def _ok(message_id: Any, result: Any) -> dict:
        return {"jsonrpc": "2.0", "id": message_id, "result": result}

    def _result(self, data: dict, error: bool) -> dict:
        body = {"source": self.server_name, "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds"), **data}
        return {"content": [{"type": "text", "text": json.dumps(body, ensure_ascii=False)}], "structuredContent": body, "isError": error}


class Layer:
    """A stand-in layer: its endpoint, its tools, and clients for the twin and the other partner."""

    def __init__(self, section: str, display: str, instructions: str) -> None:
        parser = layer_config.read(CONFIG)
        self.section = section
        self.display = display
        self.endpoint = layer_config.endpoint(parser, section, CONFIG.parent)
        self.data = parser[section]
        trusted = [str(path) for path in self.endpoint.trusted_ca]
        self.tls_server = server_context(str(self.endpoint.certificate), str(self.endpoint.private_key), trusted, self.endpoint.tls_min_version)
        self.tls_client = client_context(str(self.endpoint.certificate), str(self.endpoint.private_key), trusted, self.endpoint.tls_min_version)
        self.tools: dict[str, ToolSpec] = {}
        self.instructions = instructions
        self.allowed = set(layer_config._list(self.data.get("accept", "")))
        self.stop = threading.Event()
        self.twin = McpHttpsClient(self.data["twin_url"], self.tls_client, f"{self.endpoint.identity} (stand-in)", timeout=float(self.data.get("timeout_s", "8")))
        self.twin_identity = self.data.get("twin_identity", "city-twin").strip()

    def partner(self, prefix: str) -> McpHttpsClient:
        return McpHttpsClient(self.data[f"{prefix}_url"], self.tls_client, f"{self.endpoint.identity} (stand-in)", timeout=float(self.data.get("timeout_s", "8")))

    def tool(self, spec: ToolSpec) -> None:
        self.tools[spec.name] = spec

    def call_twin(self, tool: str, arguments: dict, incident: str = "") -> dict:
        result = self.twin.call_tool(tool, arguments, {"correlationId": incident} if incident else None)
        if self.twin.peer_identity != self.twin_identity:
            raise McpError("identity", f"the twin's certificate says '{self.twin.peer_identity}', expected '{self.twin_identity}'")
        return result

    def brief(self, to: str, summary: str, incident: str = "", payload: Any = None) -> None:
        """Put one of this layer's own steps on the twin's timeline."""
        arguments: dict = {"to": to, "summary": summary[:200]}
        if incident:
            arguments["incident"] = incident
        if payload is not None:
            arguments["payload"] = payload
        try:
            self.call_twin("post_briefing", arguments, incident)
        except McpError as error:
            log(self.display, f"briefing not delivered: {error.message}")

    def serve(self) -> int:
        server = McpHttpsServer(self.endpoint.listen_host, self.endpoint.listen_port, self.endpoint.path, self.tls_server,
                                make_handler=lambda identity: Protocol(f"{self.endpoint.identity}-standin", self.tools, self.instructions),
                                allowed_identities=lambda identity: identity in self.allowed,
                                observe=lambda event, identity, data: log(self.display, f"{event} from {identity or data.get('peer')}: {data.get('reason', '')}")
                                if event in ("refused", "forbidden") else None)
        server.start()
        log(self.display, f"stand-in listening at {self.endpoint.url} as '{self.endpoint.identity}' (accepts {', '.join(sorted(self.allowed))})")
        signal.signal(signal.SIGTERM, lambda *_: self.stop.set())
        signal.signal(signal.SIGINT, lambda *_: self.stop.set())
        while not self.stop.wait(0.5):
            pass
        server.stop()
        return 0

    @staticmethod
    def now() -> float:
        return time.monotonic()
