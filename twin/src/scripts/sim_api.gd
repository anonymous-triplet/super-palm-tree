extends Node

## Live device interface of the running city: every sensor and actuator, read and commanded in real time.
##
## This node owns no simulation state. Every answer is computed from the live scene at the moment of the request
## (the same nodes, metadata and systems the Sensors tab, the citizens and the SUMO bridge use), and every command
## goes through the same code path the control room's own buttons use. It is reached by the MCP server over a
## local line-delimited JSON socket (CITY_SIM_API_PORT); `handle_request` is the single entry point.

const BinWeight := preload("res://scripts/props/bin_weight.gd")
const Sectors := preload("res://scripts/city_sectors.gd")

const WEATHERS := ["clear", "cloudy", "rain", "fog", "storm", "auto"]
const FAMILY_BY_PREFIX := {
	"TRAF": "traffic", "CAM": "camera", "AIR": "air", "NOISE": "noise", "WX": "weather", "FLOOD": "flood",
	"UTIL": "utility", "PWR": "power_meter", "WTR": "water_meter", "WGT": "waste", "CAN": "waste", "BIN": "waste",
	"VLV": "water_valve", "SWT": "power_switch", "LGT": "lighting", "IRR": "irrigation",
	"RSV": "reservoir", "GRID": "grid", "SEC": "sector_service", "SEIS": "seismic", "LOT": "parking", "FAC": "factory",
}
const FAMILY_LABELS := {
	"traffic": "Traffic detectors", "camera": "Street cameras", "air": "Air quality", "noise": "Noise", "weather": "Weather",
	"flood": "Flood / level", "utility": "Utility telemetry", "power_meter": "Power meters", "water_meter": "Water meters",
	"waste": "Waste bin weights", "water_valve": "Water valves", "power_switch": "Power switches",
	"lighting": "Street lights", "irrigation": "Irrigation", "reservoir": "Reservoirs", "grid": "Power grid", "sector_service": "Sector services",
	"seismic": "Seismic sensors", "parking": "Parking lots", "factory": "Factories",
}

var city: Node3D
var control_room: Node
var port := 0

var _server := TCPServer.new()
var _clients: Array[Dictionary] = []
## Sensors are sampled once per MCP tick (100 ms) however many clients stream them; any command invalidates the sample.
var snapshot_ttl_ms := 100
const LIVE_STREAM_WINDOW_MSEC := 600
const SAMPLE_AHEAD_MSEC := 60
var _last_live_request_msec := -100000
var _ahead_stage := 0
const SELF_NAMED_PREFIXES := ["RSV", "SEC", "GRID", "FAC", "LOT"]
var _public_ids := {}
var _internal_ids := {}
var _prepared_environment: Array = []
var _prepared_frame := -10
var _frame_cache := {"at_msec": -1000000, "sensors": [], "reads": {}}
var _requests_served := 0
var _in_request := false
## The layer timeline: every message between the twin, the City Brain and the Guardian, and what the twin detected and did, as
## the partner gateway (tools/mcp/twin_gateway.py) records it. The same lines go to the run logs, the panel's bottom log, the
## Timeline tab and the dashboard.
const TIMELINE_LIMIT := 600
const PAYLOAD_LIMIT := 6000
var _timeline: Array = []
var _timeline_status := {}
var _timeline_seq := 0
## Readiness: how long every system has been up and steady (no loading hitch, the camera still).
const READY_HITCH_SECONDS := 0.5
var _started_msec := 0
var _last_hitch_msec := 0
var _camera_still_since_msec := 0
var _last_camera_transform := Transform3D()
var _ready_since_msec := -1

func setup(city_node: Node3D, control_room_node: Node = null) -> void:
	city = city_node
	control_room = control_room_node

func start_server(listen_port: int) -> bool:
	if _server.is_listening():
		return true
	var error := _server.listen(listen_port, "127.0.0.1")
	if error != OK:
		push_warning("SimApi could not listen on %d (error %d)" % [listen_port, error])
		return false
	port = _server.get_local_port() if listen_port == 0 else listen_port
	return true

func _process(delta: float) -> void:
	_track_readiness(delta)
	_sample_ahead()
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buffer": ""})
	for client in _clients.duplicate():
		var peer := client.peer as StreamPeerTCP
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_clients.erase(client)
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			client.buffer = str(client.buffer) + peer.get_utf8_string(available)
		while str(client.buffer).contains("\n"):
			var split := str(client.buffer).split("\n", true, 1)
			client.buffer = split[1]
			if str(split[0]).strip_edges().is_empty():
				continue
			_answer(client, str(split[0]))
		_flush_answers(client)

## While someone streams the whole city, the sample is gathered ahead of the request and over two frames (sensors, then the
## other devices), so no frame pays for all of it; the device rows are built off the main thread (see _answer). A device
## command discards the sample, so a read after a write is exact.
func _sample_ahead() -> void:
	if Time.get_ticks_msec() - _last_live_request_msec > LIVE_STREAM_WINDOW_MSEC or snapshot_ttl_ms <= 0:
		_ahead_stage = 0
		return
	match _ahead_stage:
		0:
			if Time.get_ticks_msec() - int(_frame_cache.at_msec) >= SAMPLE_AHEAD_MSEC:
				prepare_environment_sample()
				_ahead_stage = 1
		1:
			_frame_cache.at_msec = -1000000
			sensors()
			_ahead_stage = 0

