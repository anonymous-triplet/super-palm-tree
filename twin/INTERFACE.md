# Interface Card: City Ground Zero Digital Twin

The twin is the city: traffic (SUMO), incidents and the emergency fleet, 200 citizens, utilities, air, parking, earthquakes and 555 sensors and actuators. It says **what is happening**. It does not decide the response (the **City Brain** does) and does not judge whether data can be trusted (the **Guardian** does).

## Transport and security

| | |
|---|---|
| Protocol | **MCP** (Model Context Protocol), JSON-RPC 2.0, protocol version `2025-06-18` |
| Transport | MCP **Streamable HTTP**: one endpoint, `POST https://<host>:8740/mcp`, one JSON-RPC message per request. A streamed tool call answers as Server-Sent Events. |
| Encryption | **TLS 1.3** on every link. There is no plain-HTTP port. |
| Authentication | **Mutual TLS**: each side presents a certificate with its private key (PEM files, like an SSH key pair). The certificate must be signed by an authority listed in `trusted_ca`, and its common name is the caller's **identity**. A peer without a valid certificate is refused during the handshake. |
| Authorisation | Each identity has an allow-list in `twin.conf`. The Brain may call every read-only tool plus `dispatch_units` and `post_briefing`. The Guardian may call every read-only tool plus `post_briefing`. Anything else is refused, and the refusal is logged. |
| Sessions | `initialize` returns an `Mcp-Session-Id` header that later requests must send back. An unknown session gets HTTP 404, so initialize again. A request resent with the same JSON-RPC `id` gets the original answer and is not run twice. |
| Correlation | Put `"_meta": {"correlationId": "INC-0003"}` in `tools/call`, and the call is filed in that incident's run log. |

## What the twin sends

| To | Tool on the partner | When |
|---|---|---|
| City Brain | `report_incident {incident, requests}` | An incident has emergency calls waiting for a unit: once with the first calls, and again if a call must be re-decided. A scheduled service round is reported with `requests: []`. |
| City Brain | `close_incident {incident, outcome, resolved_at_s, units}` | The scene is cleared and every unit is released. |
| Both | MCP `ping` | Every 3 s, to keep the link status. |

Example: twin → Brain (the `params` of the `tools/call` request).
```json
{"name": "report_incident", "_meta": {"correlationId": "INC-0001"},
 "arguments": {
  "incident": {"id": "INC-0001", "kind": "rear_end", "title": "Rear-end collision", "category": "collision", "severity": "moderate",
               "location": {"edge": "E_r3c4_r3c5", "pos": 46.9, "x": -39.54, "z": -192.15}, "point": {"x": -39.543, "z": -192.153}, "block": "B.4",
               "participants": ["civ_087", "civ_081"], "injuries": ["civ_087", "civ_081"], "units": [], "label": "T01 Rear-end collision"},
  "requests": [{"id": "INC-0001-R1", "ask": 1, "kind": "police", "role": "traffic_control", "aid_allowed": false, "location": {"x": -39.543, "z": -192.153}},
               {"id": "INC-0001-R2", "ask": 1, "kind": "ambulance", "role": "medical", "aid_allowed": false, "location": {"x": -39.543, "z": -192.153}}]}}
```
The expected reply is any object, for example `{"accepted": true, "case": "CASE-INC-0001"}`. The decision comes afterwards through `dispatch_units`.

## What the twin receives

| From | Tool on the twin | Effect |
|---|---|---|
| City Brain | `dispatch_units {incident, decisions[]}` | Answers emergency calls. Each decision gives a `request` and an `ask`, plus an `action`: `unit` (with a `unit` id), `mutual_aid` (only once `aid_allowed` is true), `hold` (wait), or `decline` (with a `reason`). The caller then phones that unit's facility, and the unit leaves when the call ends. |
| Brain, Guardian | any read-only tool, for example `read_vehicle`, `list_vehicles`, `list_emergency_units`, `list_incidents`, `list_dispatch_requests`, `read_sensor`, `read_all`, `read_sector`, `read_city`, `read_timeline` | Live data. Units are SI and every answer is time-stamped. Data tools can stream every 100 ms (`_meta.progressToken`). |
| Brain, Guardian | `post_briefing {to, summary, incident?, payload?}` | Puts one of the partner's own steps on the twin's timeline and run log, for example a question sent to the other partner or a verdict. |

