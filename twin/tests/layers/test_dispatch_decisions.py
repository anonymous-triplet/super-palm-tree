"""The City Brain's part in dispatch: same choice as the twin's own dispatcher, the hand-off, and every fallback."""
from __future__ import annotations

import math
import random
import time
import unittest

import helpers  # noqa: F401  (paths)

import incident_engine
import incident_types
from brain_standin import Brain

WORLD = 380.0


class FakeVehicle:
    def __init__(self, positions: dict) -> None:
        self.positions = positions

    def getPosition(self, vehicle_id: str):  # noqa: N802 - TraCI's name
        return self.positions[vehicle_id]


class FakeTraci:
    class exceptions:
        TraCIException = KeyError

    def __init__(self, positions: dict) -> None:
        self.vehicle = FakeVehicle(positions)


class FakeFleet:
    """Units plus the real EmergencyFleet.select_unit."""

    def __init__(self, units: list, positions: dict) -> None:
        self.units = {unit.id: unit for unit in units}
        self.traci = FakeTraci(positions)

    def select_unit(self, kind, target, exclude=None):
        return incident_engine.EmergencyFleet.select_unit(self, kind, target, exclude)

    def call_mutual_aid(self, kind, target, now):
        return None

    def godot_silent(self, now):
        return False


class FakeLog:
    def __init__(self) -> None:
        self.entries = []

    def push(self, now, payload):
        self.entries.append(payload)


class FakeRoad:
    def __init__(self) -> None:
        self.released = []

    def release(self, incident_id):
        self.released.append(incident_id)

    def release_junction(self, junction):
        self.released.append(junction)


class FakeEngine:
    def __init__(self, fleet: FakeFleet, external: bool) -> None:
        self.road = FakeRoad()
        self.fleet = fleet
        self.traci = fleet.traci
        self.now = 100.0
        self.events = FakeLog()
        self.external = external

    def seed_for(self, incident_id: str) -> int:
        return 7

    def external_decisions(self) -> bool:
        return self.external


def random_fleet(rng: random.Random) -> tuple[list, dict]:
    units, positions = [], {}
    for index in range(rng.randint(3, 14)):
        kind = rng.choice(["police", "ambulance", "fire", "tow"])
        bay = {"x": rng.uniform(-370, 370), "z": rng.uniform(-370, 370), "unit": f"U{index}"}
        start = rng.choice(["garaged", "garaged", "patrol"])
        unit = incident_engine.Unit(f"{kind[:3].upper()}-{index}", kind, {"id": f"D{index}", "label": f"Depot {index}"}, bay, start)
        if start == "patrol":
            unit.vehicle_id = f"veh{index}"
            positions[unit.vehicle_id] = (rng.uniform(0, 760), rng.uniform(0, 760))
        if rng.random() < 0.2:
            unit.incident_id = "INC-OTHER"
        if rng.random() < 0.1:
            unit.reserved_by = "INC-OTHER"
        units.append(unit)
    return units, positions


def brain_rows(units: list, positions: dict) -> list[dict]:
    rows = []
    for unit in units:
        row = unit.public()
        if unit.vehicle_id:
            x, y = positions[unit.vehicle_id]
            row["location"] = {"x": x - WORLD, "y": 0.0, "z": y - WORLD}
        rows.append(row)
    return rows


class BrainRuleTest(unittest.TestCase):
    def test_brain_picks_what_the_twin_would(self) -> None:
        rng = random.Random(20261108)
        compared = 0
        for _ in range(600):
            units, positions = random_fleet(rng)
            fleet = FakeFleet(units, positions)
            target = (rng.uniform(0, 760), rng.uniform(0, 760))
            kind = rng.choice(["police", "ambulance", "fire", "tow"])
            twin_choice = fleet.select_unit(kind, target, set())
            request = {"id": "INC-1-R1", "ask": 1, "kind": kind, "role": "x", "aid_allowed": False,
                       "location": {"x": target[0] - WORLD, "z": target[1] - WORLD}}
            decision = Brain.choose({"id": "INC-1", "units": []}, [request], brain_rows(units, positions), {"assigned": set()})[0]
            if twin_choice is None:
                self.assertEqual(decision["action"], "hold")
            else:
                self.assertEqual(decision["action"], "unit")
                self.assertEqual(decision["unit"], twin_choice.id)
            compared += 1
        self.assertEqual(compared, 600)

    def test_two_calls_of_one_kind_get_two_units(self) -> None:
        units = [incident_engine.Unit(f"POL-{i}", "police", {"id": "D"}, {"x": 10.0 * i, "z": 0.0, "unit": f"P{i}"}, "garaged") for i in range(1, 4)]
        requests = [{"id": f"INC-1-R{i}", "ask": 1, "kind": "police", "role": "x", "location": {"x": 0.0, "z": 0.0}} for i in (1, 2)]
        decisions = Brain.choose({"id": "INC-1", "units": []}, requests, brain_rows(units, {}), {"assigned": set()})
        self.assertEqual([decision["unit"] for decision in decisions], ["POL-1", "POL-2"])

    def test_mutual_aid_only_when_allowed(self) -> None:
        request = {"id": "INC-1-R1", "ask": 1, "kind": "fire", "role": "x", "location": {"x": 0.0, "z": 0.0}}
        self.assertEqual(Brain.choose({"id": "INC-1"}, [dict(request, aid_allowed=False)], [], {"assigned": set()})[0]["action"], "hold")
        self.assertEqual(Brain.choose({"id": "INC-1"}, [dict(request, aid_allowed=True)], [], {"assigned": set()})[0]["action"], "mutual_aid")