func _answer(client: Dictionary, line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	var request := parsed as Dictionary if parsed is Dictionary else {}
	var holder := {"text": ""}
	var pending: Array = client.get_or_add("pending", [])
	var method := str(request.get("method", ""))
	if method in ["snapshot", "read_all"]:
		# The large live answers: the frame only gathers what lives in the scene (the sensor sample, vehicles, citizens ...);
		# the 555 device rows are built and the whole answer turned into text on a worker thread.
		_last_live_request_msec = Time.get_ticks_msec()
		_requests_served += 1
		var params := request.get("params", {}) as Dictionary if request.get("params", {}) is Dictionary else {}
		var family := str(params.get("family", "")).to_lower() if method == "read_all" else ""
		var sector := str(params.get("sector", "")).to_upper() if method == "read_all" else ""
		var sample := sensors()
		var seismic := _seismic_meta(sample)
		var sampled_at := _sampled_at()
		var shell := _snapshot_shell() if method == "snapshot" else {}
		var request_id: Variant = request.get("id")
		holder["task"] = WorkerThreadPool.add_task(func() -> void:
			var rows := device_rows(sample, family, sector, seismic)
			var devices := {"count": rows.size(), "devices": rows, "sampled_at": sampled_at}
			var result: Dictionary = devices
			if method == "snapshot":
				shell["devices"] = devices
				result = shell
			holder["text"] = JSON.stringify({"id": request_id, "ok": true, "result": result}))
	else:
		var response := handle_request(request) if parsed is Dictionary else {"id": null, "ok": false, "error": {"code": "bad_request", "message": "request must be a JSON object"}}
		holder["text"] = JSON.stringify(response)
	pending.append(holder)

func _flush_answers(client: Dictionary) -> void:
	## Answers leave in the order they were asked, as each is ready.
	var pending: Array = client.get("pending", [])
	while not pending.is_empty():
		var holder := pending[0] as Dictionary
		if holder.has("task"):
			if not WorkerThreadPool.is_task_completed(int(holder.task)):
				return
			WorkerThreadPool.wait_for_task_completion(int(holder.task))
		(client.peer as StreamPeerTCP).put_data((str(holder.text) + "\n").to_utf8_buffer())
		pending.pop_front()

func handle_line(line: String) -> String:
	var parsed: Variant = JSON.parse_string(line)
	if not parsed is Dictionary:
		return JSON.stringify({"id": null, "ok": false, "error": {"code": "bad_request", "message": "request must be a JSON object"}})
	return JSON.stringify(handle_request(parsed as Dictionary))

## One request: {"id", "method", "params"} -> {"id", "ok", "result"} or {"id", "ok": false, "error": {code, message}}.
func handle_request(request: Dictionary) -> Dictionary:
	_in_request = true
	var response := _handle(request)
	_in_request = false
	return response

func _handle(request: Dictionary) -> Dictionary:
	_requests_served += 1
	var method := str(request.get("method", ""))
	var params := request.get("params", {}) as Dictionary if request.get("params", {}) is Dictionary else {}
	var result: Variant = null
	match method:
		"ping": result = {"pong": true, "frame": Engine.get_process_frames()}
		"info": result = info()
		"list_devices": result = list_devices(params)
		"read_all": result = read_all(params)
		"read": result = read_device(str(params.get("id", "")), params.get("metrics", []) as Array if params.get("metrics", []) is Array else [])
		"read_many": result = read_many(params.get("ids", []) as Array if params.get("ids", []) is Array else [])
		"summary": result = summary(str(params.get("family", "")))
		"command": result = command(str(params.get("id", "")), str(params.get("command", "")), params.get("value"))
		"list_commands": result = list_commands(str(params.get("id", "")))
		"list_parking_lots": result = list_parking_lots(params)
		"read_parking_lot": result = read_parking_lot(str(params.get("id", "")))
		"list_sectors": result = list_sectors()
		"read_sector": result = read_sector(str(params.get("sector", "")))
		"list_buildings": result = list_buildings(params)
		"list_earthquakes": result = earthquake_report()
		"list_vehicles": result = list_vehicles(params)
		"read_vehicle": result = read_vehicle(str(params.get("id", "")))
		"list_citizens": result = list_citizens(params)
		"read_citizen": result = read_citizen(str(params.get("id", "")))
		"list_incidents": result = list_incidents()
		"command_result": result = command_result(str(params.get("request", "")))
		"timeline_push": result = timeline_push(params)
		"read_timeline": result = read_timeline(params)
		"readiness": result = readiness()
		"list_emergency_units": result = list_emergency_units(params)
		"snapshot": result = snapshot()
		"air_report": result = air_report()
		"event_log": result = event_log(params)
		"ui_state": result = ui_state()
		_:
			return _error(request, "unknown_method", "unknown method '%s'" % method)
	if result is Dictionary and (result as Dictionary).has("error"):
		var failure := (result as Dictionary).error as Dictionary
		return _error(request, str(failure.get("code", "error")), str(failure.get("message", "")))
	return {"id": request.get("id"), "ok": true, "result": result}

func _error(request: Dictionary, code: String, message: String) -> Dictionary:
	return {"id": request.get("id"), "ok": false, "error": {"code": code, "message": message}}

func _fail(code: String, message: String) -> Dictionary:
	return {"error": {"code": code, "message": message}}

# --- catalogue -------------------------------------------------------------------------------------

func _environment() -> Node:
	return city.get_node_or_null("EnvironmentSystem") if city != null else null

## Every sensor-style device: the environment sensors (real nodes in the "sensors" group) plus the telemetry of
## signals, valves, switches, lights, irrigation, reservoirs and the grid.
## Device ids say where a device is: type-sector.block, as AIR-D.3, with a number when a block holds several of that type, as
## LGT-A.1-3. Street cans are CAN-, large containers BIN-. They are assigned once and never change. The numbers devices are
## registered under stay internal (they also seed each sensor's reading noise).
func _apply_public_ids(entries: Array) -> void:
	# Some devices are fitted a moment after the city starts: the ids settle once they all exist.
	var complete := true
	for value in entries:
		var internal := str((value as Dictionary).id)
		if not _public_ids.has(internal) and not internal.get_slice("-", 0) in SELF_NAMED_PREFIXES:
			complete = false
			break
	if not complete:
		_public_ids.clear()
		_internal_ids.clear()
		var groups := {}
		for value in entries:
			var entry := value as Dictionary
			var internal := str(entry.id)
			var prefix := internal.get_slice("-", 0)
			if prefix in SELF_NAMED_PREFIXES:
				continue
			if prefix == "WGT":
				prefix = "BIN" if internal.begins_with("WGT-C") else "CAN"
			var key := "%s-%s" % [prefix, Sectors.block_label(entry.get("position", Vector3.ZERO) as Vector3)]
			if not groups.has(key):
				groups[key] = []
			(groups[key] as Array).append(internal)
		for key in groups:
			var members := groups[key] as Array
			members.sort()
			for index in members.size():
				var public := str(key) if members.size() == 1 else "%s-%d" % [key, index + 1]
				_public_ids[members[index]] = public
				_internal_ids[public] = members[index]
	for value in entries:
		var entry := value as Dictionary
		var public: Variant = _public_ids.get(entry.id)
		if public != null:
			entry.id = public

func public_id(internal: String) -> String:
	if _public_ids.is_empty():
		sensors()
	return str(_public_ids.get(internal, internal))

func prepare_environment_sample() -> void:
	## Takes the sensor half of a sample now, so a caller can spread one full sample over two frames.
	var env := _environment()
	_prepared_environment = env.call("get_sensor_snapshot") as Array if env != null else []
	_prepared_frame = Engine.get_process_frames()

func sensors() -> Array:
	var now := Time.get_ticks_msec()
	if now - int(_frame_cache.at_msec) < snapshot_ttl_ms:
		return _frame_cache.sensors as Array
	var all: Array = []
	var env := _environment()
	if Engine.get_process_frames() - _prepared_frame <= 1:
		all.append_array(_prepared_environment)
		_prepared_frame = -10
	elif env != null:
		for sensor in env.call("get_sensor_snapshot") as Array:
			all.append(sensor)
	all.append_array(extra_sensor_snapshot())
	_apply_public_ids(all)
	_frame_cache = {"at_msec": now, "sensors": all, "reads": {}}
	return all

static func family_of(sensor_id: String) -> String:
	return str(FAMILY_BY_PREFIX.get(sensor_id.get_slice("-", 0), "other"))

func sensor_by_id(sensor_id: String) -> Dictionary:
	for sensor in sensors():
		if str((sensor as Dictionary).id) == sensor_id:
			return sensor as Dictionary
	return {}

func _device_json(sensor: Dictionary, with_readings := true) -> Dictionary:
	var position := sensor.get("position", Vector3.ZERO) as Vector3
	var sensor_id := str(sensor.id)
	var entry := {
		"id": sensor_id, "kind": "actuator" if _is_actuator(sensor_id) else "sensor", "family": family_of(sensor_id),
		"name": str(sensor.get("name", sensor_id)), "type": str(sensor.get("type", "")),
		"position": [snappedf(position.x, 0.01), snappedf(position.y, 0.01), snappedf(position.z, 0.01)],
		"location": _location(position), "sector": Sectors.sector_of_position(position),
		"metrics": (sensor.readings as Dictionary).keys(),
	}
	var node := sensor.get("node") as Node
	entry["commands"] = _commands_for(sensor_id, node).keys()
	if with_readings:
		var readings := {}
		for metric in (sensor.readings as Dictionary).keys():
			readings[metric] = _reading_json((sensor.readings as Dictionary)[metric] as Dictionary)
		entry["readings"] = readings
		if sensor.has("state"):
			entry["state"] = sensor.state
		var source_node := sensor.get("node") as Node
		if source_node != null and source_node.has_meta("seis_waveform"):
			entry["waveform"] = source_node.get_meta("seis_waveform")
			entry["event"] = str(source_node.get_meta("seis_event", ""))
			var distance := float(source_node.get_meta("seis_distance", -1.0))
			entry["distance_to_affected_area_m"] = snappedf(distance, 0.1) if distance >= 0.0 else null
	return entry

static func _reading_json(reading: Dictionary) -> Dictionary:
	return {"value": float(reading.get("value", 0.0)), "unit": str(reading.get("unit", ""))}

static func _is_actuator(sensor_id: String) -> bool:
	return family_of(sensor_id) in ["water_valve", "power_switch", "lighting", "irrigation", "sector_service", "parking", "factory"]

func info() -> Dictionary:
	var env := _environment()
	var conditions := env.call("get_conditions") as Dictionary if env != null else {}
	var counts := {}
	for sensor in sensors():
		var family := family_of(str((sensor as Dictionary).id))
		counts[family] = int(counts.get(family, 0)) + 1
	return {
		"name": "City Ground Zero", "frame": Engine.get_process_frames(), "device_count": sensors().size(), "families": counts,
		"clock": str(conditions.get("clock_text", "")), "time": str(conditions.get("time_text", "")), "day": int(conditions.get("day", 1)),
		"weather": str(conditions.get("weather", "")), "period": str(conditions.get("period", "")),
		"paused": bool(conditions.get("paused", false)), "speed": float(conditions.get("speed", 1.0)),
		"clock_rate": float(conditions.get("clock_rate", 1.0)), "requests_served": _requests_served,
		"family_labels": FAMILY_LABELS, "traffic": _traffic_summary(), "citizens_shown": _citizens_shown(), "earthquakes_active": _active_earthquakes(),
		"readiness": readiness(),
	}

func _citizens_shown() -> int:
	var npc := city.get_node_or_null("NpcAi") if city != null else null
	return (npc.call("get_agent_motion") as Array).size() if npc != null and npc.has_method("get_agent_motion") else 0

func _traffic_summary() -> Dictionary:
	var state := _traffic_state()
	return {"connected": not state.is_empty(), "simulated_vehicles": int(state.get("simulated_vehicle_count", 0)), "stopped_vehicles": int(state.get("stopped_vehicle_count", 0)),
		"turning_vehicles": int(state.get("turning_vehicle_count", 0)), "time_s": float(state.get("time", 0.0))}

func _active_earthquakes() -> int:
	var system := _earthquakes()
	return int(earthquake_report().get("active", 0)) if system != null else 0

func list_devices(params: Dictionary) -> Dictionary:
	var family := str(params.get("family", "")).to_lower()
	var kind := str(params.get("kind", "")).to_lower()
	var query := str(params.get("query", "")).to_lower()
	var limit := clampi(int(params.get("limit", 50)), 1, 500)
	var offset := maxi(0, int(params.get("offset", 0)))
	var matches: Array = []
	for sensor in sensors():
		var entry := sensor as Dictionary
		var sensor_id := str(entry.id)
		if not family.is_empty() and family_of(sensor_id) != family:
			continue
		if not kind.is_empty() and ("actuator" if _is_actuator(sensor_id) else "sensor") != kind:
			continue
		if not query.is_empty() and not ("%s %s %s" % [sensor_id, str(entry.get("name", "")), str(entry.get("type", ""))]).to_lower().contains(query):
			continue
		matches.append(entry)
	var page: Array = []
	for index in range(offset, mini(offset + limit, matches.size())):
		page.append(_device_json(matches[index] as Dictionary, false))
	return {"total": matches.size(), "offset": offset, "count": page.size(), "devices": page}

## Every device's live readings in one answer (optionally one family or sector): what a dashboard needs to stay in step with the city.
func read_all(params: Dictionary) -> Dictionary:
	var family := str(params.get("family", "")).to_lower()
	var sector := str(params.get("sector", "")).to_upper()
	var all_sensors := sensors()
	var cache_key := family + "|" + sector
	if (_frame_cache.reads as Dictionary).has(cache_key):
		return (_frame_cache.reads as Dictionary)[cache_key] as Dictionary
	var rows := device_rows(all_sensors, family, sector, _seismic_meta(all_sensors))
	var result := {"count": rows.size(), "devices": rows, "sampled_at": _sampled_at()}
	(_frame_cache.reads as Dictionary)[cache_key] = result
	return result

## One row per device of a sensor sample. Touches no node (the seismic waveforms come in `seismic`), so it may run on a
## worker thread.
static func device_rows(sample: Array, family: String, sector: String, seismic: Dictionary) -> Array:
	var rows: Array = []
	for value in sample:
		var sensor := value as Dictionary
		var sensor_id := str(sensor.id)
		var device_family := family_of(sensor_id)
		var position := sensor.get("position", Vector3.ZERO) as Vector3
		var device_sector := Sectors.sector_of_position(position)
		if not family.is_empty() and device_family != family:
			continue
		if not sector.is_empty() and device_sector != sector:
			continue
		var readings := {}
		for metric in (sensor.readings as Dictionary).keys():
			readings[metric] = _reading_json((sensor.readings as Dictionary)[metric] as Dictionary)
		var row := {"id": sensor_id, "family": device_family, "kind": "actuator" if _is_actuator(sensor_id) else "sensor", "name": str(sensor.get("name", sensor_id)),
			"type": str(sensor.get("type", "")), "sector": device_sector, "location": _location(position), "readings": readings}
		if sensor.has("state"):
			row["state"] = sensor.state
		if seismic.has(sensor_id):
			row.merge(seismic[sensor_id] as Dictionary)
		rows.append(row)
	return rows

## Seismic waveforms of a sample, read from their nodes (main thread only).
func _seismic_meta(sample: Array) -> Dictionary:
	var out := {}
	for value in sample:
		var sensor := value as Dictionary
		if not str(sensor.id).begins_with("SEIS"):
			continue
		var node := sensor.get("node") as Node
		if node != null and node.has_meta("seis_waveform"):
			var distance := float(node.get_meta("seis_distance", -1.0))
			out[str(sensor.id)] = {"waveform": node.get_meta("seis_waveform"), "distance_to_affected_area_m": snappedf(distance, 0.1) if distance >= 0.0 else null}
	return out

func _sampled_at() -> Dictionary:
	var env := _environment()
	var clock := str((env.call("get_conditions") as Dictionary).get("clock_text", "")) if env != null else ""
	return {"frame": Engine.get_process_frames(), "unix_msec": int(Time.get_unix_time_from_system() * 1000.0), "clock": clock}

func read_device(sensor_id: String, metrics: Array = []) -> Dictionary:
	var sensor := sensor_by_id(sensor_id)
	if sensor.is_empty():
		return _fail("unknown_device", "no device with id '%s' (use list_devices to see ids)" % sensor_id)
	var entry := _device_json(sensor)
	if not metrics.is_empty():
		var wanted := {}
		for metric in metrics:
			if not (entry.readings as Dictionary).has(str(metric)):
				return _fail("unknown_metric", "%s has no metric '%s' (available: %s)" % [sensor_id, str(metric), ", ".join(PackedStringArray((entry.metrics as Array).map(func(m): return str(m))))])
			wanted[str(metric)] = (entry.readings as Dictionary)[str(metric)]
		entry["readings"] = wanted
	var env := _environment()
	entry["sampled_at"] = {"frame": Engine.get_process_frames(), "unix_msec": int(Time.get_unix_time_from_system() * 1000.0), "clock": str((env.call("get_conditions") as Dictionary).get("clock_text", "")) if env != null else ""}
	return entry

func read_many(ids: Array) -> Dictionary:
	var out: Array = []
	var missing: Array = []
	for value in ids:
		var result := read_device(str(value))
		if result.has("error"):
			missing.append(str(value))
		else:
			out.append(result)
	return {"devices": out, "unknown_ids": missing}

func summary(family: String) -> Dictionary:
	var rows := {}
	for sensor in sensors():
		var entry := sensor as Dictionary
		var fam := family_of(str(entry.id))
		if not family.is_empty() and fam != family.to_lower():
			continue
		var bucket := rows.get(fam, {}) as Dictionary
		for metric in (entry.readings as Dictionary).keys():
			var reading := (entry.readings as Dictionary)[metric] as Dictionary
			var stats := bucket.get(metric, {"count": 0, "min": INF, "max": -INF, "sum": 0.0, "unit": str(reading.get("unit", ""))}) as Dictionary
			var value := float(reading.get("value", 0.0))
			stats.count = int(stats.count) + 1
			stats.min = minf(float(stats.min), value)
			stats.max = maxf(float(stats.max), value)
			stats.sum = float(stats.sum) + value
			bucket[metric] = stats
		rows[fam] = bucket
	var out := {}
	for fam in rows:
		var metrics := {}
		for metric in (rows[fam] as Dictionary):
			var stats := (rows[fam] as Dictionary)[metric] as Dictionary
			metrics[metric] = {"devices": int(stats.count), "min": snappedf(float(stats.min), 0.01), "max": snappedf(float(stats.max), 0.01), "mean": snappedf(float(stats.sum) / maxf(1.0, float(stats.count)), 0.01), "unit": str(stats.unit)}
		out[fam] = metrics
	return {"families": out}

# --- extra telemetry ---------------------------------------------------------------------------------

func extra_sensor_snapshot() -> Array:
	var out: Array = []
	if city == null:
		return out
	var tree := city.get_tree()
	var life := city.get_node_or_null("CityLife")
	var valve_number := 0
	for value in tree.get_nodes_in_group("water_valves"):
		var valve := value as Node3D
		valve_number += 1
		var open := bool(valve.get_meta("valve_open", true))
		out.append(_entry("VLV-%02d" % valve_number, valve.name, "Water valve", valve, {"valve_open": [100.0 if open else 0.0, "%"]}, {"state": "open" if open else "closed"}))
	var switch_number := 0
	var grid := city.get_node_or_null("PowerGrid")
	for value in tree.get_nodes_in_group("power_switches"):
		var power_switch := value as Node3D
		switch_number += 1
		var closed := bool(power_switch.get_meta("switch_closed", true))
		out.append(_entry("SWT-%02d" % switch_number, power_switch.name, "Power switch", power_switch, {
			"switch_closed": [100.0 if closed else 0.0, "%"], "powered": [100.0 if bool(power_switch.get_meta("power_online", false)) else 0.0, "%"],
		}, {"state": "closed" if closed else "open"}))
	var light_number := 0
	for value in tree.get_nodes_in_group("smart_street_lights"):
		var light := value as Node3D
		light_number += 1
		out.append(_entry("LGT-%03d" % light_number, light.name, "Smart street light", light, {
			"light_level": [float(light.get_meta("light_level", 0.0)) * 100.0, "%"],
		}, {"mode": str(light.get_meta("light_mode", "auto")), "state": str(light.get_meta("actuator_state", ""))}))
	var irrigation_number := 0
	for value in tree.get_nodes_in_group("irrigation_valves"):
		var irrigation := value as Node3D
		irrigation_number += 1
		var flowing := bool(irrigation.get_meta("valve_open", false))
		out.append(_entry("IRR-%02d" % irrigation_number, irrigation.name, "Irrigation valve", irrigation, {
			"valve_open": [100.0 if flowing else 0.0, "%"], "irrigation_flow": [1.8 if flowing else 0.0, "m³/h"],
		}, {"state": "open" if flowing else "closed"}))
	var utilities := city.get_node_or_null("UtilityResources")
	if utilities != null and utilities.has_method("get_utility_status"):
		var status := utilities.call("get_utility_status") as Dictionary
		for reservoir_value in status.get("reservoirs", []) as Array:
			var reservoir := reservoir_value as Dictionary
			var site := _reservoir_node(tree, str(reservoir.name))
			var reservoir_label := Sectors.block_label(site.global_position) if site != null else str(reservoir.name)
			out.append(_entry("RSV-%s" % reservoir_label, "Reservoir %s" % reservoir_label, "Reservoir", site, {
				"water_level": [float(reservoir.percent), "%"], "water_volume": [float(reservoir.current_m3), "m³"], "water_demand": [float(reservoir.demand_m3h), "m³/h"],
			}, {}))
		var power := status.get("power", {}) as Dictionary
		out.append(_entry("GRID-01", "Power grid", "Grid storage", grid as Node3D, {
			"energy_level": [float(power.get("percent", 0.0)), "%"], "energy_available": [float(power.get("available_kwh", 0.0)), "kWh"], "grid_demand": [float(power.get("demand_kw", 0.0)), "kW"],
		}, {}))
		var power_cuts := status.get("manual_power_clusters", []) as Array
		var water_cuts := status.get("manual_water_clusters", []) as Array
		for cluster_value in status.get("service_clusters", []) as Array:
			var cluster := cluster_value as Dictionary
			var cluster_name := str(cluster.get("name", ""))
			var power_ok := not power_cuts.has(cluster_name) and str(status.get("power_shed_cluster", "")) != cluster_name
			out.append(_entry("SEC-%s" % cluster_name, "Sector %s" % cluster_name, "Sector service", null, {
				"power_supplied": [100.0 if power_ok else 0.0, "%"], "water_supplied": [0.0 if water_cuts.has(cluster_name) else 100.0, "%"],
				"sector_power": [float(cluster.get("power_meter_kw", 0.0)), "kW"], "sector_water": [float(cluster.get("water_meter_m3h", 0.0)), "m³/h"],
			}, {"power_cut": power_cuts.has(cluster_name), "water_cut": water_cuts.has(cluster_name)}))
	var presenter := _parking()
	if presenter != null:
		for report_value in parking_lots():
			var report := report_value as Dictionary
			var lot_node := (presenter.get("lots") as Dictionary).get(str(report.id), {}).get("node") as Node3D
			var capacity := maxi(int(report.capacity), 1)
			out.append(_entry(str(report.id), "Parking %s" % str(report.id), "Smart car park", lot_node, {
				"occupancy": [float(report.occupied), "cars"], "capacity": [float(report.capacity), "cars"],
				"occupancy_percent": [float(report.occupied) / float(capacity) * 100.0, "%"], "denied_entries": [float(report.denied_entries), "cars"],
				"entered": [float(report.entered_total), "cars"], "left": [float(report.left_total), "cars"],
			}, {"barrier_mode": report.barrier_mode, "gate_open": report.gate_open, "warning": report.warning, "incoming": report.incoming, "redirected": report.redirected_total, "edge": report.edge}))
	var factory_system := _factories()
	if factory_system != null:
		for factory_value in factory_system.get("factories") as Array:
			var factory := factory_value as Dictionary
			var report := factory_system.call("factory_report", factory) as Dictionary
			out.append(_entry(str(factory.id), str(factory.name), "Factory", (factory.buildings as Array)[0] as Node3D, {
				"emission_rate": [float(report.emission_percent), "%"], "gas_clouds": [float(report.clouds), "clouds"],
			}, {"state": report.state, "mode": report.mode, "block": report.block, "next_change_s": report.next_change_s}))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.id) < str(b.id))
	return out