Example: Brain → twin.
```json
{"name": "dispatch_units", "_meta": {"correlationId": "INC-0001"},
 "arguments": {"incident": "INC-0001", "decisions": [
   {"request": "INC-0001-R1", "ask": 1, "action": "unit", "unit": "POL-4", "reason": "closest free police unit (in station 48 m away)"},
   {"request": "INC-0001-R2", "ask": 1, "action": "unit", "unit": "AMB-1", "reason": "closest free ambulance unit (in station 179 m away)"}]}}
```
Reply (`structuredContent`):
`{"source": "city_ground_zero", "tool": "dispatch_units", "timestamp": "2026-11-08T12:45:06.739Z", "incident": "INC-0001", "applied": "INC-0001-R1: POL-4; INC-0001-R2: AMB-1"}`

Example: Guardian → twin. Call `read_vehicle {"id": "civ_087"}`. Reply: `{"id": "civ_087", "class": "car", "location": {"x": -42.18, "y": 0.0, "z": -192.25}, "sector": "B", "speed_mps": 0.0, "stopped": true, "road": "E_r3c4_r3c5", "incident": "INC-0001", ...}`

Example briefing, Guardian → twin: `post_briefing {"to": "brain", "incident": "INC-0001", "summary": "Verdict on INC-0001: trusted (civ_087 is at the scene ...)", "payload": {"verdict": "trusted", "confidence": 0.99, "evidence": [...]}}`

If the Brain is unreachable, or a call goes 10 s without an answer, the twin's own dispatcher answers that call. The city keeps running, and the timeline records it.

## Errors

- **JSON-RPC errors:**
  - `-32700`: the body is not JSON.
  - `-32600`: not a JSON-RPC 2.0 object.
  - `-32601`: unknown method.
  - `-32602`: unknown tool or missing parameter.
  - `-32001`: unknown session or identity.
  - `-32003`: tool not allowed for this identity.
- **Tool errors:** the response carries `"isError": true` and `structuredContent.error = {code, message}`. The codes are `invalid_arguments`, `bad_value`, `unknown_incident`, `unknown_vehicle`, `unknown_device`, `city_unreachable` and so on. A refused request changes nothing.

## Connecting a partner (nothing is hard-coded)

Everything is in `twin/twin.conf`. Paths are relative to that file.

1. **Exchange authorities.** Give the partner `twin/keys/triplet-ca.cert.pem`, the twin's endpoint (`https://<twin-host>:8740/mcp`) and the twin's identity (`city-twin`). Add the partner's CA certificate to `trusted_ca` (comma separated). If you want one authority for the whole triplet instead, sign the partner's certificate with `triplet-ca`, using `twin/src/tools/mcp/make_keys.py`.
2. **Point at them.** In `[partner:brain]` (or `[partner:guardian]`), set `url` to their endpoint, `identity` to the common name of their certificate, and `standin = no` so the bundled stand-in is not started. If their tools have other names, set `report_tool` and `close_tool`.
3. **Open the twin to the network** if they run on another machine. Set `listen_host = 0.0.0.0` and add the machine's address to `hostnames`. With `manage_keys = yes`, the launcher re-issues the twin's certificate for the new names.
4. **Run** `./run_control_room.sh`. The timeline header shows each link as connected and verified, and the first line of each run log names the layers.

Check a link by hand with a client certificate the twin trusts:
```bash
curl --cacert twin/keys/triplet-ca.cert.pem --cert twin/keys/city-brain.cert.pem --key twin/keys/city-brain.key.pem -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl"}}}' https://127.0.0.1:8740/mcp
```
