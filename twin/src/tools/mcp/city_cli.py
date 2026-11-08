#!/usr/bin/env python3
"""Interactive MCP terminal for the City Ground Zero simulation.

This is a real MCP client: it starts the MCP server (city_mcp_server.py) as a subprocess, performs the
initialize / initialized handshake, lists the tools, and sends every command you type as a JSON-RPC `tools/call`
over stdio. The server forwards it to the running Godot city, so every answer is a live reading or a real actuator
change. Nothing in this file knows about sensors: it only speaks MCP.

    ./run_control_room.sh            # opens the city and then this terminal
    python3 tools/mcp/city_cli.py --exec "call read_sensor id=CAN-F.1-1"
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import select
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from city_form import FormBook, LineEditor  # noqa: E402

HERE = Path(__file__).resolve().parent
CLIENT_PROTOCOL = "2025-06-18"

BOLD, DIM, GREEN, RED, CYAN, YELLOW, RESET = "\033[1m", "\033[2m", "\033[32m", "\033[31m", "\033[36m", "\033[33m", "\033[0m"

EXAMPLES = [
    ("What is the city doing right now?", "city_status()"),
    ("List the waste-bin weight sensors", 'list_sensors(family="waste", limit=5)'),
    ("Watch one bin's weight live", 'read_sensor(id="CAN-F.1-1")'),
    ("Read it once instead of streaming", 'read_sensor(id="CAN-F.1-1", once=True)'),
    ("Capture 15 s of a bin with a trend line", 'watch_sensor(id="CAN-F.1-1", metric="bin_weight", duration_s=15)'),
    ("The fullest bins", "waste_bin_report(limit=5)"),
    ("Air quality across the city", 'sensor_summary(family="air")'),
    ("Two sensors in the same frame", 'read_sensors(ids=["AIR-F.1", "NOISE-F.3"])'),
    ("List the power switches", 'list_actuators(family="power_switch")'),
    ("What can a switch do?", 'list_commands(id="SWT-F.3")'),
    ("Open a power switch cabinet", 'set_power_switch(id="SWT-F.3", state="open")'),
    ("... and close it again", 'set_power_switch(id="SWT-F.3", state="close")'),
    ("Switch a street light on in the daytime", 'set_street_light(id="LGT-A.1-1", mode="on")'),
    ("Return it to the adaptive schedule", 'set_street_light(id="LGT-A.1-1", mode="auto")'),
    ("Close a water valve", 'set_valve(id="VLV-F.1", state="close")'),
    ("Make it rain", 'set_weather(weather="rain")'),
    ("Jump to 22:30", 'set_time_of_day(time="22:30")'),
    ("List the sector services", 'list_sensors(family="sector_service", limit=3)'),
    ("Empty a full bin", 'empty_waste_bin(id="BIN-E.1")'),
    ("Send a raw JSON-RPC message", 'raw {"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"city_status","arguments":{}}}'),
]


CLEAR = "\033[3J\033[2J\033[H"   # wipe the screen and its scrollback, cursor to the top

# (family, what it measures) shown in the header with live ids fetched through MCP
FAMILY_GUIDE = [
    ("waste", "bin weight kg, fill %, items thrown in"),
    ("air", "PM2.5, PM10, NO2, vehicle smoke"),
    ("traffic", "vehicles, speed, road occupancy"),
    ("weather", "wind, rain, temperature"),
    ("power_switch", "feeder switch: open/close it"),
    ("lighting", "street light: on/off/auto/dim"),
    ("water_valve", "water valve: open/close"),
    ("reservoir", "water level and demand"),
    ("sector_service", "cut/restore power or water"),
]


def _error_text(result: dict) -> str:
    error = (result.get("structuredContent") or {}).get("error")
    return f"{error['code']}: {error['message']}" if isinstance(error, dict) else result["content"][0]["text"]


class MCPError(Exception):
    pass


class MCPClient:
    """Minimal MCP client over a stdio subprocess (newline-delimited JSON-RPC 2.0)."""

    def __init__(self, command: list[str], env: dict[str, str] | None = None, trace: Callable[[str, dict], None] | None = None):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, bufsize=1, env=env, start_new_session=True)
        self._next_id = 0
        self._write_lock = threading.Lock()
        self.trace = trace or (lambda direction, message: None)
        self.server_info: dict = {}
        self.protocol = ""
        self.tools: list[dict] = []
        self._stderr: list[str] = []
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _drain_stderr(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            self._stderr.append(line.rstrip())

    def _send(self, message: dict) -> None:
        assert self.process.stdin is not None
        self.trace("->", message)
        with self._write_lock:
            self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
            self.process.stdin.flush()

    def _read(self) -> dict:
        assert self.process.stdout is not None
        line = self.process.stdout.readline()
        if not line:
            raise MCPError("the MCP server stopped" + (": " + self._stderr[-1] if self._stderr else ""))
        message = json.loads(line)
        self.trace("<-", message)
        return message

    def request(self, method: str, params: dict | None = None, on_notification: Callable[[dict], None] | None = None) -> Any:
        self._next_id += 1
        request_id = self._next_id
        message: dict = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self._send(message)
        try:
            return self._await(request_id, on_notification)
        except KeyboardInterrupt:
            # Ctrl+C ends a running call the MCP way: tell the server to cancel it, then collect its final answer.
            self.cancel(request_id, "interrupted from the terminal")
            return self._await(request_id, on_notification)

    def cancel(self, request_id: int, reason: str = "") -> None:
        self.notify("notifications/cancelled", {"requestId": request_id, "reason": reason})

    @property
    def last_request_id(self) -> int:
        return self._next_id

    def _await(self, request_id: Any, on_notification: Callable[[dict], None] | None) -> Any:
        while True:
            message = self._read()
            if "id" not in message or message.get("id") is None and "method" in message:
                if on_notification:
                    on_notification(message)
                continue
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise MCPError(f"{message['error'].get('message')} (code {message['error'].get('code')})")
            return message.get("result")

    def notify(self, method: str, params: dict | None = None) -> None:
        message: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._send(message)

    def initialize(self) -> dict:
        result = self.request("initialize", {
            "protocolVersion": CLIENT_PROTOCOL, "capabilities": {}, "clientInfo": {"name": "city-cli", "version": "1.0.0"},
        })
        self.server_info = result.get("serverInfo", {})
        self.protocol = result.get("protocolVersion", "")
        self.notify("notifications/initialized")
        self.tools = self.request("tools/list").get("tools", [])
        return result

    def call_tool(self, name: str, arguments: dict, on_progress: Callable[[dict], None] | None = None) -> dict:
        params: dict = {"name": name, "arguments": arguments}
        if on_progress is not None:
            params["_meta"] = {"progressToken": f"cli-{self._next_id + 1}"}
        return self.request("tools/call", params, on_notification=on_progress)

    def raw(self, message: dict) -> list[dict]:
        """Send a hand-written JSON-RPC message and return everything the server answers with."""
        self._send(message)
        if "id" not in message:
            return []
        out = []
        while True:
            reply = self._read()
            out.append(reply)
            if reply.get("id") == message["id"]:
                return out

    def close(self) -> None:
        try:
            if self.process.stdin:
                self.process.stdin.close()
            self.process.wait(timeout=3)
        except Exception:
            self.process.kill()
        for stream in (self.process.stdout, self.process.stderr):
            if stream:
                stream.close()


# ----------------------------------------------------------------------------------------------------------------

def parse_value(text: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        if text.startswith("[") and text.endswith("]"):
            # The shell removed the quotes: ids=[AIR-F.1,NOISE-F.3] is still a list of strings.
            return [item.strip().strip("\"'") for item in text[1:-1].split(",") if item.strip()]
        return text


def parse_call(line: str) -> tuple[str, list, dict] | None:
    """`read_sensor(id="CAN-F.1-1", once=True)` -> ("read_sensor", [], {"id": "CAN-F.1-1", "once": True}); None if not a call."""
    match = re.fullmatch(r"\s*([A-Za-z_]\w*)\s*\((.*)\)\s*", line, re.S)
    if not match:
        return None
    try:
        node = ast.parse(f"f({match.group(2)})", mode="eval").body
        assert isinstance(node, ast.Call)
        positional = [ast.literal_eval(a) for a in node.args]
        keywords = {k.arg: ast.literal_eval(k.value) for k in node.keywords if k.arg}
    except (SyntaxError, ValueError, AssertionError) as error:
        raise MCPError(f"cannot read the arguments of {match.group(1)}(...): {error}")
    return match.group(1), positional, keywords


def parse_arguments(tokens: list[str], schema: dict | None) -> dict:
    """key=value tokens (values are JSON when they parse, text otherwise), or one JSON object."""
    if len(tokens) == 1 and tokens[0].startswith("{"):
        return json.loads(tokens[0])
    arguments: dict = {}
    positional: list[str] = []
    for token in tokens:
        if "=" in token and not token.startswith(("{", "[", '"')):
            key, value = token.split("=", 1)
            arguments[key] = parse_value(value)
        else:
            positional.append(token)
    required = (schema or {}).get("required", [])
    for key, value in zip([k for k in required if k not in arguments], positional):
        arguments[key] = parse_value(value) if key != "id" else value
    return arguments


def table(rows: list[list[str]], header: list[str]) -> str:
    widths = [max(len(str(row[i])) for row in [header] + rows) for i in range(len(header))]
    lines = ["  ".join(str(cell).ljust(widths[i]) for i, cell in enumerate(header))]
    lines.append("  ".join("-" * w for w in widths))
    for row in rows:
        lines.append("  ".join(str(cell).ljust(widths[i]) for i, cell in enumerate(row)))
    return "\n".join(lines)


def sparkline(values: list[float]) -> str:
    bars = "▁▂▃▄▅▆▇█"
    low, high = min(values), max(values)
    if high - low < 1e-9:
        return bars[0] * len(values)
    return "".join(bars[min(7, int((v - low) / (high - low) * 7.999))] for v in values)


def render(tool: str, data: Any) -> str:
    """Readable text for the common tools; everything else prints as JSON."""
    if not isinstance(data, dict):
        return json.dumps(data, indent=2)
    if tool == "city_status":
        families = ", ".join(f"{k} {v}" for k, v in sorted(data["families"].items()))
        return (f"{BOLD}{data['name']}{RESET}  day {data['day']}  {data['clock']}  ({data['period']})  weather {data['weather']}  "
                f"speed {data['speed']:g}x  {'PAUSED' if data['paused'] else 'running'}\n{data['device_count']} devices: {families}")
    if tool in ("list_sensors", "list_actuators"):
        rows = [[d["id"], d["family"], d["name"], d["type"], ",".join(d["commands"]) or "-"] for d in data["devices"]]
        return f"{data['total']} devices (showing {data['count']} from {data['offset']})\n" + table(rows, ["id", "family", "name", "type", "commands"])
    if tool == "read_sensor":
        rows = [[m, f"{r['value']:g}", r["unit"]] for m, r in data["readings"].items()]
        extra = f"\nstate: {json.dumps(data['state'])}" if data.get("state") else ""
        return f"{BOLD}{data['id']}{RESET}  {data['name']}  ({data['type']})  at {data['sampled_at']['clock']}  frame {data['sampled_at']['frame']}\n" + table(rows, ["metric", "value", "unit"]) + extra
    if tool == "read_sensors":
        out = []
        for d in data["devices"]:
            out.append(f"{BOLD}{d['id']}{RESET}  " + "  ".join(f"{m}={r['value']:g}{r['unit']}" for m, r in d["readings"].items()))
        if data["unknown_ids"]:
            out.append(f"{RED}unknown: {', '.join(data['unknown_ids'])}{RESET}")
        return "\n".join(out)
    if tool == "waste_bin_report":
        rows = [[b["id"], b["kind"], f"{b['weight_kg']:.2f}", f"{b['fill_percent']:.1f}", b["deposits"]] for b in data["bins"]]
        return f"{data['matching']} bins, {data['total_weight_kg']} kg in total\n" + table(rows, ["id", "kind", "kg", "fill %", "deposits"])
    if tool == "watch_sensor":
        values = [s["value"] for s in data["samples"]]
        return f"{data['id']} {data['metric']} ({data['unit']})  {sparkline(values)}  min {data['min']:g}  max {data['max']:g}  change {data['change']:+g}  ({len(values)} samples)"
    if tool == "sensor_summary":
        rows = []
        for family, metrics in data["families"].items():
            for metric, s in metrics.items():
                rows.append([family, metric, s["devices"], s["min"], s["mean"], s["max"], s["unit"]])
        return table(rows, ["family", "metric", "n", "min", "mean", "max", "unit"])
    if "applied" in data:
        text = f"{GREEN}{data['applied']}{RESET}"
        before, after = data.get("before"), data.get("after")
        if isinstance(before, dict) and isinstance(after, dict) and before and "value" in next(iter(before.values()), {}):
            text += "\n" + "\n".join(f"  {m}: {before[m]['value']:g} -> {after[m]['value']:g} {after[m]['unit']}" for m in after if m in before)
        return text
    return json.dumps(data, indent=2, ensure_ascii=False)


class Terminal:
    def __init__(self, client: MCPClient, show_protocol: bool = False, as_json: bool = False):
        self.client = client
        self.show_protocol = show_protocol
        self.as_json = as_json
        self.interactive = False
        client.trace = self._trace

    def _trace(self, direction: str, message: dict) -> None:
        if self.show_protocol:
            colour = CYAN if direction == "->" else YELLOW
            text = json.dumps(message, separators=(",", ":"))
            print(f"{colour}{direction} {text[:600]}{'…' if len(text) > 600 else ''}{RESET}")

    def tool_schema(self, name: str) -> dict | None:
        for tool in self.client.tools:
            if tool["name"] == name:
                return tool.get("inputSchema")
        return None

    def run_line(self, line: str) -> bool:
        """Execute one line; returns False when the session should end."""
        line = line.strip()
        if not line or line.startswith("#"):
            return True
        try:
            called = parse_call(line)
        except MCPError as error:
            print(f"{RED}{error}{RESET}")
            return True
        if called is not None:
            return self.run_function(*called)
        try:
            tokens = shlex.split(line)
        except ValueError as error:
            print(f"{RED}cannot parse: {error}{RESET}")
            return True
        command, rest = tokens[0], tokens[1:]
        names = [t["name"] for t in self.client.tools]
        try:
            if command in ("exit", "quit", "q"):
                return False
            elif command == "help":
                self.help()
            elif command == "tools":
                self.list_tools()
            elif command in ("describe", "desc") and rest:
                self.describe(rest[0])
            elif command == "examples":
                self.examples()
            elif command == "example" and rest and rest[0].isdigit():
                self.run_example(int(rest[0]))
            elif command == "protocol":
                self.show_protocol = not rest or rest[0] == "on"
                print(f"protocol trace {'on' if self.show_protocol else 'off'}")
            elif command == "json":
                self.as_json = not rest or rest[0] == "on"
                print(f"raw JSON output {'on' if self.as_json else 'off'}")
            elif command == "resources":
                print(json.dumps(self.client.request("resources/list"), indent=2))
            elif command == "read" and rest:
                print(json.dumps(self.client.request("resources/read", {"uri": rest[0]}), indent=2))
            elif command == "raw":
                for reply in self.client.raw(json.loads(line.split(None, 1)[1])):
                    print(json.dumps(reply, indent=2))
            elif command == "call" and rest:
                self.call(rest[0], rest[1:])
            elif command in names:
                self.call(command, rest)
            else:
                print(f"{RED}unknown command '{command}'. Type help.{RESET}")
        except (MCPError, json.JSONDecodeError, IndexError) as error:
            print(f"{RED}error: {error}{RESET}")
        return True

    def run_function(self, name: str, positional: list, keywords: dict) -> bool:
        schema = self.tool_schema(name)
        if schema is None:
            print(f"{RED}unknown function '{name}'. Type tools to see them.{RESET}")
            return True
        required = [k for k in schema.get("required", []) if k not in keywords]
        arguments = dict(keywords)
        for key, value in zip(required, positional):
            arguments[key] = value
        try:
            self.call(name, [], arguments)
        except (MCPError, json.JSONDecodeError) as error:
            print(f"{RED}error: {error}{RESET}")
        return True

    def call(self, name: str, tokens: list[str], preset: dict | None = None) -> None:
        schema = self.tool_schema(name)
        if schema is None:
            print(f"{RED}unknown tool '{name}'. Type tools.{RESET}")
            return
        arguments = dict(preset) if preset is not None else parse_arguments(tokens, schema)
        # The terminal adds nothing to the call: it sends the tool exactly what was typed. It only asks for progress
        # notifications when a person is at the keyboard (so a streaming tool can be watched and cancelled with q / Ctrl+C)
        # and prints whatever the tool sends back.
        tty = sys.stdout.isatty()
        state = {"lines": 0, "count": 0, "last": None}
        started = time.monotonic()

        def progress(message: dict) -> None:
            if message.get("method") != "notifications/progress":
                return
            try:
                update = json.loads(message["params"]["message"])
            except (KeyError, json.JSONDecodeError):
                print(f"{DIM}  … {message['params'].get('message', '')}{RESET}")
                return
            if "data" in update:
                if state["count"] == 0:
                    print(f"{BOLD}● live {name}{RESET}  {DIM}press q or Ctrl+C to stop{RESET}")
                self.show_update(update.get("tool", name), update["data"], state, tty)
            else:
                print(f"{DIM}  … {message['params'].get('message', '')}{RESET}")

        watching = self.interactive and sys.stdin.isatty()
        watcher = KeyWatcher(self.client, self.client.last_request_id + 1) if watching else None
        try:
            result = self.client.call_tool(name, arguments, on_progress=progress if watching else None)
        finally:
            if watcher:
                watcher.stop()
        elapsed = (time.monotonic() - started) * 1000.0
        if result.get("isError"):
            print(f"{RED}{_error_text(result)}{RESET}")
            return
        data = result.get("structuredContent")
        if data is not None and set(data) == {"result"}:
            data = data["result"]
        if data is None:
            data = json.loads(result["content"][0]["text"])
        if isinstance(data, dict) and "samples" in data and "updates" in data:        # a streamed call: the tool returned every sample
            if state["count"] == 0:
                for sample in data["samples"]:
                    self.show_update(data["tool"], sample["data"], state, False)
            print(f"{DIM}[{name} · {data['updates']} live updates · {'stopped by you' if data['cancelled'] else 'finished'} · via MCP {self.client.protocol}]{RESET}")
            return
        print(json.dumps(data, indent=2, ensure_ascii=False) if self.as_json else render(name, data))
        print(f"{DIM}[{name} · {elapsed:.0f} ms · via MCP {self.client.protocol}]{RESET}")

    def show_update(self, name: str, data: dict, state: dict, tty: bool) -> None:
        state["count"] += 1
        if self.as_json:
            print(json.dumps(data, ensure_ascii=False))
            return
        if name == "read_sensor":
            previous = state["last"] or {}
            parts = []
            for metric, reading in data["readings"].items():
                value = reading["value"]
                old = previous.get(metric)
                arrow, colour = ("", "")
                if old is not None and value > old:
                    arrow, colour = "▲", GREEN
                elif old is not None and value < old:
                    arrow, colour = "▼", YELLOW
                parts.append(f"{metric} {colour}{value:g}{arrow}{RESET} {reading['unit']}")
            state["last"] = {m: r["value"] for m, r in data["readings"].items()}
            print(f"{DIM}{data['sampled_at']['clock']}{RESET}  {BOLD}{data['id']}{RESET}  " + "  ·  ".join(parts))
            return
        text = render(name, data) + f"\n{DIM}● live · update #{state['count']} · press q or Ctrl+C to stop{RESET}"
        if tty and state["lines"]:
            sys.stdout.write(f"\033[{state['lines']}A\033[J")
        print(text)
        state["lines"] = text.count("\n") + 1
        sys.stdout.flush()

    # ------------------------------------------------------------------ header

    def discover_samples(self) -> dict[str, list[str]]:
        """A few live ids per family (asked through MCP): what the autocomplete and the header fill in."""
        if getattr(self, "_samples", None):
            return self._samples
        for attempt in range(6):   # the street-bin sensors are fitted a moment after the city starts
            samples = self._sample_ids()
            if any(i.startswith("CAN-") for i in samples.get("waste", [])) or not samples.get("waste"):
                break
            time.sleep(0.5)
        self._samples = samples
        return samples

    def _sample_ids(self) -> dict[str, list[str]]:
        samples: dict[str, list[str]] = {}
        for family in ("waste", "air", "traffic", "noise", "weather", "power_meter", "power_switch", "lighting", "water_valve", "sector_service"):
            try:
                devices = self.client.call_tool("list_sensors", {"family": family, "limit": 200 if family == "waste" else 6})["structuredContent"]["devices"]
            except (MCPError, KeyError):
                continue
            ids = [d["id"] for d in devices]
            if family == "waste":
                ids = [i for i in ids if i.startswith("CAN-")][:4] + [i for i in ids if i.startswith("BIN-")][:2] or ids[:4]
            samples[family] = ids[:6]
        return samples

    def header(self) -> str:
        """Short banner: what to type, the functions, a few live ids, three things to try."""
        client = self.client
        lines = [f"{BOLD}CITY GROUND ZERO · MCP TERMINAL{RESET}"]
        try:
            status = client.call_tool("city_status", {})["structuredContent"]
            lines.append(f"{GREEN}● live{RESET}  day {status['day']}  {status['clock']}  {status['weather']}  ·  {status['device_count']} devices")
        except (MCPError, KeyError):
            lines.append(f"{YELLOW}● city not reachable{RESET}")
        dashboard = os.environ.get("CITY_DASHBOARD_URL", "")
        if dashboard:
            lines.append(f"{GREEN}● dashboard{RESET}  {dashboard}   {DIM}(an MCP client of this city){RESET}")
        lines += ["", f"Press {BOLD}↑ ↓{RESET} to browse the commands, or start typing: the rest is suggested ({BOLD}◀ ▶{RESET} other functions, {BOLD}Tab{RESET} pastes it).",
                  f"{BOLD}Enter{RESET} runs the line. The sensor functions stream live by themselves; stop with {BOLD}q{RESET} or {BOLD}Ctrl+C{RESET} (or add once=True).", "",
                  f"{BOLD}Sensors{RESET}   {DIM}(live){RESET}",
                  f"  {CYAN}read_sensor{RESET}(id)               one device",
                  f"  {CYAN}read_sensors{RESET}(ids)             several devices",
                  f"  {CYAN}waste_bin_report{RESET}()            all bins, fullest first",
                  f"  {CYAN}sensor_summary{RESET}(family)        min / mean / max",
                  f"  {CYAN}city_status{RESET}()                 clock, weather, counts",
                  "", f"{BOLD}Actuators{RESET}   {DIM}(act once, show before → after){RESET}",
                  f"  {CYAN}set_power_switch{RESET}(id, state)   open / close",
                  f"  {CYAN}set_valve{RESET}(id, state)          open / close",
                  f"  {CYAN}set_street_light{RESET}(id, mode)    on / off / auto / dim",
                  f"  {CYAN}set_weather{RESET}(weather)          clear / rain / storm / fog …",
                  f"  {CYAN}empty_waste_bin{RESET}(id)           empty one bin",
                  "", f"{BOLD}City{RESET}   {DIM}(sectors A to P, parking, earthquakes, incidents){RESET}",
                  f"  {CYAN}read_sector{RESET}(sector)                everything in one sector      {CYAN}list_parking_lots{RESET}()   smart car parks",
                  f"  {CYAN}trigger_earthquake{RESET}(sector, magnitude)   {CYAN}clear_earthquakes{RESET}()   {CYAN}trigger_incident{RESET}(kind)   {CYAN}list_vehicles{RESET}()"]
        samples = self.discover_samples()
        picks = []
        for family, label in (("waste", "bin"), ("air", "air"), ("power_switch", "switch"), ("lighting", "light"), ("water_valve", "valve")):
            if samples.get(family):
                picks.append(f"{label} {CYAN}{', '.join(samples[family][:2])}{RESET}")
        if picks:
            lines += ["", f"{BOLD}Ids to try{RESET}   " + "    ".join(picks)]
        lines += ["", f"{DIM}Also: examples · tools · help · exit{RESET}"]
        return "\n".join(lines)

    def help(self) -> None:
        print(f"""{BOLD}How to use{RESET}
  ↑ ↓                               browse the commands (each shows a ready-to-run call)
  type                              the matching function appears faintly; ◀ ▶ other matching functions, Tab pastes it, Enter runs
  read_sensor(id="CAN-F.1-1")        or type a call (keyword arguments; strings in quotes)
  read_sensor("CAN-F.1-1")           the first required argument can be positional
  read_sensor(id="CAN-F.1-1", once=True)   one reading instead of a stream; interval_s=0.5 sets the rate, duration_s=20 stops after 20 s
  tools                             every function and its arguments
  describe set_power_switch         details of one function
  examples / example 3              ready-made calls / run number 3
  protocol on|off                   show the raw JSON-RPC messages
  exit                              close the terminal (and the city)""")

    def list_tools(self) -> None:
        rows = []
        for tool in self.client.tools:
            props, required = tool["inputSchema"].get("properties", {}), tool["inputSchema"].get("required", [])
            signature = ", ".join(k if k in required else f"{k}?" for k in props)
            rows.append([f"{tool['name']}({signature})", tool["description"][:80]])
        print(table(rows, ["function", "what it does"]))

    def describe(self, name: str) -> None:
        for tool in self.client.tools:
            if tool["name"] == name:
                print(f"{BOLD}{name}{RESET}\n{tool['description']}\n{json.dumps(tool['inputSchema'], indent=2)}")
                return
        print(f"{RED}unknown tool '{name}'{RESET}")

    def examples(self) -> None:
        for number, (title, line) in enumerate(EXAMPLES, 1):
            print(f"{BOLD}{number:2d}{RESET}  {title}\n    {DIM}{line}{RESET}")

    def run_example(self, number: int) -> None:
        if not 1 <= number <= len(EXAMPLES):
            print(f"{RED}example {number} does not exist{RESET}")
            return
        title, line = EXAMPLES[number - 1]
        print(f"{BOLD}{title}{RESET}\n{DIM}city-mcp> {line}{RESET}")
        self.run_line(line)


class KeyWatcher:
    """While a subscription streams, pressing q (or Esc) cancels it: sends notifications/cancelled to the server."""

    def __init__(self, client: MCPClient, request_id: int):
        import termios
        import tty
        self._termios = termios
        self._fd = sys.stdin.fileno()
        self._saved = termios.tcgetattr(self._fd)
        tty.setcbreak(self._fd, termios.TCSANOW)   # keys arrive without Enter; Ctrl+C still raises KeyboardInterrupt
        self._client = client
        self._request_id = request_id
        self._running = True
        self._thread = threading.Thread(target=self._watch, daemon=True)
        self._thread.start()

    def _watch(self) -> None:
        while self._running:
            ready, _, _ = select.select([sys.stdin], [], [], 0.1)
            if ready and self._running:
                key = os.read(self._fd, 1)
                if key in (b"q", b"Q", b"\x1b"):
                    self._client.cancel(self._request_id, "stopped from the terminal")
                    return

    def stop(self) -> None:
        self._running = False
        self._thread.join(timeout=0.5)
        self._termios.tcsetattr(self._fd, self._termios.TCSADRAIN, self._saved)


def city_alive() -> bool:
    pid = os.environ.get("CITY_GODOT_PID", "")
    if not pid.isdigit():
        return True
    try:
        os.kill(int(pid), 0)
        return True
    except OSError:
        return False


def interactive(terminal: Terminal) -> None:
    terminal.interactive = True
    history_file = Path.home() / ".city_mcp_history"
    history: list[str] = []
    try:
        history = history_file.read_text().splitlines()[-200:]
    except OSError:
        pass
    book = FormBook(terminal.client.tools, terminal.discover_samples())
    commands = [t["name"] for t in terminal.client.tools] + ["tools", "describe", "examples", "example", "protocol", "json", "raw", "resources", "read", "help", "exit"]
    editor = LineEditor(book, history, commands)
    while True:
        if not city_alive():
            print(f"{YELLOW}The city window was closed — ending the terminal.{RESET}")
            break
        try:
            line = editor.read(f"{GREEN}city-mcp>{RESET} ", city_alive)
        except KeyboardInterrupt:
            print()
            # At the idle prompt Ctrl+C is an explicit request to end the
            # control session.  The launcher observes that exit and tears down
            # the city, SUMO bridge and planner as one application.
            break
        if line is None:
            print()
            break
        if not terminal.run_line(line):
            break
    try:
        history_file.write_text("\n".join(history[-200:]) + "\n")
    except OSError:
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Interactive MCP terminal for the City Ground Zero simulation")
    parser.add_argument("--exec", "-c", action="append", default=[], metavar="LINE", help="run this command and exit (repeatable)")
    parser.add_argument("--script", help="run the commands in this file and exit")
    parser.add_argument("--show-protocol", action="store_true", help="print every JSON-RPC message")
    parser.add_argument("--json", action="store_true", help="print raw JSON results")
    parser.add_argument("--server", default=str(HERE / "city_mcp_server.py"), help="MCP server script to start")
    parser.add_argument("--port", type=int, help="city device-API port (default: CITY_SIM_API_PORT)")
    args = parser.parse_args(argv)
    env = dict(os.environ)
    if args.port:
        env["CITY_SIM_API_PORT"] = str(args.port)
    client = MCPClient([sys.executable, args.server], env=env)
    terminal = Terminal(client, show_protocol=args.show_protocol, as_json=args.json)
    try:
        info = client.initialize()
    except (MCPError, OSError) as error:
        print(f"{RED}could not start the MCP server: {error}{RESET}")
        return 1
    batch = list(args.exec)
    if args.script:
        batch += Path(args.script).read_text().splitlines()
    if batch:
        failed = False
        for line in batch:
            terminal.run_line(line)
        client.close()
        return 1 if failed else 0
    if sys.stdout.isatty():
        sys.stdout.write(CLEAR)
    print("\n")
    print(terminal.header())
    print("\n")
    interactive(terminal)
    client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