func _factories() -> Node:
	return city.get_node_or_null("Factories") if city != null else null

## Air quality by sector: what each sector's monitors read, the factories, the wind and the clouds now over the city.
func air_report() -> Dictionary:
	var by_sector := {}
	for value in sensors():
		var sensor := value as Dictionary
		if family_of(str(sensor.id)) != "air":
			continue
		var sector := Sectors.sector_of_position(sensor.get("position", Vector3.ZERO) as Vector3)
		if not by_sector.has(sector):
			by_sector[sector] = {"sector": sector, "monitors": [], "_sum": {}}
		var row := by_sector[sector] as Dictionary
		(row.monitors as Array).append(str(sensor.id))
		for metric in ["pm2_5", "pm10", "nitrogen_dioxide", "sulphur_dioxide", "air_quality_index"]:
			(row._sum as Dictionary)[metric] = float((row._sum as Dictionary).get(metric, 0.0)) + float(((sensor.readings as Dictionary)[metric] as Dictionary).value)
	var sectors: Array = []
	for sector in Sectors.IDS:
		if not by_sector.has(sector):
			continue
		var row := by_sector[sector] as Dictionary
		var count := float((row.monitors as Array).size())
		var out := {"sector": sector, "monitors": row.monitors}
		for metric in row._sum:
			out[metric] = snappedf(float((row._sum as Dictionary)[metric]) / count, 0.1)
		out["category"] = _air_category(float(out.air_quality_index))
		sectors.append(out)
	var rows: Array = []
	var system := _factories()
	var wind := {}
	var clouds: Array = []
	if system != null:
		for factory in system.get("factories") as Array:
			var report := system.call("factory_report", factory) as Dictionary
			report["location"] = _location(report.centre as Vector3)
			report.erase("centre")
			rows.append(report)
		clouds = system.call("cloud_positions") as Array
	var env := _environment()
	if env != null and env.has_method("get_wind"):
		wind = env.call("get_wind") as Dictionary
	return {"sectors": sectors, "factories": rows, "wind": wind, "clouds": clouds, "cloud_count": clouds.size()}

