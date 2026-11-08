"""MCP between layers: Streamable HTTP inside mutual TLS 1.3 - encryption, authentication, authorisation, streaming, retries."""
from __future__ import annotations

import socket
import ssl
import unittest

from helpers import EchoProtocol, make_keys

from mcp_https import McpError, McpHttpsClient, McpHttpsServer, client_context, server_context


class SecureTransportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.keys = make_keys(["city-twin=localhost,127.0.0.1", "city-brain", "intruder"])
        cls.other = make_keys(["city-brain"])          # a key pair from an authority the server does not trust
        k = cls.keys
        cls.server = McpHttpsServer("127.0.0.1", 0, "/mcp", server_context(str(k / "city-twin.cert.pem"), str(k / "city-twin.key.pem"), [str(k / "triplet-ca.cert.pem")]),
                                    make_handler=EchoProtocol, allowed_identities=lambda identity: identity in ("city-brain", "intruder"),
                                    authorize=lambda identity, message: "" if identity == "city-brain" or message.get("method") != "tools/call"
                                    or (message.get("params") or {}).get("name") == "echo" else "not allowed",
                                    filter_result=lambda identity, message, result: cls._hide_secret(identity, message, result))
        cls.server.start()
        cls.url = f"https://127.0.0.1:{cls.server.port}/mcp"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.stop()

    @staticmethod
    def _hide_secret(identity: str, message: dict, result):
        if message.get("method") == "tools/list" and identity != "city-brain":
            result = dict(result, result={"tools": [tool for tool in result["result"]["tools"] if tool["name"] != "secret"]})
        return result

    def client(self, name: str, keys=None) -> McpHttpsClient:
        k = keys or self.keys
        return McpHttpsClient(self.url, client_context(str(k / f"{name}.cert.pem"), str(k / f"{name}.key.pem"), [str(self.keys / "triplet-ca.cert.pem")]), "test")

    def test_tls13_and_identities(self) -> None:
        brain = self.client("city-brain")
        brain.connect()
        self.assertEqual(brain.tls_version, "TLSv1.3")
        self.assertEqual(brain.peer_identity, "city-twin")
        self.assertEqual(brain.call_tool("echo", {"a": 1})["caller"], "city-brain")

    def test_no_certificate_is_refused(self) -> None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(str(self.keys / "triplet-ca.cert.pem"))
        with self.assertRaises(McpError):
            McpHttpsClient(self.url, context, "anonymous").connect()

    def test_untrusted_authority_is_refused(self) -> None:
        with self.assertRaises(McpError):
            self.client("city-brain", self.other).connect()

    def test_plain_http_gets_nothing(self) -> None:
        with socket.create_connection(("127.0.0.1", self.server.port), timeout=5) as raw:
            raw.sendall(b"POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}")
            raw.settimeout(5)
            try:
                reply = raw.recv(100)
            except (ConnectionError, socket.timeout):
                reply = b""
        self.assertNotIn(b"HTTP/1.1 200", reply)

    def test_authorisation_and_tool_list_filtering(self) -> None:
        intruder = self.client("intruder")
        self.assertEqual([tool["name"] for tool in intruder.list_tools()], ["echo"])
        with self.assertRaises(McpError) as caught:
            intruder.call_tool("secret")
        self.assertEqual(caught.exception.code, -32003)

    def test_streamed_call_delivers_progress_then_result(self) -> None:
        brain = self.client("city-brain")
        brain.connect()
        seen = []
        with brain._lock:
            reply = brain._post({"jsonrpc": "2.0", "id": 99, "method": "tools/call", "params": {"name": "echo", "arguments": {}, "_meta": {"progressToken": "p1"}}},
                                on_progress=seen.append)
        self.assertEqual(len(seen), 3)
        self.assertEqual(reply["result"]["structuredContent"]["caller"], "city-brain")

    def test_a_resent_request_runs_once(self) -> None:
        brain = self.client("city-brain")
        brain.connect()
        before = EchoProtocol.calls.count("echo")
        message = {"jsonrpc": "2.0", "id": 4242, "method": "tools/call", "params": {"name": "echo", "arguments": {"n": 1}}}
        with brain._lock:
            first = brain._post(message)
            brain._drop()                                   # as after a dropped connection
            second = brain._post(message)
        self.assertEqual(first, second)
        self.assertEqual(EchoProtocol.calls.count("echo") - before, 1)

    def test_lost_session_is_reopened(self) -> None:
        brain = self.client("city-brain")
        brain.connect()
        self.server.end_session(brain.session_id)
        self.assertEqual(brain.call_tool("echo", {"again": True})["echo"], {"again": True})


if __name__ == "__main__":
    unittest.main()
