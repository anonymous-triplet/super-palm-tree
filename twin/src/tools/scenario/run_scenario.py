#!/usr/bin/env python3
"""Run one Test Book scenario on the live city (started by scenarios/<id>.sh through run_control_room.sh --scenario <id>).

1. connects to the twin's MCP endpoint as the operator (mutual TLS, twin.conf [client:operator]);
2. waits until every system is up and steady - traffic, citizens, the incident system, no loading hitch, the viewport camera
   still, both partner layers connected - and has stayed so for one second;
3. triggers the scenario's incident (named after the scenario, so its run log is logs/<time>_<id>_..._INC-nnnn_<kind>.log)
   and has the viewport watch it from the first moment to the last;
4. prints the run as it happens (the same lines as the run log) and ends ten seconds after the last activity of a
   finished incident. The launcher then closes the city.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "mcp"))

import layer_config  # noqa: E402
from mcp_https import McpError, McpHttpsClient, client_context  # noqa: E402

READY_HOLD_S = 1.0
INACTIVE_END_S = 10.0
CONNECT_WAIT_S = 240.0
READY_WAIT_S = 600.0
PARTNER_WAIT_S = 60.0
RUN_LIMIT_S = 1500.0

# The Test Book: one entry per scenario script in scenarios/. Every run exercises the whole chain: the twin detects the
# incident and reports the emergency calls to the City Brain, the Brain has the Guardian verify the report, the Guardian
# checks it against the twin's live data, the Brain answers each call with a unit through dispatch_units, the twin carries
# out the response and reports the end.
SCENARIOS = {
    "T01": {"kind": "rear_end", "title": "Rear-end collision",
            "twin": "Two cars collide in a lane; drivers get out and phone police (and ambulance and tow when needed); lane closed.",
            "guardian": "Finds both vehicles stopped at the reported place: verdict trusted.",
            "brain": "Answers every call with the closest free unit of the kind asked for."},
    "T02": {"kind": "red_light_tbone", "title": "Red-light T-bone crash",
            "twin": "A car runs a red light and hits a crossing car inside a junction; police take over the junction.",
            "guardian": "Both vehicles found stopped in the junction: verdict trusted.",
            "brain": "Two police units (junction control and investigation) plus medical and recovery as the severity needs."},
    "T03": {"kind": "unsafe_overtake", "title": "Head-on crash after an unsafe overtake",
            "twin": "An overtaking car meets oncoming traffic head-on; severe crash, both directions blocked.",
            "guardian": "Vehicles found at the scene: verdict trusted.",
            "brain": "Police, ambulance, fire and tow units, closest first."},
    "T04": {"kind": "breakdown", "title": "Vehicle breakdown",
            "twin": "A car breaks down in its lane; the driver calls for help.",
            "guardian": "The car is found stopped where reported: verdict trusted.",
            "brain": "Sends the closest free police unit and tow truck."},
    "T05": {"kind": "vehicle_fire", "title": "Vehicle fire",
            "twin": "A car catches fire on the road; the driver gets out and calls the fire service.",
            "guardian": "The burning car is found stopped at the scene: verdict trusted.",
            "brain": "Sends the closest fire unit and the support the call asks for."},
    "T06": {"kind": "lost_load", "title": "Lost load on the road",
            "twin": "A vehicle sheds its load in the lane; the lane is closed until it is cleared.",
            "guardian": "The vehicle is found at the reported place: verdict trusted.",
            "brain": "Sends the closest free units for traffic control and clearance."},
    "T07": {"kind": "building_fire", "title": "Building fire",
            "twin": "A building catches fire; a passer-by calls the fire service; the street in front is closed.",
            "guardian": "The reported block is inside the city and answers: verdict trusted.",
            "brain": "Sends fire units (and support) closest first."},
    "T08": {"kind": "water_main_break", "title": "Water main break",
            "twin": "A water main bursts under a street; the lane floods and is closed.",
            "guardian": "The reported block is inside the city and answers: verdict trusted.",
            "brain": "Sends the utility crew and traffic control."},
    "T09": {"kind": "signal_failure", "title": "Traffic signal failure",
            "twin": "A junction's signals fail; police direct traffic by hand until it is repaired.",
            "guardian": "The reported junction is inside the city and answers: verdict trusted.",
            "brain": "Sends police for traffic control and the utility crew for the repair."},
    "T10": {"kind": "garbage_collection", "title": "Garbage collection round",
            "twin": "A scheduled round: the garbage truck empties the fullest bins, stop after stop (no emergency call).",
            "guardian": "Not consulted: a scheduled round is not a report to verify.",
            "brain": "Informed of the round and of its end; no dispatch decision is needed."},
}


def say(text: str) -> None:
    print(f"[scenario] {text}", flush=True)


def connect(config: Path) -> McpHttpsClient:
    parser = layer_config.read(config)
    twin = layer_config.endpoint(parser, "twin", config.parent)
    operator = next((client for client in layer_config.clients(parser, config.parent) if client.name == "operator"), None)
    if operator is None:
        raise SystemExit("twin.conf has no [client:operator] section: the scenario runner cannot authenticate")
    context = client_context(str(operator.certificate), str(operator.private_key), [str(path) for path in twin.trusted_ca], twin.tls_min_version)
    client = McpHttpsClient(twin.url, context, "scenario runner", timeout=15.0)
    deadline = time.monotonic() + CONNECT_WAIT_S
    while True:
        try:
            client.connect()
            say(f"connected to the twin at {twin.url} ({client.tls_version}, certificate '{client.peer_identity}')")
            return client
        except McpError as error:
            if time.monotonic() > deadline:
                raise SystemExit(f"the twin's MCP endpoint did not answer: {error.message}")
            time.sleep(1.0)


def wait_until_steady(client: McpHttpsClient) -> None:
    say("waiting until every system is up and steady ...")
    deadline = time.monotonic() + READY_WAIT_S
    partners_since = time.monotonic()
    shown = ""
    while time.monotonic() < deadline:
        try:
            status = client.call_tool("city_status", {"once": True})
            timeline = client.call_tool("read_timeline", {"limit": 1, "once": True})
        except McpError as error:
            say(f"  (city not answering yet: {error.message[:80]})")
            time.sleep(1.0)
            continue
        readiness = status.get("readiness") or {}
        partners = (timeline.get("status") or {}).get("partners") or {}
        links_ok = bool(partners) and all(link.get("healthy") for link in partners.values())
        if not links_ok and time.monotonic() - partners_since > PARTNER_WAIT_S:
            links_ok = True          # a missing partner does not block the run; the twin answers the calls itself
            if shown != "partners":
                say("  a partner layer is still unreachable: the run goes ahead and the twin dispatches by itself")
                shown = "partners"
        waiting = [name for name, ok in (readiness.get("checks") or {}).items() if not ok] + ([] if links_ok else ["partner links"])
        text = ", ".join(waiting)
        if waiting and text != shown:
            say(f"  waiting for: {text}")
            shown = text
        if not waiting and float(readiness.get("stable_s", 0.0)) >= READY_HOLD_S:
            say(f"all systems running and steady for {float(readiness['stable_s']):.1f} s")
            return
        time.sleep(0.1)
    raise SystemExit("the city did not become steady in time")


def run(client: McpHttpsClient, scenario_id: str, spec: dict) -> int:
    label = f"{scenario_id} {spec['title']}"
    meta = {"label": label}
    client.call_tool("post_briefing", {"to": "twin", "summary": f"Scenario {label}: every system steady for {READY_HOLD_S:.0f} s, starting now", "label": label}, meta)
    client.call_tool("trigger_incident", {"kind": spec["kind"], "label": label}, meta)
    say(f"triggered {spec['kind']} as '{label}'")
    incident_id = ""
    deadline = time.monotonic() + 90.0
    while not incident_id and time.monotonic() < deadline:
        for incident in client.call_tool("list_incidents", {}).get("incidents", []):
            if incident.get("label") == label:
                incident_id = incident["id"]
        time.sleep(0.2)
    if not incident_id:
        say("the incident did not start")
        return 1
    client.call_tool("control_incident", {"id": incident_id, "action": "watch"}, {"correlationId": incident_id})
    say(f"{incident_id} started; the viewport is watching it")
    since = 0
    last_activity = time.monotonic()
    closed_at: float | None = None
    started = time.monotonic()
    run_log = ""
    while time.monotonic() - started < RUN_LIMIT_S:
        timeline = client.call_tool("read_timeline", {"incident": incident_id, "since_seq": since, "limit": 600, "once": True})
        for entry in timeline.get("entries", []):
            since = max(since, int(entry.get("seq", 0)))
            run_log = entry.get("run") or run_log
            route = entry.get("from", "").upper() + (" → " + entry.get("to", "").upper() if entry.get("to") else "")
            print(f"  {entry.get('time')}  {route:<19} {entry.get('text')}", flush=True)
            last_activity = time.monotonic()
        since = max(since, int(timeline.get("last_seq", since)))
        incidents = client.call_tool("list_incidents", {})
        still_open = any(item.get("id") == incident_id for item in incidents.get("incidents", []))
        if not still_open and closed_at is None:
            closed_at = time.monotonic()           # the quiet ten seconds are counted from the end of the incident at the earliest
        if closed_at is not None and time.monotonic() - max(last_activity, closed_at) >= INACTIVE_END_S:
            say(f"{incident_id} is over and nothing has happened for {INACTIVE_END_S:.0f} s")
            if run_log:
                say(f"run log: logs/{run_log}")
            return 0
        time.sleep(0.25)
    say("the run took longer than its time limit")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenario", help="Test Book id (T01 ...)")
    parser.add_argument("--config", type=Path, default=HERE.parents[2] / "twin.conf")
    parser.add_argument("--list", action="store_true", help="print the Test Book and exit")
    args = parser.parse_args()
    if args.list or not args.scenario:
        for key, spec in SCENARIOS.items():
            print(f"{key}  {spec['title']:<40} ({spec['kind']})")
        return 0
    scenario_id = args.scenario.upper()
    spec = SCENARIOS.get(scenario_id)
    if spec is None:
        say(f"unknown scenario {args.scenario}; known: {', '.join(SCENARIOS)}")
        return 2
    say(f"{scenario_id} · {spec['title']}")
    for layer in ("twin", "guardian", "brain"):
        say(f"  expected ({layer}): {spec[layer]}")
    client = connect(args.config.resolve())
    try:
        wait_until_steady(client)
        return run(client, scenario_id, spec)
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