static func _air_category(index: float) -> String:
	if index <= 50.0:
		return "good"
	if index <= 100.0:
		return "moderate"
	if index <= 150.0:
		return "unhealthy_for_sensitive_groups"
	if index <= 200.0:
		return "unhealthy"
	return "very_unhealthy" if index <= 300.0 else "hazardous"

func _reservoir_node(tree: SceneTree, reservoir_name: String) -> Node3D:
	for value in tree.get_nodes_in_group("water_reservoir_sites"):
		if (value as Node).name == reservoir_name or str((value as Node).name).contains(reservoir_name):
			return value as Node3D
	return null

func _entry(sensor_id: String, display_name: String, type_text: String, node: Node3D, metrics: Dictionary, state: Dictionary) -> Dictionary:
	var readings := {}
	for metric in metrics:
		var pair := metrics[metric] as Array
		readings[metric] = {"value": snappedf(float(pair[0]), 0.1), "unit": str(pair[1])}
	return {"id": sensor_id, "name": display_name, "type": type_text, "position": node.global_position if node != null else Vector3.ZERO, "node": node, "sample_sequence": Engine.get_process_frames(), "readings": readings, "state": state}

# --- sectors, buildings, earthquakes ---------------------------------------------------------------

static func _location(position: Vector3) -> Dictionary:
	return {"x": snappedf(position.x, 0.01), "y": snappedf(position.y, 0.01), "z": snappedf(position.z, 0.01)}

func _earthquakes() -> Node:
	return city.get_node_or_null("Earthquakes") if city != null else null

func _buildings_all() -> Array:
	var out: Array = []
	if city == null:
		return out
	var tree := city.get_tree()
	for group_name in ["buildings", "backdrop_buildings"]:
		for value in tree.get_nodes_in_group(group_name):
			if value is Node3D:
				out.append(value)
	return out

func list_sectors() -> Dictionary:
	var rows: Array = []
	for sector in Sectors.IDS:
		rows.append(_sector_summary(str(sector)))
	var overlay := city.get_node_or_null("SectorOverlay") if city != null else null
	return {"sectors": rows, "count": rows.size(), "shown_sectors": overlay.call("shown_sectors") if overlay != null else [], "layout": "4 x 4 grid of sectors, A (top left) to P (bottom right), blocks 1 2 / 3 4 in each"}

func _sector_summary(sector: String) -> Dictionary:
	var families := {}
	var device_count := 0
	for sensor in sensors():
		var entry := sensor as Dictionary
		if Sectors.sector_of_position(entry.get("position", Vector3.ZERO) as Vector3) != sector:
			continue
		if entry.get("node") == null and family_of(str(entry.id)) in ["sector_service", "grid", "reservoir"]:
			continue
		var family := family_of(str(entry.id))
		families[family] = int(families.get(family, 0)) + 1
		device_count += 1
	var buildings := 0
	var collapsed := 0
	for value in _buildings_all():
		var building := value as Node3D
		if Sectors.sector_of_position(building.global_position) != sector:
			continue
		buildings += 1
		collapsed += int(building.has_meta("collapsed"))
	var centre := Sectors.centre(sector)
	return {"sector": sector, "name": Sectors.label(sector), "centre": _location(centre), "bounds": {"x": Sectors.rect(sector).position.x, "z": Sectors.rect(sector).position.y, "size": Sectors.SECTOR_SIZE},
		"neighbours": Sectors.neighbours(sector), "devices": device_count, "devices_by_family": families, "buildings": buildings, "collapsed_buildings": collapsed}

func read_sector(sector: String) -> Dictionary:
	if not Sectors.is_sector(sector):
		return _fail("unknown_sector", "sector must be one of %s" % ", ".join(PackedStringArray(Sectors.IDS)))
	var target := sector.to_upper()
	var report := _sector_summary(target)
	var metrics := {}
	for sensor in sensors():
		var entry := sensor as Dictionary
		if Sectors.sector_of_position(entry.get("position", Vector3.ZERO) as Vector3) != target or entry.get("node") == null:
			continue
		var family := family_of(str(entry.id))
		if family in ["lighting", "waste"]:
			continue
		for metric in (entry.readings as Dictionary).keys():
			var key := "%s.%s" % [family, metric]
			var reading := (entry.readings as Dictionary)[metric] as Dictionary
			var bucket := metrics.get(key, {"devices": 0, "min": INF, "max": -INF, "sum": 0.0, "unit": str(reading.get("unit", ""))}) as Dictionary
			var value := float(reading.get("value", 0.0))
			bucket.devices = int(bucket.devices) + 1
			bucket.min = minf(float(bucket.min), value)
			bucket.max = maxf(float(bucket.max), value)
			bucket.sum = float(bucket.sum) + value
			metrics[key] = bucket
	var summary := {}
	for key in metrics:
		var bucket := metrics[key] as Dictionary
		summary[key] = {"devices": bucket.devices, "min": snappedf(float(bucket.min), 0.001), "max": snappedf(float(bucket.max), 0.001), "mean": snappedf(float(bucket.sum) / maxf(1.0, float(bucket.devices)), 0.001), "unit": bucket.unit}
	report["sensor_summary"] = summary
	var bins := 0
	var bin_kg := 0.0
	for value in city.get_tree().get_nodes_in_group("bin_weight_sensors"):
		if Sectors.sector_of_position((value as Node3D).global_position) == target:
			bins += 1
			bin_kg += BinWeight.weight_of(value as Node)
	report["waste"] = {"bins": bins, "total_weight_kg": snappedf(bin_kg, 0.01)}
	var quakes: Array = []
	var system := _earthquakes()
	if system != null:
		for event_value in system.call("public_events") as Array:
			var event := event_value as Dictionary
			if str(event.sector) in [target, "ALL"]:
				quakes.append(event)
	report["earthquakes"] = quakes
	var lots: Array = []
	for lot in parking_lots():
		if str((lot as Dictionary).get("sector", "")) == target:
			lots.append(lot)
	report["parking_lots"] = lots
	return report

