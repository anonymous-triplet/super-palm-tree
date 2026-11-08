#!/usr/bin/env python3
"""The Digital Twin's partner gateway: how this layer talks to the City Brain and the Guardian.

Everything about the connection comes from twin/twin.conf. The gateway

* serves the twin's MCP tools to partners: MCP Streamable HTTP inside mutually authenticated TLS 1.3 (twin.conf [twin]). A peer
  must present a certificate signed by a trusted authority; its common name says which partner it is and what it may call;
* reports to the City Brain: every incident the twin detects and every emergency call that needs a responding unit (the Brain's
  report_incident tool), and the incident's end (close_incident). The Brain answers through the twin's dispatch_units tool;
* keeps the timeline: every message both ways, every briefing a partner posts, and what the twin detected and did, with a time
  stamp. Each line goes to the run log of its incident (logs/), to the control room (bottom log and Timeline tab) and to the
  dashboard (read_timeline).

When the City Brain is unreachable the twin's own dispatcher answers the calls (the decision lease is not renewed), so the city
keeps running; the timeline says so.

    python twin_gateway.py --config ../../twin.conf           (the launcher starts it)
    python twin_gateway.py --config ../../twin.conf --check   (validate the configuration and the PEM files, then exit)
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import queue
import re
import signal
import ssl
import sys
import threading
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import layer_config  # noqa: E402
from city_mcp_server import Server, SimClient, SimError, Tool, _schema  # noqa: E402
from mcp_https import McpError, McpHttpsClient, McpHttpsServer, client_context, server_context  # noqa: E402

POLL_S = 0.1
LEASE_RENEW_S = 2.0
HEALTH_S = 3.0
ROLE_NAMES = {"twin": "TWIN", "brain": "BRAIN", "guardian": "GUARDIAN", "operator": "OPERATOR"}
QUIET_METHODS = {"ping", "notifications/initialized", "tools/list"}


def _now_ms() -> int:
    return int(time.time() * 1000)


def _clock(ms: int) -> str:
    stamp = datetime.datetime.fromtimestamp(ms / 1000.0)
    return stamp.strftime("%H:%M:%S.") + f"{ms % 1000:03d}"


def _slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9.]+", "-", text).strip("-").lower()[:60] or "run"


def _short(value: Any, limit: int = 90) -> str:
    text = value if isinstance(value, str) else json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _role_text(role: str) -> str:
    return role.replace("_", " ")


# ------------------------------------------------------------------------------------------- run logs

class RunLogs:
    """One file per incident run (and one per session) under the logs directory, in time order by name."""

    def __init__(self, directory: Path, payload_limit: int, header: list[str]) -> None:
        self.directory = directory
        self.directory.mkdir(parents=True, exist_ok=True)
        self.payload_limit = payload_limit
        self.header = header
        self.runs: dict[str, Path] = {}
        self.lock = threading.Lock()
        started = datetime.datetime.now()
        self.session = self.directory / f"{started.strftime('%Y-%m-%d_%H-%M-%S')}_session.log"
        self._start(self.session, "Session (link events and everything outside an incident run)", started)

    def _start(self, path: Path, title: str, started: datetime.datetime) -> None:
        offset = started.astimezone().strftime("%z")
        lines = ["City Ground Zero · Digital Twin run log", f"Run:     {title}", f"Started: {started.strftime('%Y-%m-%d %H:%M:%S')} (local time, UTC{offset[:3]}:{offset[3:]})",
                 *self.header,
                 "Each line: time · who → whom · what happened. Indented '↳' lines carry the details and payload;",
                 "show the lines alone with: python3 twin/src/tools/mcp/runlog.py <this file>",
                 "-" * 118]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def open_run(self, incident: str, label: str, kind: str) -> Path:
        with self.lock:
            if incident in self.runs:
                return self.runs[incident]
            started = datetime.datetime.now()
            name = f"{started.strftime('%Y-%m-%d_%H-%M-%S')}_{_slug(label) + '_' if label else ''}{incident}_{_slug(kind)}.log"
            path = self.directory / name
            self._start(path, f"{label + ' · ' if label else ''}{incident} ({kind})", started)
            self.runs[incident] = path
            return path

    def write(self, entry: dict, path: Path | None = None) -> None:
        target = path or self.runs.get(entry.get("incident", ""), self.session)
        lines = [self.line(entry)]
        payload = entry.get("payload")
        if payload is not None:
            text = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) if not isinstance(payload, str) else payload
            if len(text) > self.payload_limit:
                text = text[: self.payload_limit] + f" … ({len(text) - self.payload_limit} more characters)"
            lines.append(" " * 14 + "↳ " + text)
        with self.lock, target.open("a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")

    @staticmethod
    def route(entry: dict) -> str:
        source = ROLE_NAMES.get(entry.get("from", ""), entry.get("from", "").upper())
        target = ROLE_NAMES.get(entry.get("to", ""), entry.get("to", "").upper())
        return f"{source} → {target}" if target else source

    def line(self, entry: dict) -> str:
        return f"{entry['time']}  {self.route(entry):<19} {entry['text']}"


# ------------------------------------------------------------------------------------------- partners

class PartnerLink:
    """The twin's client of one partner layer, with its health."""

    def __init__(self, partner: layer_config.Partner, context: ssl.SSLContext, gateway: "Gateway") -> None:
        self.partner = partner
        self.gateway = gateway
        self.client = McpHttpsClient(partner.url, context, f"{gateway.endpoint.identity} (City Ground Zero twin)", timeout=partner.timeout_s)
        self.healthy = False
        self.detail = "connecting"
        self.lock = threading.Lock()

    def check(self) -> None:
        try:
            if not self.client.session_id:
                self.client.connect()
            else:
                self.client.ping()
            if self.client.peer_identity != self.partner.identity:
                raise McpError("identity", f"the server at {self.partner.url} is '{self.client.peer_identity}', expected '{self.partner.identity}'")
            if not self.healthy:
                self.healthy = True
                self.detail = f"connected over {self.client.tls_version}"
                info = self.client.server_info
                self.gateway.emit("twin", self.partner.role, "link", f"Connected to the {self.partner.role.title()} at {self.partner.url}: {self.client.tls_version}, certificate '{self.client.peer_identity}' verified"
                                  f"{', server ' + str(info.get('name')) if info.get('name') else ''}", payload={"server": info, "identity": self.client.peer_identity, "tls": self.client.tls_version})
                self.gateway.push_status()
        except (McpError, OSError, ssl.SSLError) as error:
            self.client.close()
            message = getattr(error, "message", str(error))
            if self.healthy or self.detail == "connecting":
                self.gateway.emit("twin", self.partner.role, "link", f"The {self.partner.role.title()} is unreachable at {self.partner.url} ({_short(message, 110)}); retrying every {HEALTH_S:.0f} s")
            self.healthy = False
            self.detail = f"unreachable: {_short(message, 80)}"
            self.gateway.push_status()

    def call(self, tool: str, arguments: dict, incident: str, text: str, reply_text) -> dict | None:
        """Call one of the partner's tools and log both directions. Returns the result, or None when it failed."""
        meta = {"correlationId": incident} if incident else None
        self.gateway.emit("twin", self.partner.role, "request", text, incident=incident, payload={"tool": tool, "arguments": arguments, "_meta": meta})
        try:
            with self.lock:
                result = self.client.call_tool(tool, arguments, meta)
        except McpError as error:
            if error.code == "unreachable":
                self.healthy = False
                self.detail = "unreachable"
                self.gateway.push_status()
            self.gateway.emit(self.partner.role, "twin", "response", f"{tool} failed: {_short(error.message, 120)}", incident=incident, payload={"error": {"code": error.code, "message": error.message}})
            return None
        self.gateway.emit(self.partner.role, "twin", "response", reply_text(result), incident=incident, payload=result)
        return result


