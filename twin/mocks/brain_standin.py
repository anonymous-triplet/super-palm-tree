#!/usr/bin/env python3
"""Stand-in for the City Brain layer.

Runs as its own process with its own key pair (standins.conf [brain]) and talks to the twin and the Guardian over MCP inside
mutual TLS, exactly as the real City Brain would:

* its tools (called by the twin): report_incident (an incident and the emergency calls that need a responding unit) and
  close_incident;
* for each report it asks the Guardian to verify it (the Guardian's verify_report), reads the emergency fleet from the twin
  (list_emergency_units) and answers every call with a unit through the twin's actuator tool dispatch_units;
* its rule is the dispatcher's classic one: the closest free unit of the kind asked for (a patrol car already on the road
  counts at 0.8 of its distance; a unit in its station adds 60 m to leave it), mutual aid from outside the city once the
  twin allows it, otherwise wait. A report the Guardian does not trust is declined, with the reason;
* it briefs the twin's timeline on what it asked the Guardian and why it chose each unit.
"""
from __future__ import annotations

import math
import sys
import threading

from standin_common import Layer, McpError, ToolSpec, log

NAME = "BRAIN"


class Brain:
    def __init__(self) -> None:
        self.layer = Layer("brain", NAME, "City Brain stand-in. The twin reports incidents with report_incident and closes them with close_incident.")
        self.guardian = self.layer.partner("guardian")
        self.guardian_identity = self.layer.data.get("guardian_identity", "guardian").strip()
        self.cases: dict[str, dict] = {}
        self.lock = threading.Lock()
        self.layer.tool(ToolSpec("report_incident", "The twin reports an incident and the emergency calls waiting for a unit. Answered at once; the decision follows "
                                 "through the twin's dispatch_units tool.",
                                 {"type": "object", "properties": {"incident": {"type": "object"}, "requests": {"type": "array"}}, "required": ["incident", "requests"]},
                                 self.report_incident))
        self.layer.tool(ToolSpec("close_incident", "The twin reports that an incident is over.",
                                 {"type": "object", "properties": {"incident": {"type": "string"}, "outcome": {"type": "string"}}, "required": ["incident"]},
                                 self.close_incident))

    # ---- tools

    def report_incident(self, args: dict, meta: dict) -> dict:
        facts = args["incident"] if isinstance(args["incident"], dict) else {}
        requests = [request for request in args["requests"] if isinstance(request, dict) and request.get("id")]
        incident = str(facts.get("id", ""))
        if not incident:
            return {"error": {"code": "bad_value", "message": "incident.id is required"}}
        with self.lock:
            case = self.cases.setdefault(incident, {"verdict": None, "assigned": set(), "lock": threading.Lock(), "decisions": 0})
        if not requests:
            return {"accepted": True, "case": f"CASE-{incident}", "note": "noted; nothing to decide (no emergency call)"}
        threading.Thread(target=self.decide, args=(facts, requests, case), daemon=True).start()
        fresh = case["verdict"] is None
        return {"accepted": True, "case": f"CASE-{incident}", "note": f"{len(requests)} call(s) taken" + ("; verifying the report with the Guardian" if fresh else "")}

    def close_incident(self, args: dict, meta: dict) -> dict:
        incident = str(args["incident"])
        with self.lock:
            case = self.cases.pop(incident, None)
        return {"closed": True, "note": f"{case['decisions'] if case else 0} dispatch decision(s) on record"}

    # ---- deciding

    def decide(self, facts: dict, requests: list[dict], case: dict) -> None:
        incident = str(facts["id"])
        with case["lock"]:
            try:
                if case["verdict"] is None:
                    case["verdict"] = self.verify(facts)
                verdict = case["verdict"]
                if verdict.get("verdict") == "untrusted":
                    reason = f"the Guardian does not trust this report ({verdict.get('reason', 'no evidence')})"
                    self.layer.brief("twin", f"Not dispatching for {incident}: {reason}", incident, verdict)
                    self.layer.call_twin("dispatch_units", {"incident": incident, "decisions": [
                        {"request": request["id"], "ask": request.get("ask", 1), "action": "decline", "reason": reason} for request in requests]}, incident)
                    return
                fleet = self.layer.call_twin("list_emergency_units", {}, incident).get("units", [])
                decisions = self.choose(facts, requests, fleet, case)
                self.layer.call_twin("dispatch_units", {"incident": incident, "decisions": decisions}, incident)
                case["decisions"] += len(decisions)
            except McpError as error:
                log(NAME, f"{incident}: {error.message}")

    def verify(self, facts: dict) -> dict:
        incident = str(facts["id"])
        self.layer.brief("guardian", f"Asked the Guardian whether the {incident} report can be trusted", incident, {"tool": "verify_report", "incident": facts})
        try:
            verdict = self.guardian.call_tool("verify_report", {"incident": facts}, {"correlationId": incident})
            if self.guardian.peer_identity != self.guardian_identity:
                raise McpError("identity", f"the Guardian's certificate says '{self.guardian.peer_identity}'")
            return verdict
        except McpError as error:
            # An emergency is not left unanswered because the Guardian is down: act on it, and say so.
            self.layer.brief("twin", f"Guardian unreachable ({error.message[:80]}); acting on the {incident} report unverified", incident)
            return {"verdict": "unverified", "reason": error.message}

    @staticmethod
    def choose(facts: dict, requests: list[dict], fleet: list[dict], case: dict) -> list[dict]:
        incident = str(facts["id"])
        busy = {unit.get("unit") for unit in facts.get("units", [])} | {row.get("unit") for row in fleet if row.get("incident") == incident} | case["assigned"]
        decisions = []
        for request in requests:
            target = request.get("location") or facts.get("point") or {"x": 0.0, "z": 0.0}
            best, best_distance, how = None, math.inf, ""
            for row in fleet:
                if row.get("kind") != request.get("kind") or not row.get("available") or row.get("unit") in busy:
                    continue
                if row.get("status") == "patrol" and row.get("vehicle"):
                    where = row.get("location")
                    if not where:
                        continue
                    distance = math.hypot(float(where["x"]) - float(target["x"]), float(where["z"]) - float(target["z"])) * 0.8
                    kind_of_start = f"patrol car {distance / 0.8:.0f} m away"
                else:
                    base = row.get("base") or {"x": 0.0, "z": 0.0}
                    distance = math.hypot(float(base["x"]) - float(target["x"]), float(base["z"]) - float(target["z"])) + 60.0
                    kind_of_start = f"in station {distance - 60.0:.0f} m away"
                if distance < best_distance:
                    best, best_distance, how = row, distance, kind_of_start
            if best is not None:
                busy.add(best["unit"])
                case["assigned"].add(best["unit"])
                decisions.append({"request": request["id"], "ask": request.get("ask", 1), "action": "unit", "unit": best["unit"],
                                  "reason": f"closest free {request.get('kind')} unit ({how})"})
            elif request.get("aid_allowed"):
                decisions.append({"request": request["id"], "ask": request.get("ask", 1), "action": "mutual_aid",
                                  "reason": f"no free {request.get('kind')} unit in the city; mutual aid is due"})
            else:
                decisions.append({"request": request["id"], "ask": request.get("ask", 1), "action": "hold",
                                  "reason": f"no free {request.get('kind')} unit right now"})
        return decisions


def main() -> int:
    return Brain().layer.serve()


if __name__ == "__main__":
    sys.exit(main())