func list_buildings(params: Dictionary) -> Dictionary:
	var sector := str(params.get("sector", "")).to_upper()
	var only_collapsed := bool(params.get("collapsed_only", false))
	var limit := clampi(int(params.get("limit", 50)), 1, 500)
	var offset := maxi(0, int(params.get("offset", 0)))
	var rows: Array = []
	for value in _buildings_all():
		var building := value as Node3D
		var building_sector := Sectors.sector_of_position(building.global_position)
		if not sector.is_empty() and building_sector != sector:
			continue
		var is_collapsed := building.has_meta("collapsed")
		if only_collapsed and not is_collapsed:
			continue
		rows.append({"id": str(building.name), "sector": building_sector, "location": _location(building.global_position),
			"state": "collapsed" if is_collapsed else ("collapsing" if building.has_meta("collapse_pending") else "standing"),
			"district": "core" if building.is_in_group("buildings") else "outer"})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.id) < str(b.id))
	var page := rows.slice(offset, offset + limit)
	return {"total": rows.size(), "offset": offset, "count": page.size(), "buildings": page}

func earthquake_report() -> Dictionary:
	var system := _earthquakes()
	if system == null:
		return _fail("unavailable", "the earthquake system is not available")
	var events := system.call("public_events") as Array
	var active := 0
	for event in events:
		active += int(str((event as Dictionary).status) == "active")
	return {"earthquakes": events, "active": active, "collapsed_buildings": int(system.call("collapsed_count"))}

# --- vehicles, citizens, incidents, emergency units -------------------------------------------------

func _traffic_state() -> Dictionary:
	var life := city.get_node_or_null("CityLife") if city != null else null
	return (life.get("_last_state") as Dictionary) if life != null and life.get("_last_state") is Dictionary else {}

func _vehicle_json(entry: Dictionary) -> Dictionary:
	var position := Vector3(float(entry.get("x", 0.0)), 0.0, float(entry.get("z", 0.0)))
	return {
		"id": str(entry.get("id", "")), "class": str(entry.get("cls", "")), "type": str(entry.get("type", "")),
		"location": _location(position), "sector": Sectors.sector_of_position(position), "speed_mps": snappedf(float(entry.get("speed", 0.0)), 0.01),
		"heading_deg": snappedf(float(entry.get("angle", 0.0)), 0.1), "road": str(entry.get("road", "")),
		"stopped": bool(entry.get("stopped", false)), "stop_reason": str(entry.get("stop_reason", "")),
		"unit": str(entry.get("unit", "")), "incident": str(entry.get("incident", "")),
	}

func list_vehicles(params: Dictionary) -> Dictionary:
	var wanted_class := str(params.get("class", "")).to_lower()
	var sector := str(params.get("sector", "")).to_upper()
	var limit := clampi(int(params.get("limit", 50)), 1, 500)
	var offset := maxi(0, int(params.get("offset", 0)))
	var rows: Array = []
	var state := _traffic_state()
	for value in state.get("vehicles", []) as Array:
		var row := _vehicle_json(value as Dictionary)
		if not wanted_class.is_empty() and str(row["class"]) != wanted_class:
			continue
		if not sector.is_empty() and str(row.sector) != sector:
			continue
		rows.append(row)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.id) < str(b.id))
	var page := rows.slice(offset, offset + limit)
	return {"total": rows.size(), "offset": offset, "count": page.size(), "vehicles": page, "simulated": int(state.get("simulated_vehicle_count", 0)), "time_s": float(state.get("time", 0.0))}

func read_vehicle(vehicle_id: String) -> Dictionary:
	for value in _traffic_state().get("vehicles", []) as Array:
		var entry := value as Dictionary
		if str(entry.get("id", "")) == vehicle_id or str(entry.get("unit", "")) == vehicle_id:
			var row := _vehicle_json(entry)
			row["length_m"] = float(entry.get("len", 0.0))
			row["waiting_s"] = float(entry.get("waiting", 0.0))
			return row
	return _fail("unknown_vehicle", "no vehicle '%s' is on the road right now (use list_vehicles)" % vehicle_id)

func _agents() -> Array:
	var npc := city.get_node_or_null("NpcAi") if city != null else null
	return npc.call("get_agent_debug") as Array if npc != null and npc.has_method("get_agent_debug") else []

func _citizen_json(state: Dictionary) -> Dictionary:
	var node := state.get("node") as Node3D
	var position := node.global_position if node != null else Vector3.ZERO
	return {
		"id": str(state.get("citizen_id", "")), "name": str(state.get("display_name", "")), "role": str(state.get("role", "")),
		"household_id": str(state.get("household_id", "")), "action": str(state.get("action", "")), "action_target": str(state.get("action_target", "")),
		"motion_state": str(state.get("motion_state", "")), "speed_mps": snappedf(float(state.get("speed_mps", 0.0)), 0.01),
		"station_id": str(state.get("station_id", "")), "decision_reason": str(state.get("decision_reason", "")),
		"completed_actions": int(state.get("completed_actions", 0)), "location": _location(position), "sector": Sectors.sector_of_position(position), "embodied": true,
	}

func list_citizens(params: Dictionary) -> Dictionary:
	var sector := str(params.get("sector", "")).to_upper()
	var role := str(params.get("role", "")).to_lower()
	var limit := clampi(int(params.get("limit", 50)), 1, 500)
	var offset := maxi(0, int(params.get("offset", 0)))
	var rows: Array = []
	var npc_brief := city.get_node_or_null("NpcAi") if city != null else null
	for value in (npc_brief.call("get_agent_briefs") as Array if npc_brief != null else []):
		var row := _citizen_json(value as Dictionary)
		if not sector.is_empty() and str(row.sector) != sector:
			continue
		if not role.is_empty() and not str(row.role).to_lower().contains(role):
			continue
		rows.append(row)
	var page := rows.slice(offset, offset + limit)
	var npc := city.get_node_or_null("NpcAi")
	var society := npc.call("get_society_debug") as Dictionary if npc != null and npc.has_method("get_society_debug") else {}
	return {"total_visible": rows.size(), "offset": offset, "count": page.size(), "citizens": page, "population": int(society.get("citizens", society.get("population", 0)))}

func read_citizen(citizen_id: String) -> Dictionary:
	for value in _agents():
		var state := value as Dictionary
		if str(state.get("citizen_id", "")) == citizen_id or str(state.get("npc_id", "")) == citizen_id:
			var row := _citizen_json(state)
			row["society"] = _society_view(citizen_id)
			return row
	var record := _society_view(citizen_id)
	if record.is_empty():
		return _fail("unknown_citizen", "no citizen '%s' (use list_citizens for the ones currently shown)" % citizen_id)
	return {"id": citizen_id, "embodied": false, "society": record}

func _society_view(citizen_id: String) -> Dictionary:
	var npc := city.get_node_or_null("NpcAi") if city != null else null
	if npc == null:
		return {}
	var society = npc.get("_society")
	if society == null or not society.has_method("get_citizen_public_state"):
		return {}
	return _plain(society.call("get_citizen_public_state", citizen_id)) as Dictionary

## Strips engine types from a state dictionary so it serialises as plain JSON.
func _plain(value: Variant) -> Variant:
	if value is Dictionary:
		var out := {}
		for key in value:
			out[str(key)] = _plain(value[key])
		return out
	if value is Array:
		var list: Array = []
		for item in value:
			list.append(_plain(item))
		return list
	if value is Vector3:
		return _location(value)
	if value is Node:
		return str((value as Node).name)
	if value is StringName:
		return str(value)
	return value

func _incident_manager() -> Node:
	return city.get_node_or_null("Incidents") if city != null else null

func list_incidents() -> Dictionary:
	var manager := _incident_manager()
	if manager == null:
		return _fail("unavailable", "the incident system is not available")
	var state := manager.get("last_state") as Dictionary
	# How police are running a junction's signals is the engine's business, not part of the record.
	var open_incidents := _plain(state.get("incidents", [])) as Array
	for incident in open_incidents:
		((incident as Dictionary).get("scene", {}) as Dictionary).erase("junction_control")
	return {"incidents": open_incidents, "resolved_recently": _plain(state.get("resolved_incidents", [])),
		"closures": _plain(state.get("closures", [])), "time_s": float(state.get("time", 0.0))}

func list_emergency_units(params: Dictionary) -> Dictionary:
	var manager := _incident_manager()
	if manager == null:
		return _fail("unavailable", "the incident system is not available")
	var kind := str(params.get("kind", "")).to_lower()
	var status := str(params.get("status", "")).to_lower()
	var vehicles := {}
	for value in _traffic_state().get("vehicles", []) as Array:
		var entry := value as Dictionary
		if not str(entry.get("unit", "")).is_empty():
			vehicles[str(entry.unit)] = entry
	var rows: Array = []
	for unit_value in (manager.get("last_state") as Dictionary).get("fleet", []) as Array:
		var unit := unit_value as Dictionary
		if not kind.is_empty() and str(unit.get("kind", "")).to_lower() != kind:
			continue
		if not status.is_empty() and str(unit.get("status", "")).to_lower() != status:
			continue
		var row := _plain(unit) as Dictionary
		var live := vehicles.get(str(unit.get("unit", "")), {}) as Dictionary
		if not live.is_empty():
			var position := Vector3(float(live.get("x", 0.0)), 0.0, float(live.get("z", 0.0)))
			row["location"] = _location(position)
			row["sector"] = Sectors.sector_of_position(position)
			row["speed_mps"] = snappedf(float(live.get("speed", 0.0)), 0.01)
		rows.append(row)
	return {"count": rows.size(), "units": rows}

