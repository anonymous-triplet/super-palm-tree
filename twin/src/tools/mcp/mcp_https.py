"""MCP between layers: the Streamable HTTP transport over mutually authenticated TLS.

The Model Context Protocol (JSON-RPC 2.0) carried as the specification's "Streamable HTTP" transport (one endpoint; a POST per
message; a long tool call streams its progress as Server-Sent Events), inside TLS 1.3 with a certificate on both sides:

* encryption in transit: everything after the TCP handshake is TLS 1.3 (AES-GCM / ChaCha20);
* authentication: each layer holds a private key and a certificate (PEM files, like an SSH key pair) signed by an authority the
  other side trusts. A peer without a valid certificate never reaches HTTP; the certificate's common name is the peer's identity
  and decides what it may call.

Only the Python standard library is used. Both ends are here: McpHttpsServer (the layer's own MCP endpoint, one session object per
MCP session) and McpHttpsClient (what a layer uses to call a partner's tools).
"""
from __future__ import annotations

import http.client
import http.server
import itertools
import json
import queue
import secrets
import socket
import ssl
import threading
import time
from typing import Any, Callable
from urllib.parse import urlsplit

MAX_BODY = 4 * 1024 * 1024
PROTOCOL_VERSION = "2025-06-18"


# --------------------------------------------------------------------------------------------- TLS

def _tls_version(text: str) -> ssl.TLSVersion:
    return ssl.TLSVersion.TLSv1_2 if str(text).strip() in ("1.2", "TLSv1.2") else ssl.TLSVersion.TLSv1_3


def server_context(certificate: str, private_key: str, trusted: list[str], min_version: str = "1.3") -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = _tls_version(min_version)
    context.load_cert_chain(certificate, private_key)
    for authority in trusted:
        context.load_verify_locations(authority)
    context.verify_mode = ssl.CERT_REQUIRED          # no client certificate, no connection
    return context


def client_context(certificate: str, private_key: str, trusted: list[str], min_version: str = "1.3") -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = _tls_version(min_version)
    context.load_cert_chain(certificate, private_key)
    for authority in trusted:
        context.load_verify_locations(authority)
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def certificate_identity(certificate: dict | None) -> str:
    """The common name of a peer certificate (as returned by SSLSocket.getpeercert())."""
    for field in (certificate or {}).get("subject", ()):
        for key, value in field:
            if key == "commonName":
                return str(value)
    return ""


# ------------------------------------------------------------------------------------------ server

class Session:
    """One MCP session: the protocol handler serving it and the peer it belongs to."""

    def __init__(self, session_id: str, identity: str, handler: Any) -> None:
        self.id = session_id
        self.identity = identity
        self.handler = handler            # has handle(message) -> response | None, notify, cancelled
        self.streams: dict[Any, queue.Queue] = {}
        self.lock = threading.Lock()
        self.last_seen = time.monotonic()
        # Answers already given, by JSON-RPC id: a client that resends a request after a dropped connection gets the same
        # answer instead of running the call twice.
        self.answers: dict[Any, dict] = {}
        self.running: dict[Any, threading.Event] = {}
        handler.notify = self._route

    def begin(self, message_id: Any) -> tuple[bool, dict | None]:
        """(first time, earlier answer). Waits for an identical request that is still running."""
        with self.lock:
            if message_id in self.answers:
                return False, self.answers[message_id]
            running = self.running.get(message_id)
            if running is None:
                self.running[message_id] = threading.Event()
                return True, None
        running.wait(60.0)
        with self.lock:
            return False, self.answers.get(message_id)

    def finish(self, message_id: Any, response: dict) -> None:
        with self.lock:
            self.answers[message_id] = response
            while len(self.answers) > 256:
                del self.answers[next(iter(self.answers))]
            event = self.running.pop(message_id, None)
        if event is not None:
            event.set()

    def _route(self, message: dict) -> None:
        token = ((message.get("params") or {}).get("progressToken"))
        with self.lock:
            stream = self.streams.get(token)
        if stream is not None:
            stream.put(message)