# ------------------------------------------------------------------------------------------- MCP server

class GatewayServer(Server):
    """The twin's tools as partners see them, plus post_briefing (a partner's account of its own steps)."""

    def __init__(self, sim: SimClient, gateway: "Gateway", identity: str) -> None:
        self.gateway = gateway
        self.identity = identity
        super().__init__(sim)

    def _build_tools(self) -> list[Tool]:
        tools = super()._build_tools()
        tools.append(Tool("post_briefing", "Tell the twin's timeline what your layer did or sent to another layer (a verdict, a decision, a question to the other partner). "
                          "It appears in the run log and on the timeline screens with your layer as the sender.",
                          _schema({"to": {"type": "string", "enum": ["twin", "brain", "guardian", ""], "description": "The layer the briefed message went to ('' for an internal step)"},
                                   "summary": {"type": "string", "description": "One plain sentence (at most 200 characters)"},
                                   "incident": {"type": "string", "description": "Incident id this belongs to, if any"},
                                   "label": {"type": "string", "description": "Run label (a scenario about to start), when there is no incident yet"},
                                   "payload": {"description": "The message itself, or any detail worth keeping"}}, ["summary"]),
                          lambda s, a: s._brief(a), read_only=False))
        return tools

    def _brief(self, args: dict) -> dict:
        role = self.gateway.role_of(self.identity)
        summary = str(args["summary"]).strip()[:200]
        if not summary:
            raise SimError("bad_value", "summary must not be empty")
        entry = self.gateway.emit(role, str(args.get("to", "")), "briefing", summary, incident=str(args.get("incident", "")), payload=args.get("payload"), briefed=True,
                                  label=str(args.get("label", "")))
        return {"recorded": True, "time": entry["time"], "run": entry.get("run", "")}