func _parking() -> Node:
	return city.get_node_or_null("ParkingLots") if city != null else null

func parking_lots() -> Array:
	var presenter := _parking()
	return presenter.call("all_reports") as Array if presenter != null and presenter.has_method("all_reports") else []

func list_parking_lots(params: Dictionary) -> Dictionary:
	var sector := str(params.get("sector", "")).to_upper()
	var rows: Array = []
	for lot in parking_lots():
		if sector.is_empty() or str((lot as Dictionary).sector) == sector:
			var row := (lot as Dictionary).duplicate(true)
			row.erase("cars")
			rows.append(row)
	var parked := 0
	var capacity := 0
	for row in rows:
		parked += int((row as Dictionary).occupied)
		capacity += int((row as Dictionary).capacity)
	return {"count": rows.size(), "lots": rows, "parked": parked, "capacity": capacity}

func read_parking_lot(lot_id: String) -> Dictionary:
	var presenter := _parking()
	var report := presenter.call("lot_report", lot_id) as Dictionary if presenter != null else {}
	if report.is_empty():
		return _fail("unknown_device", "no parking lot '%s' (use list_parking_lots)" % lot_id)
	return report

# --- actuators ---------------------------------------------------------------------------------------

## Everything a live view needs, in one answer (so a dashboard costs the city one request per tick, not ten).
func snapshot() -> Dictionary:
	var out := _snapshot_shell()
	out["devices"] = read_all({})
	return out

## The snapshot without its device rows (those are built on a worker for streamed requests).
func _snapshot_shell() -> Dictionary:
	var out := {"status": info(), "vehicles": list_vehicles({"limit": 500}), "citizens": list_citizens({"limit": 200}),
		"incidents": list_incidents(), "units": list_emergency_units({}), "parking": list_parking_lots({}), "earthquakes": earthquake_report(), "air": air_report()}
	if control_room != null and control_room.has_method("api_event_log"):
		out["events"] = event_log({"limit": 60})
		out["ui"] = ui_state()
	out["timeline"] = read_timeline({"limit": 80})
	for key in out:
		if (out[key] as Dictionary).has("error"):
			out[key] = null
	return out

func event_log(params: Dictionary) -> Dictionary:
	if control_room == null or not control_room.has_method("api_event_log"):
		return _fail("unavailable", "the control room event log is not attached")
	var rows := control_room.call("api_event_log", int(params.get("limit", 60))) as Array
	return {"count": rows.size(), "events": rows}

func ui_state() -> Dictionary:
	if control_room == null or not control_room.has_method("api_ui_state"):
		return _fail("unavailable", "the control room is not attached")
	return control_room.call("api_ui_state") as Dictionary

## The bridge's answer to a command sent over the incident link ("" while it is on its way).
func command_result(request: String) -> Dictionary:
	var manager := _incident_manager()
	if manager == null:
		return _fail("unavailable", "the incident system is not available")
	var result := str(manager.link.call("result_of", request))
	return {"request": request, "done": not result.is_empty(), "result": result}

## The partner gateway adds timeline entries (and the state of each partner link) here.
func timeline_push(params: Dictionary) -> Dictionary:
	var added: Array = []
	for value in params.get("entries", []) as Array:
		if not value is Dictionary:
			continue
		var entry := (value as Dictionary).duplicate(true)
		_timeline_seq += 1
		entry["seq"] = _timeline_seq
		var payload: Variant = entry.get("payload")
		if payload != null:
			var text: String = str(payload) if payload is String else JSON.stringify(payload, "  ")
			entry["payload"] = text if text.length() <= PAYLOAD_LIMIT else text.left(PAYLOAD_LIMIT) + "\n… (full payload in the run log)"
		_timeline.append(entry)
		added.append(entry)
	if _timeline.size() > TIMELINE_LIMIT:
		_timeline = _timeline.slice(_timeline.size() - TIMELINE_LIMIT)
	if params.get("status") is Dictionary:
		_timeline_status = (params.status as Dictionary).duplicate(true)
	if control_room != null and control_room.has_method("api_timeline_added"):
		control_room.call("api_timeline_added", added, _timeline_status)
	return {"added": added.size(), "last_seq": _timeline_seq}

## Timeline entries newest last. since_seq: only newer ones; incident: one incident's run; seq: one entry with its payload.
func read_timeline(params: Dictionary) -> Dictionary:
	var since := int(params.get("since_seq", 0))
	var incident := str(params.get("incident", ""))
	var wanted := int(params.get("seq", 0))
	var limit := clampi(int(params.get("limit", 200)), 1, TIMELINE_LIMIT)
	var rows: Array = []
	for value in _timeline:
		var entry := value as Dictionary
		if wanted > 0:
			if int(entry.seq) == wanted:
				return {"entry": entry, "status": _timeline_status}
			continue
		if int(entry.seq) <= since or (not incident.is_empty() and str(entry.get("incident", "")) != incident):
			continue
		var row := entry.duplicate()
		row.erase("payload")
		row["has_payload"] = entry.has("payload")
		rows.append(row)
	if wanted > 0:
		return _fail("unknown_entry", "no timeline entry %d (only the latest %d are kept; the run logs keep all)" % [wanted, TIMELINE_LIMIT])
	if rows.size() > limit:
		rows = rows.slice(rows.size() - limit)
	return {"count": rows.size(), "last_seq": _timeline_seq, "entries": rows, "status": _timeline_status}