class HandOffTest(unittest.TestCase):
    def make(self, external: bool):
        units = [incident_engine.Unit("POL-1", "police", {"id": "HQ", "label": "Police HQ"}, {"x": 0.0, "z": 0.0, "unit": "P1"}, "garaged"),
                 incident_engine.Unit("POL-2", "police", {"id": "HQ", "label": "Police HQ"}, {"x": 300.0, "z": 0.0, "unit": "P2"}, "garaged")]
        engine = FakeEngine(FakeFleet(units, {}), external)
        incident = incident_types.Incident(engine, "INC-0001", {})
        incident.location = {"sx": WORLD, "sy": WORLD, "x": 0.0, "z": 0.0}
        incident.request_unit("police", "traffic_control", {"edge": "E", "pos": 30.0})
        return engine, incident

    def test_twin_alone_queues_the_call_at_once(self) -> None:
        _engine, incident = self.make(external=False)
        incident._service_unit_requests()
        self.assertEqual(len(incident.calls), 1)
        self.assertEqual(incident.calls[0]["unit"], "POL-1")

    def test_brain_answer_is_used(self) -> None:
        _engine, incident = self.make(external=True)
        incident._service_unit_requests()
        self.assertEqual(incident.calls, [])
        pending = incident.dispatch_requests_public()
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["id"], "INC-0001-R1")
        result = incident.receive_decisions([{"request": "INC-0001-R1", "ask": 1, "action": "unit", "unit": "POL-2"}])
        self.assertIn("POL-2", result)
        incident._service_unit_requests()
        self.assertEqual(incident.calls[0]["unit"], "POL-2")
        self.assertEqual(incident.calls[0]["facility"], "Police HQ")
        self.assertEqual(incident.dispatch_requests_public(), [])

    def test_stale_or_duplicate_answers_are_refused(self) -> None:
        _engine, incident = self.make(external=True)
        incident._service_unit_requests()
        self.assertIn("not waiting", incident.receive_decisions([{"request": "INC-0001-R1", "ask": 7, "action": "unit", "unit": "POL-1"}]))
        self.assertIn("unknown", incident.receive_decisions([{"request": "INC-0001-R9", "ask": 1, "action": "unit", "unit": "POL-1"}]))
        incident.receive_decisions([{"request": "INC-0001-R1", "ask": 1, "action": "unit", "unit": "POL-1"}])
        incident._service_unit_requests()
        self.assertIn("already answered", incident.receive_decisions([{"request": "INC-0001-R1", "ask": 1, "action": "unit", "unit": "POL-2"}]))

    def test_unit_taken_meanwhile_means_asking_again(self) -> None:
        engine, incident = self.make(external=True)
        incident._service_unit_requests()
        incident.receive_decisions([{"request": "INC-0001-R1", "ask": 1, "action": "unit", "unit": "POL-2"}])
        engine.fleet.units["POL-2"].incident_id = "INC-0002"
        incident._service_unit_requests()
        self.assertEqual(incident.calls, [])
        incident._service_unit_requests()
        self.assertEqual(incident.dispatch_requests_public()[0]["ask"], 2)

    def test_hold_waits_until_the_fleet_changes(self) -> None:
        engine, incident = self.make(external=True)
        incident._service_unit_requests()
        incident.receive_decisions([{"request": "INC-0001-R1", "ask": 1, "action": "hold"}])
        for _ in range(3):
            incident._service_unit_requests()
        self.assertEqual(incident.dispatch_requests_public(), [])
        engine.fleet.units["POL-1"].incident_id = "INC-0002"          # the nearest unit leaves: the twin's view changes
        incident._service_unit_requests()
        self.assertEqual(incident.dispatch_requests_public()[0]["ask"], 2)

    def test_silent_brain_lets_the_twin_answer(self) -> None:
        _engine, incident = self.make(external=True)
        incident._service_unit_requests()
        incident.unit_requests[0]["asked_at"] = time.monotonic() - incident_types.BRAIN_ANSWER_SECONDS - 1.0
        incident._service_unit_requests()
        self.assertEqual(incident.calls[0]["unit"], "POL-1")
        self.assertTrue(any("No answer from the City Brain" in note["text"] for note in incident.timeline))

    def test_lost_link_returns_to_the_twins_dispatcher(self) -> None:
        engine, incident = self.make(external=True)
        incident._service_unit_requests()
        engine.external = False
        incident._service_unit_requests()
        self.assertEqual(incident.calls[0]["unit"], "POL-1")

    def test_decline_is_recorded_and_never_dispatched(self) -> None:
        _engine, incident = self.make(external=True)
        incident._service_unit_requests()
        incident.receive_decisions([{"request": "INC-0001-R1", "ask": 1, "action": "decline", "reason": "fake report"}])
        for _ in range(3):
            incident._service_unit_requests()
        self.assertEqual(incident.calls, [])
        self.assertTrue(any("declined" in note["text"] for note in incident.timeline))

    def test_caller_ready_counts_even_before_the_call(self) -> None:
        _engine, incident = self.make(external=True)
        incident.participants["civ_1"] = {"status": "wreck"}
        self.assertEqual(incident.acknowledge("caller_ready", {"caller": "civ_1"}), "ok")
        incident._service_unit_requests()
        incident.receive_decisions([{"request": "INC-0001-R1", "ask": 1, "action": "unit", "unit": "POL-1"}])
        incident._service_unit_requests()
        self.assertTrue(incident._caller_ready("civ_1"))