# ------------------------------------------------------------------------------------------- the gateway

class Gateway:
    def __init__(self, config_path: Path) -> None:
        self.config_path = config_path.resolve()
        base = self.config_path.parent
        parser = layer_config.read(self.config_path)
        self.endpoint = layer_config.endpoint(parser, "twin", base)
        self.partners = {partner.role: partner for partner in layer_config.partners(parser)}
        self.clients = layer_config.clients(parser, base)
        logs = parser["logs"] if parser.has_section("logs") else {}
        self.logs_dir = (base / logs.get("directory", "../logs")).resolve()
        self.payload_limit = int(float(logs.get("payload_limit_kb", "64")) * 1024)
        decisions = parser["decisions"] if parser.has_section("decisions") else {}
        self.dispatch_by = decisions.get("dispatch", "brain").strip()
        self.lease_s = float(decisions.get("lease_s", "6"))
        self.sim = SimClient(timeout=10.0)
        self.watch_sim = SimClient(timeout=10.0)
        self.push_queue: queue.Queue = queue.Queue()
        self.links: dict[str, PartnerLink] = {}
        self.runs: dict[str, dict] = {}
        self.pending_labels: dict[str, list[dict]] = {}
        self.stop = threading.Event()
        self.external = False
        self.logs: RunLogs | None = None
        self.server: McpHttpsServer | None = None
        self.lock = threading.Lock()

    # ---- configuration

    def check(self) -> list[str]:
        problems = []
        for label, path in (("twin certificate", self.endpoint.certificate), ("twin private key", self.endpoint.private_key), *(("trusted authority", p) for p in self.endpoint.trusted_ca)):
            if not path.is_file():
                problems.append(f"{label} not found: {path}")
        if not problems:
            try:
                server_context(str(self.endpoint.certificate), str(self.endpoint.private_key), [str(p) for p in self.endpoint.trusted_ca], self.endpoint.tls_min_version)
            except (ssl.SSLError, OSError) as error:
                problems.append(f"the twin's PEM files do not load: {error}")
        if "brain" not in self.partners:
            problems.append("no [partner:brain] section")
        if "guardian" not in self.partners:
            problems.append("no [partner:guardian] section")
        if self.dispatch_by not in ("brain", "twin"):
            problems.append("[decisions] dispatch must be brain or twin")
        return problems

    def role_of(self, identity: str) -> str:
        for partner in self.partners.values():
            if partner.identity == identity:
                return partner.role
        for client in self.clients:
            if client.identity == identity:
                return client.name
        return identity or "unknown"

    def _allow_list(self, identity: str) -> list[str] | None:
        for partner in self.partners.values():
            if partner.identity == identity:
                return partner.allow
        for client in self.clients:
            if client.identity == identity:
                return client.allow
        return None

    def _tool_allowed(self, identity: str, tool: str, server: GatewayServer | None = None) -> bool:
        allow = self._allow_list(identity) or []
        if "all" in allow or tool in allow:
            return True
        if "read_only" in allow:
            probe = server or self._probe
            spec = probe.tools.get(tool)
            return spec is not None and spec.read_only
        return False

    def authorize(self, identity: str, message: dict) -> str:
        if message.get("method") != "tools/call":
            return ""
        tool = str((message.get("params") or {}).get("name", ""))
        if self._tool_allowed(identity, tool):
            return ""
        return f"'{identity}' ({self.role_of(identity)}) may not call {tool} on the twin (see the allow list in twin.conf)"

    def filter_result(self, identity: str, message: dict, response: Any) -> Any:
        if message.get("method") == "tools/list" and isinstance(response, dict) and "result" in response:
            tools = [tool for tool in response["result"].get("tools", []) if self._tool_allowed(identity, tool.get("name", ""))]
            response = dict(response, result=dict(response["result"], tools=tools))
        return response

    # ---- timeline

    def emit(self, source: str, target: str, kind: str, text: str, incident: str = "", payload: Any = None, briefed: bool = False, label: str = "") -> dict:
        stamp = _now_ms()
        entry = {"t": stamp, "time": _clock(stamp), "from": source, "to": target, "kind": kind, "text": text, "incident": incident}
        if briefed:
            entry["briefed"] = True
        with self.lock:
            run = self.runs.get(incident)
            if run is not None:
                entry["run"] = run["path"].name
            elif label:
                self.pending_labels.setdefault(label, []).append(dict(entry, payload=payload))
        if payload is not None:
            entry["payload"] = payload
        if self.logs is not None:
            self.logs.write(entry)
        print(self.logs.line(entry) if self.logs else text, flush=True)
        self.push_queue.put(entry)
        return entry

    def push_status(self) -> None:
        self.push_queue.put(None)

    def status(self) -> dict:
        partners = {}
        for role, link in self.links.items():
            partners[role] = {"identity": link.partner.identity, "url": link.partner.url, "healthy": link.healthy, "detail": link.detail,
                              "standin": link.partner.standin}
        return {"twin": {"identity": self.endpoint.identity, "url": self.endpoint.url, "tls": self.endpoint.tls_min_version},
                "partners": partners, "dispatch": "brain" if self.external else "twin", "logs": str(self.logs_dir)}

    def _pusher(self) -> None:
        while not self.stop.is_set():
            try:
                first = self.push_queue.get(timeout=0.5)
            except queue.Empty:
                continue
            batch = [first]
            while True:
                try:
                    batch.append(self.push_queue.get_nowait())
                except queue.Empty:
                    break
            entries = [entry for entry in batch if entry is not None]
            for attempt in range(40):
                try:
                    self.sim.request("timeline_push", {"entries": entries, "status": self.status()})
                    break
                except SimError:
                    if self.stop.wait(0.25):
                        return

    # ---- inbound (partners calling the twin)

    def observe(self, event: str, identity: str, data: dict) -> None:
        role = self.role_of(identity)
        if event == "refused":
            self.emit("twin", "", "security", f"Refused a connection from {data.get('peer')}: {_short(data.get('reason', ''), 120)}", payload=data)
            return
        if event == "forbidden":
            message = data.get("message") or {}
            self.emit("twin", role, "security", f"Refused {role}'s request: {_short(data.get('reason', ''), 140)}", payload={"request": message, "reason": data.get("reason")})
            return
        if event == "session_closed":
            return
        message = data.get("message") or {}
        method = str(message.get("method", ""))
        if method in QUIET_METHODS:
            return
        params = message.get("params") or {}
        if method == "initialize":
            if event == "request":
                client = params.get("clientInfo", {})
                self.emit(role, "twin", "link", f"Opened an MCP session with the twin ({client.get('name', identity)}, certificate '{identity}' verified)", payload=params)
            return
        if method != "tools/call":
            return
        tool = str(params.get("name", ""))
        arguments = params.get("arguments") or {}
        meta = params.get("_meta") or {}
        incident = str(meta.get("correlationId") or arguments.get("incident") or "")
        label = str(meta.get("label", "")) or (str(arguments.get("label", "")) if tool == "trigger_incident" else "")
        if tool == "post_briefing":
            return                       # the briefing itself is the entry
        spec = self._probe.tools.get(tool)
        if role == "operator" and spec is not None and spec.read_only:
            return                       # the twin's own operator polling the city is not traffic between layers
        if event == "request":
            self.emit(role, "twin", "request", describe_call(tool, arguments), incident=incident, payload={"tool": tool, "arguments": arguments, "_meta": meta}, label=label)
        elif event == "response":
            response = data.get("response") or {}
            self.emit("twin", role, "response", describe_result(tool, arguments, response), incident=incident,
                      payload=(response.get("result") or {}).get("structuredContent", response), label=label)

    # ---- outbound (the twin reporting to the Brain)

    def _brain(self) -> PartnerLink | None:
        link = self.links.get("brain")
        return link if link is not None and link.healthy else None

    def _report(self, incident: dict, requests: list[dict]) -> None:
        link = self.links.get("brain")
        if link is None:
            return
        tool = link.partner.tools.get("report", "report_incident")
        facts = incident_facts(incident)
        asks = ", ".join(f"{request['kind']} ({_role_text(request['role'])})" + (" or mutual aid" if request.get("aid_allowed") else "") for request in requests)
        first = all(int(request.get("ask", 1)) <= 1 for request in requests) and not self.runs[incident["id"]].get("reported")
        units = ", ".join(str(unit.get("unit")) for unit in incident.get("units", []))
        if not requests:
            text = f"Reported {incident['id']}: {facts['title'].lower()} under way" + (f" with {units}" if units else "") + " (scheduled, no call to answer)"
        elif first:
            text = f"Reported {incident['id']}: {facts['title'].lower()} at {facts.get('block', '?')}, {facts['severity']}: callers need {asks}"
        else:
            text = f"Asked again for {incident['id']}: {asks}"
        self.runs[incident["id"]]["reported"] = True
        link.call(tool, {"incident": facts, "requests": requests}, incident["id"], text,
                  lambda result: f"Acknowledged {incident['id']}" + (f": {_short(result.get('note'), 100)}" if result.get("note") else ""))

    def _close(self, incident_id: str, summary: dict) -> None:
        link = self.links.get("brain")
        if link is None or not link.healthy:
            return
        tool = link.partner.tools.get("close", "close_incident")
        units = [unit.get("unit") for unit in summary.get("units", [])]
        link.call(tool, {"incident": incident_id, "outcome": "resolved", "resolved_at_s": summary.get("resolved_at"), "units": units}, incident_id,
                  f"{incident_id} is resolved: scene cleared" + (f", units {', '.join(units)} released" if units else ""),
                  lambda result: f"Closed case {incident_id}" + (f": {_short(result.get('note'), 100)}" if result.get("note") else ""))

    # ---- watching the city

    def _watch(self) -> None:
        while not self.stop.is_set():
            started = time.monotonic()
            try:
                data = self.watch_sim.request("list_incidents")
            except SimError:
                self.stop.wait(0.5)
                continue
            open_ids = set()
            for incident in data.get("incidents", []):
                open_ids.add(incident["id"])
                self._follow(incident)
            for incident_id in [key for key, run in self.runs.items() if key not in open_ids and not run.get("closed")]:
                summary = next((item for item in data.get("resolved_recently", []) if item.get("id") == incident_id), {})
                self._finish(incident_id, summary)
            self.stop.wait(max(0.0, POLL_S - (time.monotonic() - started)))

    def _follow(self, incident: dict) -> None:
        incident_id = incident["id"]
        run = self.runs.get(incident_id)
        if run is None:
            label = str(incident.get("label", ""))
            path = self.logs.open_run(incident_id, label, str(incident.get("title") or incident.get("kind", "incident")))
            with self.lock:
                run = {"path": path, "notes": set(), "asked": set(), "label": label, "closed": False, "reported": False}
                self.runs[incident_id] = run
                early = self.pending_labels.pop(label, []) if label else []
            for entry in early:              # the trigger and anything said before the incident existed head its run log
                self.logs.write(dict(entry, incident=incident_id), run["path"])
            facts = incident_facts(incident)
            self.emit("twin", "", "event", f"Opened the run log for {incident_id} ({facts['title'].lower()}{', ' + label if label else ''}): {run['path'].name}", incident=incident_id)
        for note in incident.get("timeline", []):
            key = (note.get("t"), note.get("text"))
            if key in run["notes"]:
                continue
            run["notes"].add(key)
            self.emit("twin", "", "event", f"{incident_id}: {note.get('text')}", incident=incident_id, payload={"sim_time_s": note.get("t"), "phase": incident.get("phase"),
                                                                                                          "location": incident.get("location")})
        requests = [dict(request, ask=int(request.get("ask", 1))) for request in incident.get("dispatch_requests", []) or []]   # Godot's JSON makes numbers floats
        fresh = [request for request in requests if (request["id"], request["ask"]) not in run["asked"]]
        if fresh and self._brain() is not None and self.external:
            for request in fresh:
                run["asked"].add((request["id"], request["ask"]))
            threading.Thread(target=self._report, args=(incident, fresh), daemon=True).start()
        elif not run["reported"] and incident.get("category") == "service" and incident.get("units") and self._brain() is not None:
            # A scheduled round calls nobody: the Brain is told it is under way, with no decision to make.
            run["reported"] = True
            threading.Thread(target=self._report, args=(incident, []), daemon=True).start()

    def _finish(self, incident_id: str, summary: dict) -> None:
        run = self.runs[incident_id]
        run["closed"] = True
        for note in summary.get("timeline", []):
            key = (note.get("t"), note.get("text"))
            if key not in run["notes"]:
                run["notes"].add(key)
                self.emit("twin", "", "event", f"{incident_id}: {note.get('text')}", incident=incident_id, payload={"sim_time_s": note.get("t")})
        self.emit("twin", "", "event", f"{incident_id} closed: every unit released, the road is open", incident=incident_id, payload=summary or None)
        threading.Thread(target=self._close, args=(incident_id, summary), daemon=True).start()

    # ---- the decision lease and partner health

    def _lease(self) -> None:
        while not self.stop.is_set():
            want = self.dispatch_by == "brain" and self._brain() is not None
            try:
                if want:
                    self.sim.request("command", {"id": "INCIDENTS", "command": "decisions", "value": {"mode": "external", "lease_s": self.lease_s}})
                elif self.external:
                    self.sim.request("command", {"id": "INCIDENTS", "command": "decisions", "value": {"mode": "auto"}})
                if want != self.external:
                    self.external = want
                    self.emit("twin", "", "link", "The City Brain now decides which unit answers each emergency call (through dispatch_units)" if want
                              else "The twin's own dispatcher answers emergency calls until the City Brain is back")
                    self.push_status()
            except SimError:
                pass
            self.stop.wait(LEASE_RENEW_S)

    def _health(self, link: PartnerLink) -> None:
        while not self.stop.is_set():
            link.check()
            self.stop.wait(HEALTH_S)

    # ---- life cycle

    def run(self) -> int:
        problems = self.check()
        if problems:
            for problem in problems:
                print(f"twin.conf: {problem}", file=sys.stderr)
            return 2
        brain, guardian = self.partners.get("brain"), self.partners.get("guardian")
        header = [f"Layers:  Twin '{self.endpoint.identity}' at {self.endpoint.url} · "
                  f"Brain '{brain.identity}' at {brain.url}{' (stand-in)' if brain.standin else ''} · "
                  f"Guardian '{guardian.identity}' at {guardian.url}{' (stand-in)' if guardian.standin else ''}",
                  f"Links:   MCP {self.endpoint.path} (Streamable HTTP) over mutually authenticated TLS {self.endpoint.tls_min_version}+, configured in {self.config_path.name}"]
        self.logs = RunLogs(self.logs_dir, self.payload_limit, header)
        trusted = [str(path) for path in self.endpoint.trusted_ca]
        tls_server = server_context(str(self.endpoint.certificate), str(self.endpoint.private_key), trusted, self.endpoint.tls_min_version)
        tls_client = client_context(str(self.endpoint.certificate), str(self.endpoint.private_key), trusted, self.endpoint.tls_min_version)
        self._probe = GatewayServer(self.sim, self, "")
        self.server = McpHttpsServer(self.endpoint.listen_host, self.endpoint.listen_port, self.endpoint.path, tls_server,
                                     make_handler=lambda identity: GatewayServer(self.sim, self, identity), authorize=self.authorize,
                                     allowed_identities=lambda identity: self._allow_list(identity) is not None, observe=self.observe,
                                     filter_result=self.filter_result)
        self.server.start()
        threading.Thread(target=self._pusher, daemon=True).start()
        self.emit("twin", "", "link", f"The twin's MCP endpoint is listening at {self.endpoint.url} (TLS {self.endpoint.tls_min_version}+, client certificates required)",
                  payload=self.status())
        for partner in self.partners.values():
            link = PartnerLink(partner, tls_client, self)
            self.links[partner.role] = link
            threading.Thread(target=self._health, args=(link,), daemon=True).start()
        threading.Thread(target=self._watch, daemon=True).start()
        threading.Thread(target=self._lease, daemon=True).start()
        signal.signal(signal.SIGTERM, lambda *_: self.stop.set())
        signal.signal(signal.SIGINT, lambda *_: self.stop.set())
        while not self.stop.wait(0.5):
            pass
        self.emit("twin", "", "link", "The twin's gateway is stopping")
        time.sleep(0.3)
        self.server.stop()
        return 0


