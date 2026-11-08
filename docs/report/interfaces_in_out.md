# Interfaces in/out

**Scope.** Everything built in this project is the **twin layer**: the digital twin of the city and all its sub-components (traffic engine, incident and emergency engine, citizen society, utilities and grid, environment, 555 simulated sensors and actuators, parking, earthquakes). It is a faithful, controllable replica of the physical city. It does **not** decide what should be done and it does **not** judge whether a reading is trustworthy: the decision layers above it do both. This section describes what crosses the boundary of the twin: what it publishes (*out*), what it accepts (*in*), and the guarantees that let the other layers rely on it.

## 1. Position in the architecture

```
   Decision / analytics layers            Validation layers            Operators, dashboards
   (choose actions)                       (check data validity)        (watch and intervene)
            \                                    |                          /
             \______________  one interface: MCP (JSON-RPC 2.0)  __________/
                                        |
        +---------------------------- TWIN LAYER ------------------------------+
        |  device interface (one registry)                                       |
        |  traffic (SUMO) | incidents + fleet | citizens | utilities | environment |
        |  parking | earthquakes | 555 sensors and actuators                      |
        +------------------------------------------------------------------------+
```

The twin offers **one** external interface, the Model Context Protocol (MCP). Every other layer, whether it is an AI agent, an analytics service, a validator, the terminal or the web dashboard, reads and acts through the same tools. Nothing else reaches into the twin, and the web dashboard is proven to use only this interface.

## 2. Out: what the twin publishes

| Feed | Content | Update |
|---|---|---|
| **Devices** (555 in 20 families) | Every sensor and actuator: id, family, kind (sensor / actuator), sector (A–P), position, readings as `{value, unit}`, actuator state, and a `sampled_at` stamp (frame, unix time, city clock). Families: traffic detectors, cameras, air, noise, weather, flood, utility telemetry, power and water meters, waste-bin weight, seismic (with 3-axis waveform), valves, power switches, street lights, irrigation, reservoirs, grid, sector services, parking lots, factories. | every 100 ms tick |
| **Ground truth entities** | Every road vehicle (class, speed, heading, road, stop reason, sector), every shown citizen (role, current action and the reason for it), incidents with timeline and road closures, the emergency fleet, car parks (occupancy, barrier, refusals), earthquakes (magnitude, sector, buildings collapsed), sectors and buildings. | every 100 ms tick |
| **Whole-city snapshot** (`read_city`) | All of the above plus the event log and the operator-view state in one consistent answer (about 260 KB). | every 100 ms tick |
| **Derived views** | Sensor summaries (min / mean / max per family), waste-bin report, sector report. | on demand or streamed |
| **Resources** | `city://status`, `city://sensors`, `city://sensor/{id}`, with change notifications. | on change |
| **Partner reports** | `report_incident` to the City Brain (the incident and every emergency call that needs a unit), `close_incident` at its end; the layer timeline (`read_timeline`) and one run log per incident in `logs/` | as they happen |

