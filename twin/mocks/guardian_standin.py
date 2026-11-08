#!/usr/bin/env python3
"""Stand-in for the Guardian layer.

Runs as its own process with its own key pair (standins.conf [guardian]) and answers over MCP inside mutual TLS:

* its tool (called by the City Brain): verify_report - is this incident report telling the truth?
* to answer, it does not take the report's word: it reads the twin's live data itself (read_vehicle for every vehicle the
  report names, read_sector for the place) and checks that the vehicles exist, are at the reported place and have stopped;
* the verdict (trusted, or untrusted with the reason) goes back to the Brain, and the Guardian briefs the twin's timeline.
"""
from __future__ import annotations

import math
import sys

from standin_common import Layer, McpError, ToolSpec

NAME = "GUARDIAN"
SCENE_RADIUS_M = 80.0
STOPPED_MPS = 2.0


class Guardian:
    def __init__(self) -> None:
        self.layer = Layer("guardian", NAME, "Guardian stand-in. verify_report checks an incident report against the twin's live data.")
        self.layer.tool(ToolSpec("verify_report", "Check an incident report against independent live data and return a trust verdict with the evidence.",
                                 {"type": "object", "properties": {"incident": {"type": "object"}}, "required": ["incident"]}, self.verify_report, read_only=True))

    def verify_report(self, args: dict, meta: dict) -> dict:
        facts = args["incident"] if isinstance(args["incident"], dict) else {}
        incident = str(facts.get("id", ""))
        point = facts.get("point")
        evidence: list[str] = []
        doubts: list[str] = []
        participants = [vehicle for vehicle in facts.get("participants", []) if vehicle][:4]
        found = 0
        for vehicle in participants:
            try:
                data = self.layer.call_twin("read_vehicle", {"id": vehicle}, incident)
            except McpError as error:
                doubts.append(f"{vehicle}: {error.message[:60]}")
                continue
            found += 1
            where = data.get("location") or {}
            speed = float(data.get("speed_mps", 0.0))
            if point and where:
                distance = math.hypot(float(where.get("x", 0.0)) - float(point["x"]), float(where.get("z", 0.0)) - float(point["z"]))
                if distance <= SCENE_RADIUS_M:
                    evidence.append(f"{vehicle} is at the scene ({distance:.0f} m, {speed:.1f} m/s)" + (", stopped" if speed <= STOPPED_MPS else ""))
                else:
                    doubts.append(f"{vehicle} is {distance:.0f} m from the reported place")
            else:
                evidence.append(f"{vehicle} exists ({speed:.1f} m/s)")
        block = str(facts.get("block", ""))
        if block:
            try:
                sector = self.layer.call_twin("read_sector", {"sector": block[0]}, incident)
                devices = sum(int(count) for count in (sector.get("devices_by_family") or {}).values()) if isinstance(sector.get("devices_by_family"), dict) else 0
                evidence.append(f"block {block} is inside the city (sector {block[0]} answers" + (f", {devices} devices online)" if devices else ")"))
            except McpError as error:
                doubts.append(f"sector {block[0]}: {error.message[:60]}")
        if participants and found == 0:
            verdict = {"verdict": "untrusted", "confidence": 0.9, "reason": "none of the vehicles in the report exists", "evidence": evidence, "doubts": doubts}
        elif not evidence:
            verdict = {"verdict": "untrusted", "confidence": 0.6, "reason": "nothing in the live data supports the report", "evidence": evidence, "doubts": doubts}
        else:
            confidence = 0.99 if participants and found == len(participants) and not doubts else 0.9
            verdict = {"verdict": "trusted", "confidence": confidence, "reason": "; ".join(evidence[:3]), "evidence": evidence, "doubts": doubts}
        self.layer.brief("brain", f"Verdict on {incident}: {verdict['verdict']} ({verdict['reason'][:150]})", incident, verdict)
        return verdict


def main() -> int:
    return Guardian().layer.serve()


if __name__ == "__main__":
    sys.exit(main())