class McpHttpsServer:
    """The layer's MCP endpoint. `make_handler(identity)` builds the protocol handler of a new session; `authorize(identity,
    message)` returns an error text to refuse a request; `observe(event, identity, data)` sees every exchange (for the logs)."""

    def __init__(self, host: str, port: int, path: str, context: ssl.SSLContext, make_handler: Callable[[str], Any],
                 authorize: Callable[[str, dict], str] | None = None, allowed_identities: Callable[[str], bool] | None = None,
                 observe: Callable[[str, str, dict], None] | None = None, filter_result: Callable[[str, dict, Any], Any] | None = None,
                 session_idle_s: float = 3600.0) -> None:
        self.path = path
        self.context = context
        self.make_handler = make_handler
        self.authorize = authorize or (lambda identity, message: "")
        self.allowed_identities = allowed_identities or (lambda identity: True)
        self.observe = observe or (lambda event, identity, data: None)
        self.filter_result = filter_result or (lambda identity, message, result: result)
        self.session_idle_s = session_idle_s
        self.sessions: dict[str, Session] = {}
        self._lock = threading.Lock()
        outer = self

        class Handler(_Handler):
            server_owner = outer

        self.httpd = _TlsHttpServer((host, port), Handler, context)
        self.port = self.httpd.server_address[1]
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self.httpd.serve_forever, kwargs={"poll_interval": 0.2}, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()

    def new_session(self, identity: str) -> Session:
        session = Session(secrets.token_urlsafe(24), identity, self.make_handler(identity))
        with self._lock:
            now = time.monotonic()
            for key in [key for key, old in self.sessions.items() if now - old.last_seen > self.session_idle_s]:
                del self.sessions[key]
            self.sessions[session.id] = session
        return session

    def session(self, session_id: str) -> Session | None:
        with self._lock:
            return self.sessions.get(session_id)

    def end_session(self, session_id: str) -> bool:
        with self._lock:
            return self.sessions.pop(session_id, None) is not None


class _TlsHttpServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, context: ssl.SSLContext) -> None:
        self.tls = context
        super().__init__(address, handler)

    def handle_error(self, request, client_address) -> None:
        # A refused TLS handshake (no certificate, unknown authority, wrong protocol) is reported, not printed as a traceback.
        import sys
        error = sys.exc_info()[1]
        owner = getattr(self.RequestHandlerClass, "server_owner", None)
        if owner is not None and isinstance(error, (ssl.SSLError, ConnectionError, OSError)):
            owner.observe("refused", "", {"peer": f"{client_address[0]}:{client_address[1]}", "reason": str(error)[:200]})
            return
        super().handle_error(request, client_address)


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CityTwinMCP/1.0"
    sys_version = ""                    # no interpreter version in the Server header
    server_owner: McpHttpsServer
    timeout = 120

    def setup(self) -> None:
        raw = self.request
        raw.settimeout(15)
        self.request = self.server.tls.wrap_socket(raw, server_side=True)      # mutual TLS handshake, in this connection's thread
        self.identity = certificate_identity(self.request.getpeercert())
        self.request.settimeout(self.timeout)
        super().setup()

    def log_message(self, format: str, *args: Any) -> None:  # quiet: exchanges are reported through observe()
        return

    # ---- helpers

    def _send_json(self, status: int, body: Any, headers: dict | None = None) -> None:
        data = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode("utf-8") if body is not None else b""
        self.send_response(status)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _reject(self, status: int, code: int, message: str, message_id: Any = None) -> None:
        self._send_json(status, {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}})

    # ---- verbs

    def do_GET(self) -> None:  # noqa: N802 - no server-initiated stream on this endpoint
        self._send_json(405, None, {"Allow": "POST, DELETE"})

    def do_DELETE(self) -> None:  # noqa: N802
        owner = self.server_owner
        session_id = self.headers.get("Mcp-Session-Id", "")
        session = owner.session(session_id)
        if session is None or session.identity != self.identity:
            self._send_json(404, None)
            return
        owner.end_session(session_id)
        owner.observe("session_closed", self.identity, {"session": session_id[:8]})
        self._send_json(200, None)

    def do_POST(self) -> None:  # noqa: N802
        owner = self.server_owner
        if self.path.split("?")[0] != owner.path:
            self._send_json(404, None)
            return
        if not owner.allowed_identities(self.identity):
            owner.observe("forbidden", self.identity, {"reason": "unknown identity"})
            self._reject(403, -32001, f"certificate identity '{self.identity}' is not a configured partner of this layer")
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            self._reject(400, -32600, "a JSON-RPC message is required in the request body (at most 4 MB)")
            return
        try:
            message = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._reject(400, -32700, "Parse error: the body is not JSON")
            return
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            self._reject(400, -32600, "Invalid Request: one JSON-RPC 2.0 object per POST")
            return
        method = message.get("method")
        message_id = message.get("id")
        if method == "initialize":
            session = owner.new_session(self.identity)
        else:
            session = owner.session(self.headers.get("Mcp-Session-Id", ""))
            if session is None or session.identity != self.identity:
                self._reject(404, -32001, "Unknown or expired MCP session: initialize again", message_id)
                return
        session.last_seen = time.monotonic()
        headers = {"Mcp-Session-Id": session.id}
        if method is None or message_id is None:
            # A notification (cancel, initialized) or a response: accepted, nothing to return.
            if method == "notifications/cancelled":
                session.handler.cancelled.add((message.get("params") or {}).get("requestId"))
            else:
                session.handler.handle(message)
            self._send_json(202, None, headers)
            return
        refusal = owner.authorize(self.identity, message)
        if refusal:
            owner.observe("forbidden", self.identity, {"message": message, "reason": refusal})
            self._send_json(200, {"jsonrpc": "2.0", "id": message_id, "error": {"code": -32003, "message": refusal}}, headers)
            return
        first, earlier = session.begin(message_id)
        if not first:
            self._send_json(200, earlier or {"jsonrpc": "2.0", "id": message_id, "error": {"code": -32603, "message": "the first copy of this request did not finish"}}, headers)
            return
        owner.observe("request", self.identity, {"message": message, "session": session.id})
        started = time.monotonic()
        token = ((message.get("params") or {}).get("_meta") or {}).get("progressToken") if method == "tools/call" else None
        if token is None:
            try:
                response = session.handler.handle(message)
            except Exception as error:
                response = {"jsonrpc": "2.0", "id": message_id, "error": {"code": -32603, "message": str(error)[:300]}}
            response = owner.filter_result(self.identity, message, response)
            session.finish(message_id, response)
            owner.observe("response", self.identity, {"message": message, "response": response, "elapsed_ms": round((time.monotonic() - started) * 1000.0, 1)})
            self._send_json(200, response, headers)
            return
        # A streamed tool call: Server-Sent Events, progress notifications first, the response last.
        stream: queue.Queue = queue.Queue()
        with session.lock:
            session.streams[token] = stream

        def run() -> None:
            try:
                stream.put(("done", session.handler.handle(message)))
            except Exception as error:  # the handler failed: the client still gets an answer
                stream.put(("done", {"jsonrpc": "2.0", "id": message_id, "error": {"code": -32603, "message": str(error)[:300]}}))

        threading.Thread(target=run, daemon=True).start()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Mcp-Session-Id", session.id)
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        counter = itertools.count(1)
        try:
            while True:
                item = stream.get()
                if isinstance(item, tuple) and item[0] == "done":
                    response = owner.filter_result(self.identity, message, item[1])
                    session.finish(message_id, response)
                    owner.observe("response", self.identity, {"message": message, "response": response, "elapsed_ms": round((time.monotonic() - started) * 1000.0, 1)})
                    self._event(next(counter), response)
                    break
                self._event(next(counter), item)
        except (BrokenPipeError, ConnectionError, ssl.SSLError, OSError):
            session.handler.cancelled.add(message_id)          # the client went away: stop the stream
        finally:
            with session.lock:
                session.streams.pop(token, None)

    def _event(self, event_id: int, message: Any) -> None:
        data = json.dumps(message, separators=(",", ":"), ensure_ascii=False)
        self.wfile.write(f"id: {event_id}\nevent: message\ndata: {data}\n\n".encode("utf-8"))
        self.wfile.flush()