The ground-truth entities are published next to the sensor readings on purpose. Sensors are modelled with noise and reach, so a validation layer can cross-check them (for example a traffic detector's count against the real vehicles near it, or a seismic reading against the earthquake record) and decide which source to believe.

## 3. In: what the twin accepts

All inputs are MCP tool calls (33 acting tools, counting the partners' `post_briefing`; the other 28 are read-only and flagged so). They fall in six groups.

| Group | Examples | Effect inside the twin |
|---|---|---|
| **Environment and time** | weather, time of day, simulation speed 1–8, clock pace, pause / resume | forwarded to the environment system and to SUMO, which stays the master clock |
| **Infrastructure actuation** | power switches, water valves, irrigation, street lights (single or all, dimming), sector power and water cuts, utility recharge, parking barriers (auto / open / closed), factories (auto / on / off), bin emptying | the real model changes and every dependent value follows (outages, light level, parking flow) |
| **Scenario injection** | trigger an incident (10 kinds), resolve all, trigger or clear an earthquake (sector A–P or whole city, magnitude 4–8) | emergency response, lane closures, collapse and seismic waveforms play out inside the twin |
| **Operator view** | cameras, follow a vehicle or person, highlight an asset kind, focus a device, full-window canvas, incident and replay controls | presentation only, no effect on the simulated world |
| **Generic** | `command_actuator(id, command, value)`, `list_commands` | discovery of what any device accepts |
| **Partner decisions** | `dispatch_units` (the City Brain answers each emergency call with a unit, mutual aid, hold or decline), `post_briefing` (a partner puts its own step on the timeline) | the caller phones the chosen unit's facility; the unit leaves when the call ends |

Every command is validated and answered with a structured result: `applied` (what actually happened) plus the readings **before and after**. A bad request returns a typed error (`unknown_device`, `bad_command`, `bad_value`, `invalid_arguments`) and changes nothing. So a decision layer gets closed-loop evidence that its action took effect.

## 4. How the data moves

| # | Between | Transport and format | Rate | Why |
|---|---|---|---|---|
| 1 | City Brain, Guardian ⇄ twin | **MCP** Streamable HTTP inside **mutual TLS 1.3** (certificates on both sides; the common name is the identity; per-identity allow-lists), configured in `twin/twin.conf` | request / answer, live streams at 100 ms; the twin calls the Brain's `report_incident` / `close_incident` | the single standard interface, encrypted and authenticated |
| 1b | Local programs ⇄ twin | the same MCP over stdio (terminal, assistants) | request / answer, live streams | no network exposure |
| 2 | Browser dashboard ⇄ twin | the same MCP carried over **HTTP + Server-Sent Events** | one `read_city` stream, 10 updates/s | a web client with no extra API |
| 3 | MCP server ⇄ simulation core | local TCP, one JSON object per line, served on the main game loop | one snapshot per tick, shared by all clients | consistent frame, one cost however many clients |
| 4 | Traffic engine → twin | UDP, JSON, ~15 packets/s (~40 kB): all vehicles, signals, incidents, fleet, parking | continuous | only the latest state matters |
| 5 | Twin → traffic engine | UDP, small idempotent commands (pause, speed, weather, incident, barrier) | on demand, incident commands acknowledged and resent | cheap but reliable |
| 6 | Twin ⇄ optional citizen planner | local HTTP, advisory only | budget-limited | an external planner never has authority |

Channels 4 to 6 are internal to the twin: they join its own sub-components and are not for other layers.

**Streaming contract.** Any live tool streams by itself when the client asks for progress: one `notifications/progress` per tick (`{tool, t, data}`) until the client cancels or a `duration_s` ends. `once=true` gives a single reading. The wait is taken after each answer, so a slow tick lengthens the interval; updates never queue up or arrive late in a burst.

## 5. What the other layers can rely on

* **Always structured JSON.** Every result, success or error, is one object `{source, tool, timestamp, …}`, identical as text and as structured content.
* **Units and time on every value.** Each reading carries its unit, and each answer a time stamp (frame, wall clock, city clock) so a validator can check freshness and order.
* **One owner per fact.** Vehicle motion is owned by SUMO, citizens by the society kernel, utilities by the utility system, and so on. The interface only reads their state, so two answers cannot contradict each other.
* **One consistent sample per tick.** All clients share the same 100 ms sample, and a command invalidates it, so a read after a write sees the write.
* **Stable ids and discovery.** Device ids and sector letters never change; `list_*` and `list_commands` describe what exists and what each device accepts.
* **Safe by design.** Read and write tools are marked, every argument is range-checked, and the dashboard is read/write only through the tools above.
* **Deterministic and explainable.** Citizen agendas and incident choreography are reproducible and every decision carries a stated reason, so a decision layer can audit what the twin did.

## 6. What the twin deliberately leaves to the other layers

It sets **no thresholds, raises no alarms, ranks no options and certifies no readings**: whether PM2.5 is dangerous, which incident to handle first, or whether a sensor has drifted is for the decision and validation layers. It keeps **no long-term history**: consumers store what they need (the dashboard keeps ten minutes). It simply reflects the city accurately and carries out, faithfully and verifiably, what it is told.