func _track_readiness(delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _started_msec == 0:
		_started_msec = now
		_last_hitch_msec = now
		_camera_still_since_msec = now
	if delta > READY_HITCH_SECONDS:
		_last_hitch_msec = now
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	var current := camera.global_transform if camera != null else Transform3D()
	if not current.is_equal_approx(_last_camera_transform):
		_last_camera_transform = current
		_camera_still_since_msec = now

## Whether the city is up and steady: traffic flowing, citizens out, the incident system loaded, no loading hitch for two seconds
## and the viewport camera still for one. stable_s is how long all of that has held (a scenario starts one second after it does).
func readiness() -> Dictionary:
	var now := Time.get_ticks_msec()
	var traffic := _traffic_summary()
	var manager := _incident_manager()
	var checks := {
		"traffic": bool(traffic.connected) and int(traffic.simulated_vehicles) > 0,
		"citizens": _citizens_shown() > 0,
		"incident_system": manager != null and bool(manager.get("prewarmed")) and not (manager.get("last_state") as Dictionary).is_empty(),
		"no_loading": _started_msec > 0 and now - _last_hitch_msec >= 2000,
		"camera_still": _started_msec > 0 and now - _camera_still_since_msec >= 1000,
	}
	var ready := true
	for key in checks:
		ready = ready and bool(checks[key])
	if ready and _ready_since_msec < 0:
		_ready_since_msec = now
	elif not ready:
		_ready_since_msec = -1
	return {"ready": ready, "stable_s": snappedf((now - _ready_since_msec) / 1000.0, 0.01) if ready else 0.0, "checks": checks,
		"uptime_s": snappedf((now - _started_msec) / 1000.0, 0.01) if _started_msec > 0 else 0.0}

func list_commands(sensor_id: String) -> Dictionary:
	if sensor_id.is_empty():
		var global := {}
		for key in _global_commands():
			global[key] = _global_commands()[key]
		var by_family := {}
		for sensor in sensors():
			var entry := sensor as Dictionary
			var family := family_of(str(entry.id))
			if not by_family.has(family):
				for key in _commands_for(str(entry.id), entry.get("node") as Node):
					by_family[family] = by_family.get(family, {})
					(by_family[family] as Dictionary)[key] = (_commands_for(str(entry.id), entry.get("node") as Node))[key]
		return {"global": global, "by_family": by_family}
	var sensor := sensor_by_id(sensor_id)
	if sensor.is_empty() and not _global_commands().has(sensor_id):
		return _fail("unknown_device", "no device with id '%s'" % sensor_id)
	if _global_commands().has(sensor_id):
		return {"id": sensor_id, "commands": _global_commands()[sensor_id]}
	return {"id": sensor_id, "commands": _commands_for(sensor_id, sensor.get("node") as Node)}

func _global_commands() -> Dictionary:
	return {
		"WEATHER": {"set": "value: " + ", ".join(PackedStringArray(WEATHERS))},
		"CLOCK": {"set_time": "value: minute of day 0-1439 or 'HH:MM'", "set_speed": "value: simulation speed 1-8", "set_rate": "value: clock seconds per simulated second",
			"pause": "pause SUMO and the city", "resume": "resume SUMO and the city"},
		"UTILITY": {"auto_recharge_on": "turn automatic energy recharge on", "auto_recharge_off": "turn automatic energy recharge off", "recharge_all": "refill every utility reserve now"},
		"CAMERA": {"view": "value: a street camera id such as CAM-A.4, overview, street, reset or city", "follow": "value: person or car (random one), or a citizen/vehicle id"},
		"HIGHLIGHT": {"show": "value: an asset kind (see ui_state.highlight_kinds) - frame those assets in the city", "clear": "remove the highlight"},
		"FOCUS": {"device": "value: a device id - select it and frame its physical model in the viewport"},
		"VIEWPORT": {"full": "make the simulation canvas fill the Godot window", "panel": "restore the control-room panels"},
		"FACTORIES": {"auto": "every factory works in shifts with short breaks", "on": "every factory runs without a break", "off": "shut every factory down"},
		"LIGHTS": {"on": "force every street light on", "off": "force every street light off", "auto": "return every street light to the adaptive schedule", "dim": "value: 0.0-1.0 output scale for every street light"},
		"REPLAY": {"play": "value: incident id", "stop": "stop", "pause":"pause playback", "resume":"resume playback", "restart":"seek to the beginning", "seek":"value: seconds", "speed":"value: 0.25-4", "camera":"value: orbit, chase, driver, street or overhead"},
		"SECTORS": {"show": "value: a sector letter, a list of letters or \"ALL\" - show the sector tint and letter on the ground", "hide": "value: the same - hide them (all are hidden by default)"},
		"EARTHQUAKE": {"trigger": "value: {\"sector\": \"A\"..\"P\" or \"ALL\", \"magnitude\": 4.0-8.0}", "clear": "remove every earthquake and restore every collapsed building"},
		"INCIDENTS": {"trigger": "value: incident kind (rear_end, red_light_tbone, unsafe_overtake, breakdown, vehicle_fire, lost_load, building_fire, water_main_break, signal_failure, garbage_collection)",
			"resolve_all": "fast-forward every open incident", "resolve":"value: incident id", "watch":"value: incident id", "dispatch":"value: {id, kind: police|ambulance|fire|tow}",
			"decide": "value: {incident, decisions: [{request, ask, action: unit|mutual_aid|hold|decline, unit}]} - the City Brain's answer to dispatch requests",
			"decisions": "value: {mode: external|auto, lease_s} - who chooses responding units (the partner gateway renews external)"},
	}

func _commands_for(sensor_id: String, _node: Node) -> Dictionary:
	match family_of(sensor_id):
		"power_switch": return {"open": "open the switch (isolate its feeder)", "close": "close the switch (energise its feeder)"}
		"water_valve", "irrigation": return {"open": "open the valve", "close": "close the valve"}
		"lighting": return {"on": "force the luminaire on", "off": "force the luminaire off", "auto": "return to the adaptive night schedule", "dim": "value: 0.0-1.0 output scale"}
		"sector_service": return {"cut_power": "cut the sector's power", "restore_power": "restore the sector's power", "cut_water": "cut the sector's water", "restore_water": "restore the sector's water"}
		"waste": return {"empty": "send a crew to empty the bin (weight returns to the liner residue)"}
		"factory": return {"auto": "work in shifts with short breaks", "on": "run without a break", "off": "shut down: no emissions"}
		"parking": return {"auto": "barrier opens for arriving cars while there is room", "open": "admit every arriving car while there is room", "closed": "keep the barrier shut: arriving cars are turned away"}
	return {}

func command(target: String, action: String, value: Variant = null) -> Dictionary:
	if target.is_empty() or action.is_empty():
		return _fail("bad_request", "command needs an 'id' and a 'command'")
	var env := _environment()
	_frame_cache.at_msec = -1000000
	var before := read_device(target) if not _global_commands().has(target) else {}
	match target:
		"WEATHER":
			if action != "set" or not str(value) in WEATHERS:
				return _fail("bad_value", "WEATHER set needs one of: %s" % ", ".join(PackedStringArray(WEATHERS)))
			if control_room != null and control_room.has_method("_set_weather"):
				control_room.call("_set_weather", str(value))
			elif env != null:
				if str(value) == "auto": env.call("set_automatic_weather", true)
				else: env.call("set_weather", str(value))
			_frame_cache.at_msec = -1000000
			return {"id": target, "applied": "weather -> %s" % str(value), "after": info()}
		"CLOCK":
			return _clock_command(env, action, value)
		"SECTORS":
			var overlay := city.get_node_or_null("SectorOverlay")
			if overlay == null or not action in ["show", "hide"]:
				return _fail("bad_command", "SECTORS accepts show and hide")
			var wanted: Array = []
			if value is Array:
				for item in value:
					wanted.append(str(item).to_upper())
			elif value != null:
				wanted.append(str(value).to_upper())
			for item in wanted:
				if item != "ALL" and not Sectors.is_sector(item):
					return _fail("bad_value", "sectors must be letters A to P or ALL")
			for item in wanted:
				if item == "ALL":
					overlay.call("set_all_visible", action == "show")
				else:
					overlay.call("set_sector_visible", item, action == "show")
			if control_room != null and control_room.has_method("_sync_sector_buttons"):
				control_room.call("_sync_sector_buttons")
			return {"id": target, "applied": "sectors %s %s" % [", ".join(PackedStringArray(wanted)), "shown" if action == "show" else "hidden"], "shown_sectors": overlay.call("shown_sectors")}
		"EARTHQUAKE":
			var system := _earthquakes()
			if system == null:
				return _fail("unavailable", "the earthquake system is not available")
			if action == "clear":
				return {"id": target, "applied": "earthquake damage cleaned up", "result": system.call("clear_all")}
			if action == "trigger":
				var spec := value as Dictionary if value is Dictionary else {}
				var result := system.call("trigger", str(spec.get("sector", "ALL")), float(spec.get("magnitude", 6.0))) as Dictionary
				if result.has("error"):
					return result
				return {"id": target, "applied": "earthquake %s triggered" % result.id, "earthquake": result}
			return _fail("bad_command", "EARTHQUAKE accepts trigger and clear")
		"INCIDENTS":
			var manager := _incident_manager()
			if manager == null:
				return _fail("unavailable", "the incident system is not available")
			if action == "resolve_all":
				manager.link.call("send", {"action": "resolve_all"})
				return {"id": target, "applied": "resolve all incidents requested"}
			if action == "resolve":
				manager.link.call("send", {"action":"resolve", "incident":str(value)})
				return {"id":target, "applied":"resolve %s requested" % str(value)}
			if action == "dispatch":
				var dispatch := value as Dictionary if value is Dictionary else {}
				var unit_kind := str(dispatch.get("kind", ""))
				if str(dispatch.get("id", "")).is_empty() or not unit_kind in ["police", "ambulance", "fire", "tow"]:
					return _fail("bad_value", "dispatch needs {id, kind: police|ambulance|fire|tow}")
				manager.link.call("send", {"action":"dispatch_extra", "incident":str(dispatch.id), "kind":unit_kind})
				return {"id":target, "applied":"extra %s dispatched to %s" % [unit_kind, str(dispatch.id)]}
			if action == "watch":
				if control_room == null or not control_room.has_method("api_watch_incident"):
					return _fail("unavailable", "the control room is not attached")
				var watched := control_room.call("api_watch_incident", str(value)) as Dictionary
				if watched.has("error"): return watched
				return {"id":target, "applied":"viewport watching %s" % str(value), "ui":watched}
			if action == "trigger":
				var kind := str(value) if value is String else str((value as Dictionary).get("kind", "")) if value is Dictionary else ""
				if kind.is_empty():
					return _fail("bad_value", "INCIDENTS trigger needs an incident kind")
				var trigger_params := {"source": "device_api"}
				if value is Dictionary and not str((value as Dictionary).get("label", "")).is_empty():
					trigger_params["label"] = str((value as Dictionary).label).left(80)
				if kind == "building_fire":
					# A building fire needs a building with road access: chosen the way the panel's button chooses one.
					var panel: Node = control_room.get("_incident_panel") as Node if control_room != null else null
					var building: Node3D = panel.call("_random_building") as Node3D if panel != null else null
					if building == null:
						return _fail("unavailable", "no building with road access was found for the fire")
					trigger_params["building"] = panel.call("_building_address", building)
				var request := str(manager.link.call("send", {"action": "trigger", "type": kind, "params": trigger_params}))
				return {"id": target, "applied": "incident %s requested" % kind, "request": request}
			if action == "decide":
				# The City Brain's answers: which unit answers each emergency call of one incident.
				var answer := value as Dictionary if value is Dictionary else {}
				if str(answer.get("incident", "")).is_empty() or not answer.get("decisions") is Array or (answer.decisions as Array).is_empty():
					return _fail("bad_value", "decide needs {incident, decisions: [{request, ask, action, unit}]}")
				var decide_request := str(manager.link.call("send", {"action": "decide", "incident": str(answer.incident), "decisions": answer.decisions}))
				return {"id": target, "applied": "decisions for %s sent" % str(answer.incident), "request": decide_request}
			if action == "decisions":
				# Who chooses responding units: "external" (the City Brain, renewed as a lease) or "auto" (the twin itself).
				var mode_value := value as Dictionary if value is Dictionary else {"mode": str(value)}
				var mode := "external" if str(mode_value.get("mode", "auto")) == "external" else "auto"
				var mode_request := str(manager.link.call("send", {"action": "decision_mode", "mode": mode, "lease_s": float(mode_value.get("lease_s", 6.0))}))
				return {"id": target, "applied": "decisions %s" % mode, "request": mode_request}
			return _fail("bad_command", "INCIDENTS accepts trigger, resolve_all, resolve, dispatch, watch, decide and decisions")
		"UTILITY":
			var utilities := city.get_node_or_null("UtilityResources")
			if utilities == null or not action in ["auto_recharge_on", "auto_recharge_off", "recharge_all"]:
				return _fail("bad_command", "UTILITY supports auto_recharge_on / auto_recharge_off / recharge_all")
			if action == "recharge_all":
				if control_room != null and control_room.has_method("api_recharge"):
					control_room.call("api_recharge")
				else:
					utilities.call("recharge_all")
			else:
				utilities.call("set_auto_recharge_enabled", action == "auto_recharge_on")
			return {"id": target, "applied": action}
		"CAMERA", "HIGHLIGHT":
			if control_room == null or not control_room.has_method("api_camera"):
				return _fail("unavailable", "the control room is not attached")
			var shown: Dictionary
			if target == "CAMERA" and action == "view":
				var view := str(value)
				if view.to_upper().begins_with("CAM-"):
					public_id("")
					if not _internal_ids.has(view.to_upper()):
						return _fail("bad_value", "no street camera '%s' (see read_all with family camera)" % view)
					view = str(_internal_ids[view.to_upper()])
				shown = control_room.call("api_camera", view) as Dictionary
			elif target == "CAMERA" and action == "follow":
				var who := str(value)
				shown = control_room.call("api_follow", who if who in ["person", "car"] else "", "" if who in ["person", "car"] else who) as Dictionary
			elif target == "HIGHLIGHT" and action in ["show", "clear"]:
				shown = control_room.call("api_highlight", str(value) if action == "show" else "clear") as Dictionary
			else:
				return _fail("bad_command", "%s does not accept '%s'" % [target, action])
			if shown.has("error"):
				return shown
			return {"id": target, "applied": "%s %s" % [action, str(value) if value != null else ""], "ui": shown}
		"FOCUS":
			if action != "device" or control_room == null or not control_room.has_method("api_focus_device"):
				return _fail("bad_command", "FOCUS accepts device when the control room is attached")
			var focused := control_room.call("api_focus_device", str(value)) as Dictionary
			if focused.has("error"): return focused
			return {"id":target, "applied":"focused device %s" % str(value), "ui":focused}
		"VIEWPORT":
			if not action in ["full", "panel"] or control_room == null or not control_room.has_method("api_set_view_only"):
				return _fail("bad_command", "VIEWPORT accepts full and panel when the control room is attached")
			var layout := control_room.call("api_set_view_only", action == "full") as Dictionary
			return {"id":target, "applied":"viewport layout %s" % action, "ui":layout}
		"FACTORIES":
			var plants := _factories()
			if plants == null or not bool(plants.call("set_mode", "", action)):
				return _fail("bad_command", "FACTORIES accepts auto, on and off")
			_frame_cache.at_msec = -1000000
			return {"id": target, "applied": "every factory -> %s" % action}
		"LIGHTS":
			if not action in ["on", "off", "auto", "dim"]:
				return _fail("bad_command", "LIGHTS accepts on, off, auto and dim")
			if action == "dim" and not (value is float or value is int):
				return _fail("bad_value", "dim needs a number from 0.0 to 1.0")
			var changed := 0
			for sensor_entry in sensors():
				var entry := sensor_entry as Dictionary
				if family_of(str(entry.id)) != "lighting":
					continue
				var light := entry.get("node") as Node3D
				if light == null:
					continue
				if action == "dim":
					light.set_meta("light_dim", clampf(float(value), 0.0, 1.0))
				else:
					light.set_meta("light_mode", action)
				changed += 1
			if env != null:
				env.call("_apply_environment")
			return {"id": target, "applied": "%d street lights -> %s" % [changed, action], "lights": changed}
		"REPLAY":
			var replay_manager := _incident_manager()
			if replay_manager == null or replay_manager.get("replay") == null:
				return _fail("unavailable", "the incident replay is not available")
			if action == "stop":
				replay_manager.replay.call("stop")
				return {"id": target, "applied": "replay stopped"}
			if action == "play":
				var camera := city.get_viewport().get_camera_3d()
				if not bool(replay_manager.replay.call("play", str(value), camera)):
					return _fail("no_clip", "no recorded collision for '%s'" % str(value))
				return {"id": target, "applied": "replaying %s" % str(value)}
			if action == "pause" or action == "resume":
				replay_manager.replay.set("paused", action == "pause")
			elif action == "restart":
				replay_manager.replay.call("seek", 0.0)
				replay_manager.replay.set("paused", false)
			elif action == "seek" and (value is float or value is int):
				replay_manager.replay.call("seek", maxf(0.0, float(value)))
			elif action == "speed" and (value is float or value is int) and float(value) >= 0.25 and float(value) <= 4.0:
				replay_manager.replay.set("playback_speed", float(value))
			elif action == "camera" and str(value) in ["orbit", "chase", "driver", "street", "overhead"]:
				replay_manager.replay.set("camera_mode", str(value))
			else:
				return _fail("bad_command", "REPLAY accepts play, stop, pause, resume, restart, seek, speed and camera")
			return {"id":target, "applied":"replay %s %s" % [action, str(value) if value != null else ""]}
	var sensor := sensor_by_id(target)
	if sensor.is_empty():
		return _fail("unknown_device", "no device with id '%s' (use list_devices to see ids)" % target)
	var commands := _commands_for(target, sensor.get("node") as Node)
	if not commands.has(action):
		return _fail("bad_command", "%s does not accept '%s' (accepts: %s)" % [target, action, ", ".join(PackedStringArray(commands.keys())) if not commands.is_empty() else "no commands: it is a read-only sensor"])
	var node := sensor.get("node") as Node3D
	var applied := ""
	match family_of(target):
		"power_switch":
			var grid := city.get_node_or_null("PowerGrid")
			if grid == null or node == null:
				return _fail("unavailable", "power grid is not available")
			grid.call("set_switch_enabled", node.name, action == "close")
			node.set_meta("switch_closed", action == "close")
			applied = "%s %s" % [node.name, "closed" if action == "close" else "opened"]
		"water_valve", "irrigation":
			node.set_meta("valve_open", action == "open")
			_tint_indicator(node, action == "open")
			applied = "%s %s" % [node.name, "opened" if action == "open" else "closed"]
		"lighting":
			if action == "dim":
				if not (value is float or value is int):
					return _fail("bad_value", "dim needs a number from 0.0 to 1.0")
				node.set_meta("light_dim", clampf(float(value), 0.0, 1.0))
				applied = "%s output scale %.2f" % [node.name, clampf(float(value), 0.0, 1.0)]
			else:
				node.set_meta("light_mode", action)
				applied = "%s mode %s" % [node.name, action]
			if env != null:
				env.call("_apply_environment")
		"sector_service":
			var utilities := city.get_node_or_null("UtilityResources")
			if utilities == null:
				return _fail("unavailable", "utility system is not available")
			var cluster := target.trim_prefix("SEC-")
			var kind := "power" if action.ends_with("power") else "water"
			utilities.call("set_manual_%s_cluster" % kind, cluster, action.begins_with("cut"))
			applied = "%s %s for %s" % [kind, "cut" if action.begins_with("cut") else "restored", cluster]
		"waste":
			var removed := BinWeight.empty(node)
			applied = "%s emptied (%.2f kg removed)" % [target, removed]
		"factory":
			_factories().call("set_mode", target, action)
			applied = "%s -> %s" % [target, action]
		"parking":
			if control_room == null or not control_room.has_method("_send_bridge"):
				return _fail("unavailable", "the traffic bridge is not connected")
			control_room.call("_send_bridge", {"command": "parking", "lot": target, "mode": action})
			var lots_node := _parking()
			if lots_node != null:
				lots_node.call("note_mode", target, action)
			applied = "%s barrier set to %s" % [target, action]
	_frame_cache.at_msec = -1000000
	return {"id": target, "applied": applied, "before": (before.get("readings", {}) as Dictionary), "after": (read_device(target).get("readings", {}) as Dictionary)}

func _clock_command(env: Node, action: String, value: Variant) -> Dictionary:
	if env == null:
		return _fail("unavailable", "environment system is not available")
	match action:
		"set_time":
			var minute := -1
			if value is String and (value as String).contains(":"):
				var parts := (value as String).split(":")
				if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
					minute = int(parts[0]) * 60 + int(parts[1])
			elif value is float or value is int:
				minute = int(value)
			if minute < 0 or minute > 1439:
				return _fail("bad_value", "set_time needs a minute of day 0-1439 or 'HH:MM'")
			if control_room != null and control_room.has_method("_set_time_of_day"):
				control_room.call("_set_time_of_day", minute)
			else:
				env.call("set_time_of_day", minute)
		"set_speed":
			if not (value is float or value is int) or float(value) < 1.0 or float(value) > 8.0:
				return _fail("bad_value", "set_speed needs a number from 1 to 8")
			if control_room != null and control_room.has_method("_set_simulation_speed"):
				control_room.call("_set_simulation_speed", float(value))
			else:
				env.call("set_simulation_speed", float(value))
		"set_rate":
			if not (value is float or value is int) or float(value) <= 0.0:
				return _fail("bad_value", "set_rate needs a positive number")
			if control_room != null and control_room.has_method("_set_clock_rate"):
				control_room.call("_set_clock_rate", float(value))
			else:
				env.call("set_clock_rate", float(value))
		"pause", "resume":
			_send_sumo(action)
		_:
			return _fail("bad_command", "CLOCK accepts set_time, set_speed, set_rate, pause, resume")
	_frame_cache.at_msec = -1000000
	return {"id": "CLOCK", "applied": "%s %s" % [action, str(value) if value != null else ""], "after": info()}

func _send_sumo(command_name: String) -> void:
	if control_room != null and control_room.has_method("_send_sumo_command"):
		control_room.call("_send_sumo_command", command_name)
		return
	var env := _environment()
	if env != null:
		env.call("_send_command", {"command": command_name})

func _tint_indicator(valve: Node3D, open: bool) -> void:
	var indicator := valve.get_node_or_null("Indicator") as MeshInstance3D
	if indicator == null or not indicator.material_override is StandardMaterial3D:
		return
	var material := (indicator.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
	var colour := Color(0.1, 0.95, 0.35) if open else Color(1.0, 0.18, 0.12)
	material.albedo_color = colour
	material.emission_enabled = true
	material.emission = colour
	indicator.material_override = material
