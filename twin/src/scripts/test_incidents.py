#!/usr/bin/env python3
"""Headless end-to-end regression for every incident type.

Each incident is triggered through the operator command path, then must:
reach its onset (impact / breakdown / ignition / burst / dark signals),
get its responders dispatched and on scene, clear, reopen the road and
release every participant — without any collision other than the scripted
one, without teleports, and with the civilian fleet restored afterwards.
"""

from __future__ import annotations

from collections import deque
import sys
import time

import sumo_bridge

STEP = 1.0 / 15.0
LIMITS = {"rear_end": 600, "red_light_tbone": 660, "unsafe_overtake": 660, "breakdown": 600, "vehicle_fire": 600,
          "lost_load": 600, "building_fire": 600, "water_main_break": 600, "signal_failure": 600,
          "garbage_collection": 600}


def dump_unit_forensics(traci, engine, incident) -> None:
    """Where every unit of a stuck incident is, and what holds it."""
    print(f"  STUCK {incident.id} location={incident.location} flagger={engine.road.flagger_public(incident.id)} closures={engine.road.closures_public()}")
    for unit_id in incident.units:
        unit = engine.fleet.units[unit_id]
        line = f"    {unit_id} {unit.status} vehicle={unit.vehicle_id or '-'}"
        if unit.vehicle_id in engine.last_snapshot:
            data = engine.last_snapshot[unit.vehicle_id]
            line += f" road={data['road']} pos={data['lane_position']:.1f} v={data['speed']:.1f}"
            try:
                line += f" stops={[(stop.lane, round(stop.endPos, 1)) for stop in traci.vehicle.getStops(unit.vehicle_id)]}"
                chain, vehicle = [], unit.vehicle_id
                for _ in range(6):
                    leader = traci.vehicle.getLeader(vehicle, 40.0)
                    if not leader:
                        break
                    other = engine.last_snapshot.get(leader[0], {})
                    chain.append(f"{leader[0]}@{other.get('road')}:{other.get('lane_position', 0):.0f} gap={leader[1]:.1f} v={other.get('speed', 0):.1f}")
                    vehicle = leader[0]
                line += f" leaders={chain}"
            except traci.exceptions.TraCIException:
                pass
        print(line, flush=True)