# ------------------------------------------------------------------------------------------ client

class McpError(Exception):
    def __init__(self, code: Any, message: str, data: Any = None) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.data = data


class McpHttpsClient:
    """A partner's MCP endpoint, called over mutual TLS. Thread-safe; reconnects and re-initialises by itself."""

    def __init__(self, url: str, context: ssl.SSLContext, client_name: str, timeout: float = 10.0,
                 observe: Callable[[str, dict], None] | None = None) -> None:
        parts = urlsplit(url)
        if parts.scheme != "https":
            raise ValueError(f"partner url must be https:// (got {url})")
        self.url = url
        self.host = parts.hostname or "127.0.0.1"
        self.port = parts.port or 443
        self.path = parts.path or "/mcp"
        self.context = context
        self.client_name = client_name
        self.timeout = timeout
        self.observe = observe or (lambda event, data: None)
        self.session_id = ""
        self.server_info: dict = {}
        self.peer_identity = ""
        self.tls_version = ""
        self._ids = itertools.count(1)
        self._lock = threading.Lock()
        self._connection: http.client.HTTPSConnection | None = None

    # ---- plumbing

    def _connect(self) -> http.client.HTTPSConnection:
        if self._connection is None:
            connection = http.client.HTTPSConnection(self.host, self.port, context=self.context, timeout=self.timeout)
            connection.connect()
            self.peer_identity = certificate_identity(connection.sock.getpeercert())
            self.tls_version = connection.sock.version() or ""
            self._connection = connection
        return self._connection

    def close(self) -> None:
        with self._lock:
            if self._connection is not None and self.session_id:
                try:
                    self._connection.request("DELETE", self.path, headers={"Mcp-Session-Id": self.session_id})
                    self._connection.getresponse().read()
                except (OSError, http.client.HTTPException):
                    pass
            self._drop()
            self.session_id = ""

    def _drop(self) -> None:
        if self._connection is not None:
            try:
                self._connection.close()
            except OSError:
                pass
        self._connection = None

    def _headers(self) -> dict:
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": PROTOCOL_VERSION}
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        return headers

    def _post(self, message: dict, on_progress: Callable[[dict], None] | None = None) -> dict | None:
        body = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        for attempt in (0, 1):
            try:
                connection = self._connect()
                connection.request("POST", self.path, body=body, headers=self._headers())
                response = connection.getresponse()
                session = response.getheader("Mcp-Session-Id")
                if session:
                    self.session_id = session
                if response.status == 202:
                    response.read()
                    return None
                if response.status == 404 and message.get("method") != "initialize" and attempt == 0:
                    response.read()
                    self._drop()
                    self._initialize()               # the partner restarted: open a new session and repeat once
                    continue
                kind = (response.getheader("Content-Type") or "").split(";")[0].strip()
                if kind == "text/event-stream":
                    result = self._read_events(response, message.get("id"), on_progress)
                    self._drop()
                    return result
                data = response.read()
                if response.getheader("Connection", "").lower() == "close":
                    self._drop()
                if not data:
                    raise McpError(response.status, f"HTTP {response.status} without a body")
                return json.loads(data.decode("utf-8"))
            except (OSError, http.client.HTTPException, ssl.SSLError) as error:
                self._drop()
                if attempt == 1 or message.get("method") == "initialize":
                    raise McpError("unreachable", f"{self.url}: {error}") from error
        return None

    @staticmethod
    def _read_events(response: http.client.HTTPResponse, message_id: Any, on_progress: Callable[[dict], None] | None) -> dict | None:
        data_lines: list[str] = []
        while True:
            raw = response.readline()
            if not raw:
                return None
            line = raw.decode("utf-8").rstrip("\r\n")
            if line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
                continue
            if line or not data_lines:
                continue
            event = json.loads("\n".join(data_lines))
            data_lines = []
            if isinstance(event, dict) and event.get("id") == message_id and ("result" in event or "error" in event):
                return event
            if on_progress is not None and isinstance(event, dict):
                on_progress(event)

    def _initialize(self) -> dict:
        self.session_id = ""
        reply = self._post({"jsonrpc": "2.0", "id": next(self._ids), "method": "initialize", "params": {
            "protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": self.client_name, "version": "1.0.0"}}})
        if not reply or "error" in reply:
            raise McpError((reply or {}).get("error", {}).get("code", "refused"), (reply or {}).get("error", {}).get("message", "initialize refused"))
        self.server_info = reply["result"].get("serverInfo", {})
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.observe("connected", {"server": self.server_info, "identity": self.peer_identity, "tls": self.tls_version})
        return reply["result"]

    def _request(self, method: str, params: dict, on_progress: Callable[[dict], None] | None = None) -> Any:
        with self._lock:
            if not self.session_id:
                self._initialize()
            reply = self._post({"jsonrpc": "2.0", "id": next(self._ids), "method": method, "params": params}, on_progress)
        if reply is None:
            raise McpError("no_answer", f"{self.url} did not answer {method}")
        if "error" in reply:
            error = reply["error"]
            raise McpError(error.get("code"), str(error.get("message", "")), error.get("data"))
        return reply.get("result")

    # ---- API

    def connect(self) -> dict:
        with self._lock:
            return self._initialize()

    def ping(self) -> None:
        self._request("ping", {})

    def list_tools(self) -> list[dict]:
        return list((self._request("tools/list", {}) or {}).get("tools", []))

    def call_tool(self, name: str, arguments: dict | None = None, meta: dict | None = None) -> dict:
        """Call a partner tool; returns its structured result. A tool that reports an error raises McpError."""
        params: dict = {"name": name, "arguments": arguments or {}}
        if meta:
            params["_meta"] = meta
        result = self._request("tools/call", params) or {}
        data = result.get("structuredContent")
        if data is None:
            texts = [part.get("text", "") for part in result.get("content", []) if part.get("type") == "text"]
            try:
                data = json.loads(texts[0]) if texts else {}
            except json.JSONDecodeError:
                data = {"text": "\n".join(texts)}
        if result.get("isError"):
            error = (data or {}).get("error", {}) if isinstance(data, dict) else {}
            raise McpError(error.get("code", "tool_error"), str(error.get("message", data)), data)
        return data if isinstance(data, dict) else {"result": data}


def wait_for_port(host: str, port: int, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.2)
    return False