class ForceCloseTest(unittest.TestCase):
    def test_an_unreachable_scene_is_closed_by_the_supervisor(self) -> None:
        engine, incident = HandOffTest().make(external=False)
        incident._service_unit_requests()
        incident.request_resolve()
        incident.force_close("Clearance could not be completed")
        self.assertTrue(incident.finished())
        self.assertIn("INC-0001", engine.road.released)
        self.assertEqual(incident.calls[0]["state"], "cancelled")
        self.assertTrue(any("could not be completed" in note["text"] for note in incident.timeline))


class AcknowledgementTest(unittest.TestCase):
    def test_crash_and_breakdown_accept_messages_without_a_vehicle(self) -> None:
        # Godot's caller_ready and scene_cleanup_complete name no vehicle; they used to be answered "unknown vehicle".
        for cls in (incident_types.CrashIncident, incident_types.BreakdownIncident):
            incident = cls.__new__(cls)
            incident.participants = {}
            incident.scene = {}
            incident.callers = {"civ_9": {"ready": False}}
            incident.ready_callers = set()
            self.assertEqual(incident.acknowledge("caller_ready", {"caller": "civ_9"}), "ok")
            self.assertTrue(incident.callers["civ_9"]["ready"])
            self.assertEqual(incident.acknowledge("scene_cleanup_complete", {}), "ok")
            self.assertTrue(incident.scene["cleanup_complete"])
            self.assertEqual(incident.acknowledge("wreck_loaded", {"vehicle": "nope"}), "unknown vehicle")


class DecisionLeaseTest(unittest.TestCase):
    def test_lease_runs_out(self) -> None:
        engine = incident_engine.IncidentEngine.__new__(incident_engine.IncidentEngine)
        engine.decision_mode, engine.decision_lease, engine.decisions_were_external = "auto", 0.0, False
        engine.events, engine.now = FakeLog(), 0.0
        self.assertEqual(engine._apply("decision_mode", {"mode": "external", "lease_s": 1.0}), "decisions external")
        self.assertTrue(engine.external_decisions())
        engine.decision_lease = time.monotonic() - 0.01
        self.assertFalse(engine.external_decisions())
        engine._watch_decision_lease()
        self.assertEqual(engine.events.entries[-1], {"kind": "decision_mode", "mode": "auto"})


if __name__ == "__main__":
    unittest.main()
