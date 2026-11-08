# The Digital Twin layer

The twin is the city itself. It runs on its own: the City Brain and Guardian it talks to are stand-ins in `mocks/`. They are real processes with their own keys, MCP endpoints and configuration, so the twin's side of every exchange is exactly what it would be with the real partner teams.

## Run this layer alone

From the repository root:

```bash
./run_control_room.sh            # the control room, with the stand-ins playing the Brain and the Guardian
scenarios/T01_rear_end_collision.sh   # one scenario, start to finish
./run_control_room.sh --tests    # every test of this layer
```

The first run sets up what is missing, asking before it installs anything (see the root README).

## How it is put together

```
src/                    Godot 4.7.2 project (res:// is this folder)
  scenes/, scripts/     the city, its society, utilities, incidents (GDScript) and the control room
  scripts/sumo_bridge.py, incident_engine.py, incident_types.py
                        SUMO traffic over TraCI, and the incident and emergency engine
  scripts/sim_api.gd    the city's device interface (local JSON over TCP), used by the MCP server and the gateway
  tools/mcp/            the MCP tools (city_mcp_server.py), the partner gateway (twin_gateway.py), the secure
                        transport (mcp_https.py), keys (make_keys.py), the run-log reader (runlog.py)
  tools/scenario/       the Test Book runner behind scenarios/*.sh
  tools/dashboard/      the web dashboard (an MCP client)
mocks/                  brain_standin.py, guardian_standin.py and their standins.conf
tests/                  run_tests.sh, the Godot tests (*.gd), tests/mcp (MCP server, terminal, dashboard), tests/layers
                        (secure transport, dispatch decisions, configuration, keys, run logs)
twin.conf               the whole link configuration
keys/                   the PEM key pairs (created by the launcher, never committed)
.runtime/               Godot, Python and SUMO (installed by the launcher, never committed)
```

## A message's way through

1. The **twin detects** an incident: the drivers phone for help, and each call needs a responding unit.
2. The partner gateway reports it to the **City Brain** (`report_incident`).
3. The Brain asks the **Guardian** to verify the report. The Guardian reads the twin's live data itself (`read_vehicle`, `read_sector`) and returns a verdict.
4. The Brain reads the emergency fleet (`list_emergency_units`) and answers each call through the twin's actuator tool `dispatch_units`.
5. The twin carries out the decision: the caller phones that unit's facility, and the unit drives out when the call ends. It then reports the end (`close_incident`).

Every step is a line in the run log, in the control room's bottom window and on the Timeline. Messages between the Brain and the Guardian reach the twin's timeline as briefings (`post_briefing`).

If the Brain is unreachable or slow (no answer within 10 s), the twin's own dispatcher answers the call with the same rule: the closest free unit of the kind asked for. The city never waits on a missing partner.

See [INTERFACE.md](INTERFACE.md) for the messages, examples and how to connect a real partner.