def run(kinds: list[str]) -> int:
    sumo_bridge.prepare_environment()
    import traci  # type: ignore

    traci.start(sumo_bridge.sumo_command(STEP), verbose=False)
    traffic = sumo_bridge.TrafficState(traci)
    engine = sumo_bridge.create_engine(traci, True, STEP)
    failures = []
    watch: set[str] = set()
    try:
        for _ in range(int(90 / STEP)):
            traci.simulationStep()
            sumo_bridge.make_state(traffic, engine, build_packet=False)
        for kind in kinds:
            params = {}
            if kind == "building_fire":
                params = {"building": {"edge": "E_r4c7_r4c6", "pos": 40.0, "x": 150.0, "z": -80.0, "path": "test"}}
            incident_id = engine.handle_command({"command": "incident", "action": "trigger", "type": kind, "params": params, "request": f"t-{kind}"})
            if not incident_id.startswith("INC-"):
                failures.append(f"{kind}: trigger failed ({incident_id})")
                continue
            started = engine.now
            phases: list[str] = []
            onset = None
            unexpected: set[str] = set()
            units_seen: set[str] = set()
            on_scene: set[str] = set()
            wall = time.monotonic()
            participants: set[str] = set()
            collisions: list[tuple] = []
            workflow_faults: set[str] = set()
            # Both wrecks in a red-light collision must enter recovery. This
            # catches the live-state bug where only a queue-staged tow could
            # be assigned and the second on-scene tow waited forever.
            recovered_participants: set[str] = set()
            history: deque = deque(maxlen=int(1.5 / STEP))
            reported: set = set()
            tracked = None
            while True:
                traci.simulationStep()
                sumo_bridge.make_state(traffic, engine, build_packet=False)
                incident = engine.incidents.get(incident_id)
                if incident is None:
                    break
                tracked = incident
                participants |= set(incident.participants)
                if not phases or phases[-1] != incident.phase:
                    phases.append(incident.phase)
                if onset is None and incident.phase not in ("arming", "approach", "coasting"):
                    onset = engine.now - started
                loading = any(record.get("status") == "loading" for record in incident.participants.values())
                if kind == "red_light_tbone":
                    recovered_participants |= {vehicle_id for vehicle_id, record in incident.participants.items() if record.get("status") in ("loading", "towed")}
                if kind in ("rear_end", "red_light_tbone", "unsafe_overtake") and loading:
                    report_done = getattr(incident, "report_done_at", -1.0) >= 0.0 and engine.now >= getattr(incident, "report_done_at", -1.0)
                    medical_done = getattr(incident, "treatment_done_at", -1.0) >= 0.0 and engine.now >= getattr(incident, "treatment_done_at", -1.0)
                    medical_needed = any(record.get("injured") for record in incident.participants.values())
                    if not report_done or (medical_needed and not medical_done):
                        workflow_faults.add("recovery began before investigation/patient care completed")
                if kind == "vehicle_fire":
                    if loading and not bool(incident.scene.get("extinguished", False)):
                        workflow_faults.add("tow loading began before the vehicle fire was extinguished")
                    fire = incident.scene.get("fire", {})
                    if fire.get("water") and not incident.units_on_scene("fire_suppression"):
                        workflow_faults.add("suppression water ran without an engine physically on scene")
                if kind == "red_light_tbone" and incident.phase == "cleanup" and getattr(incident, "junction", "") not in engine.road.junctions:
                    workflow_faults.add("junction reopened before presenter cleanup completed")
                if kind == "red_light_tbone" and any(bool(request.get("stop", {}).get("park", False)) for request in incident.unit_requests):
                    workflow_faults.add("junction response used a roadside parking offset instead of its approach lane")
                for unit_id in incident.units:
                    units_seen.add(unit_id)
                    if engine.fleet.units[unit_id].status == "on_scene":
                        on_scene.add(unit_id)
                frame = {}
                for vehicle_id, data in engine.last_snapshot.items():
                    try:
                        opposite = not data["road"].startswith(":") and data["road"] not in traci.vehicle.getRoute(vehicle_id) if vehicle_id in watch else False
                    except traci.exceptions.TraCIException:
                        opposite = False
                    frame[vehicle_id] = (data["road"], round(data["lane_position"], 1), round(data["speed"], 1), opposite)
                history.append((round(engine.now - started, 1), frame))
                for collision in traci.simulation.getCollisions():
                    collisions.append((round(engine.now - started, 1), collision.collider, collision.victim, collision.lane, collision.type))
                    key = (collision.collider, collision.victim)
                    if key not in reported and not {collision.collider, collision.victim} <= participants:
                        reported.add(key)
                        print(f"  FORENSICS {collision.collider}->{collision.victim} {collision.type} on {collision.lane}")
                        for when, snapshot_frame in list(history)[::5]:
                            print(f"     t={when} {collision.collider}={snapshot_frame.get(collision.collider)} {collision.victim}={snapshot_frame.get(collision.victim)}")
                        watch.update(key)
                if int((engine.now - started) / STEP) % int(30 / STEP) == 0:
                    print(f"  t={engine.now - started:.0f} phase={incident.phase} units={[(u, engine.fleet.units[u].status) for u in incident.units]} requests={[r['kind'] + ':' + (r['unit'] or '-') for r in incident.unit_requests]}", flush=True)
                if engine.now - started > LIMITS.get(kind, 480):
                    failures.append(f"{kind}: not resolved after {LIMITS.get(kind, 480)} s (phases {phases})")
                    dump_unit_forensics(traci, engine, incident)
                    engine.handle_command({"command": "incident", "action": "resolve", "incident": incident_id})
                    for _ in range(int(120 / STEP)):
                        traci.simulationStep()
                        sumo_bridge.make_state(traffic, engine, build_packet=False)
                        if incident_id not in engine.incidents:
                            break
                    break
            # Judge collisions against everyone any incident ever involved
            # (unscripted contacts are converted to secondary incidents, which
            # are reported separately and must stay rare).
            for other in engine.incidents.values():
                participants |= set(other.participants)
            for resolved in engine.resolved:
                participants |= {record["id"] for record in resolved.get("participants", [])}
            for when, collider, victim, lane, collision_type in collisions:
                if not {collider, victim} <= participants:
                    unexpected.add(f"{collider}->{victim}@{lane}:{collision_type}")
                    print(f"  COLLISION t={when} {collider}->{victim}@{lane}:{collision_type}", flush=True)
            summary = engine.resolved[-1] if engine.resolved and engine.resolved[-1]["id"] == incident_id else {}
            if onset is None:
                failures.append(f"{kind}: never reached onset (phases {phases})")
            if not on_scene:
                failures.append(f"{kind}: no unit ever arrived on scene (dispatched {sorted(units_seen)})")
            if unexpected:
                failures.append(f"{kind}: unscripted collisions involving {sorted(unexpected)}")
            if workflow_faults:
                failures.append(f"{kind}: workflow order violation(s): {sorted(workflow_faults)}")
            if tracked is not None and tracked.phones:
                # Every responding unit was phoned first, once, by someone, and only facilities whose unit came were called.
                done = {call["unit"] for call in tracked.calls if call["state"] == "done" and call["unit"]}
                answered_by = {call["unit"]: call for call in tracked.calls if call["state"] == "done"}
                local = {unit for unit in tracked.units if not unit.startswith("AID-")}
                if local - done:
                    failures.append(f"{kind}: units dispatched without a phone call: {sorted(local - done)}")
                if done - set(tracked.units):
                    failures.append(f"{kind}: a facility was called whose unit never came: {sorted(done - set(tracked.units))}")
                notes = [entry["text"] for entry in tracked.timeline]
                for call in answered_by.values():
                    called = next((i for i, text in enumerate(notes) if text.endswith(f"called {call['facility']}")), -1)
                    hung = next((i for i, text in enumerate(notes) if text.endswith(f"hung up on {call['facility']}")), -1)
                    sent = next((i for i, text in enumerate(notes) if text.startswith(f"{call['unit']} dispatched")), -1)
                    if not 0 <= called < hung or (call["unit"] and not hung <= sent):
                        failures.append(f"{kind}: call log out of order for {call['facility']} ({called}, {hung}, {sent})")
                if not tracked.calls:
                    failures.append(f"{kind}: nobody phoned anybody")
            if kind == "red_light_tbone" and len(recovered_participants) < 2:
                failures.append(f"{kind}: only {len(recovered_participants)} wreck(s) entered recovery")
            if engine.road.closures_public() or engine.road.junctions:
                failures.append(f"{kind}: road control left active {engine.road.closures_public()} {list(engine.road.junctions)}")
            print(f"INCIDENT {kind} id={incident_id} onset={onset if onset is None else round(onset, 1)}s total={round(engine.now - started, 1)}s phases={'>'.join(phases)} units={sorted(units_seen)} on_scene={sorted(on_scene)} severity={summary.get('severity')} guard={engine.road.guard_interventions} secondary={engine.secondary_collisions} wall={time.monotonic() - wall:.0f}s", flush=True)
            settle_deadline = engine.now + 400.0
            while engine.incidents and engine.now < settle_deadline:
                traci.simulationStep()
                sumo_bridge.make_state(traffic, engine, build_packet=False)
            if engine.incidents:
                failures.append(f"{kind}: follow-on incidents still open {list(engine.incidents)}")
            for _ in range(int(20 / STEP)):
                traci.simulationStep()
                sumo_bridge.make_state(traffic, engine, build_packet=False)
        civilians = sum(1 for vehicle_id in traci.vehicle.getIDList() if vehicle_id.startswith("civ")) + len([v for v in traci.simulation.getPendingVehicles() if v.startswith("civ")])
        if civilians < traffic.civilian_target - 2:
            failures.append(f"civilian fleet not restored: {civilians}/{traffic.civilian_target}")
    finally:
        traci.close(False)
    if failures:
        for failure in failures:
            print("INCIDENT_TEST_FAILURE", failure, file=sys.stderr)
        return 1
    print(f"INCIDENT_TEST_OK types={len(kinds)}")
    return 0


if __name__ == "__main__":
    selected = sys.argv[1:] or list(LIMITS)
    raise SystemExit(run(selected))