# ------------------------------------------------------------------------------------------- wording

def incident_facts(incident: dict) -> dict:
    location = dict(incident.get("location") or {})
    requests = incident.get("dispatch_requests") or []
    point = (requests[0].get("location") if requests else None) or ({"x": location["x"], "z": location["z"]} if "x" in location and "z" in location else None)
    facts = {"id": incident.get("id"), "kind": incident.get("kind"), "title": incident.get("title") or incident.get("kind", "incident"),
             "category": incident.get("category"), "severity": incident.get("severity", "minor"), "phase": incident.get("phase"),
             "location": location, "point": point, "participants": [item.get("id") for item in incident.get("participants", [])],
             "injuries": [item.get("id") for item in incident.get("participants", []) if item.get("injured") or item.get("trapped")],
             "callers": len(incident.get("callers") or {}), "units": incident.get("units", []), "label": incident.get("label", "")}
    if point:
        facts["block"] = layer_config.block_label(float(point["x"]), float(point["z"]))
    return facts


def describe_call(tool: str, arguments: dict) -> str:
    if tool == "dispatch_units":
        parts = []
        for decision in arguments.get("decisions", []):
            action = decision.get("action")
            request = str(decision.get("request", ""))
            if action == "unit":
                parts.append(f"{decision.get('unit')} for {request}")
            elif action == "mutual_aid":
                parts.append(f"mutual aid for {request}")
            else:
                parts.append(f"{action} {request}")
        return f"Dispatch decision for {arguments.get('incident')}: {', '.join(parts)}"
    if tool == "list_emergency_units":
        return "Read the emergency fleet" + (f" ({arguments['kind']})" if arguments.get("kind") else "")
    if tool == "read_vehicle":
        return f"Read vehicle {arguments.get('id')}"
    if tool == "list_vehicles":
        return "Read the vehicles" + (f" in sector {arguments['sector']}" if arguments.get("sector") else "")
    if tool == "trigger_incident":
        return f"Trigger {arguments.get('kind', '').replace('_', ' ')}" + (f" ({arguments['label']})" if arguments.get("label") else "")
    if tool == "read_sector":
        return f"Read sector {arguments.get('sector')}"
    if tool in ("read_sensor", "read_parking_lot", "read_citizen"):
        return f"Read {arguments.get('id')}"
    if tool == "list_incidents":
        return "Read the open incidents"
    shown = {key: value for key, value in arguments.items() if not key.startswith("_")}
    return f"Called {tool}" + (f" {_short(shown, 80)}" if shown else "")


def describe_result(tool: str, arguments: dict, response: dict) -> str:
    if "error" in response:
        return f"Refused {tool}: {_short(response['error'].get('message', ''), 120)}"
    result = response.get("result") or {}
    data = result.get("structuredContent") or {}
    if result.get("isError"):
        error = data.get("error") or {}
        return f"Refused {tool}: {_short(error.get('message', ''), 120)}"
    if tool == "dispatch_units":
        return f"Dispatch accepted: {_short(data.get('applied', ''), 140)}"
    if tool == "list_emergency_units":
        units = data.get("units", [])
        return f"Fleet: {len(units)} units, {sum(1 for unit in units if unit.get('available'))} free"
    if tool == "read_vehicle":
        speed = data.get("speed_mps", data.get("speed"))
        where = data.get("sector") or ""
        return f"Vehicle {arguments.get('id')}: " + (f"{float(speed):.1f} m/s" if isinstance(speed, (int, float)) else "found") + (f" in sector {where}" if where else "")
    if tool == "list_vehicles":
        return f"{data.get('count', len(data.get('vehicles', [])))} vehicles"
    if tool == "trigger_incident":
        return f"Incident requested ({data.get('applied', 'ok')})"
    if tool == "list_incidents":
        return f"{len(data.get('incidents', []))} open incidents"
    if tool == "read_sector":
        return f"Sector {data.get('sector')}: {data.get('devices', 0)} devices, {data.get('buildings', 0)} buildings"
    if tool == "control_incident":
        return f"Done: {_short(data.get('applied', 'ok'), 120)}"
    return f"Answered {tool}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=HERE.parents[2] / "twin.conf")
    parser.add_argument("--check", action="store_true", help="validate the configuration and exit")
    args = parser.parse_args()
    try:
        gateway = Gateway(args.config)
    except layer_config.ConfigError as error:
        print(f"twin.conf: {error}", file=sys.stderr)
        return 2
    if args.check:
        problems = gateway.check()
        for problem in problems:
            print(problem)
        if not problems:
            print(f"twin.conf OK: endpoint {gateway.endpoint.url}, partners: " + ", ".join(f"{p.role} at {p.url}" for p in gateway.partners.values()))
        return 1 if problems else 0
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    return gateway.run()


if __name__ == "__main__":
    sys.exit(main())
