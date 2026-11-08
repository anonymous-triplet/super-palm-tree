extends SceneTree

## Live check of the whole call story against a running SUMO bridge (default ports): a rear-end crash is triggered through
## the device API; the people involved must climb out of their vehicles, stand well away from the wreckage, and each phone
## call must show the calling badge while it lasts. Frames and the event log are written to OUTPUT_DIR.
## godot --display-driver x11 --script tests/render_incident_calls.gd  (start scripts/sumo_bridge.py first)

const OUTPUT_DIR := "/tmp/city_incident_calls"
const SAFE_MINIMUM := 6.0

var _room: Node
var _api: Node
var _city: Node3D
var _manager: Node
var _shots := 0

func _init() -> void:
	call_deferred("_run")

func _ask(method: String, params := {}) -> Dictionary:
	return _api.call("handle_request", {"id": 1, "method": method, "params": params}) as Dictionary

func _fail(message: String) -> void:
	push_error("INCIDENT CALLS TEST FAILED: " + message)
	print("INCIDENT CALLS TEST FAILED: " + message)
	quit(1)

func _shot(label: String, focus: Vector3, from_offset := Vector3(6.5, 3.2, 7.5)) -> void:
	var camera := _city.get_node("EstablishingCamera") as Camera3D
	camera.call("_clear_target_follow")
	camera.look_at_from_position(focus + from_offset, focus + Vector3(0, 1.4, 0), Vector3.UP)
	for unused in 4:
		await process_frame
	_shots += 1
	(_room.get("_city_viewport") as SubViewport).get_texture().get_image().save_png("%s/%02d_%s.png" % [OUTPUT_DIR, _shots, label])

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	_room = (load("res://scenes/ControlRoom.tscn") as PackedScene).instantiate()
	root.add_child(_room)
	for i in 150:
		await process_frame
	_api = _room.get("_sim_api")
	_city = _room.get("_city") as Node3D
	_manager = _city.get_node("Incidents")
	_ask("command", {"id": "CLOCK", "command": "set_speed", "value": 4})
	var triggered := _ask("command", {"id": "INCIDENTS", "command": "trigger", "value": "rear_end"})
	if not bool(triggered.ok):
		_fail("could not trigger the incident: " + JSON.stringify(triggered))
		return
	var presenter := _manager.get("scene_presenter") as Node
	var seen_ringing := false
	var seen_icon := false
	var min_distance := INF
	var wreck_shot := false
	var phone_shot := false
	var deadline := Time.get_ticks_msec() + 150000
	var last_log := ""
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.4, true, false, true).timeout
		var incidents := (_ask("list_incidents").result as Dictionary).incidents as Array
		if incidents.is_empty():
			if seen_ringing:
				break
			continue
		var record := incidents[0] as Dictionary
		var scene := presenter.get("scenes").get(str(record.id), {}) as Dictionary
		if scene.is_empty():
			continue
		var wreck_centre := Vector3.ZERO
		var wrecks := 0
		for vehicle_value in scene.layout_vehicles as Array:
			var vehicle := vehicle_value as Dictionary
			if str(vehicle.kind) == "wreck":
				wreck_centre += vehicle.centre as Vector3
				wrecks += 1
		if wrecks == 0:
			continue
		wreck_centre /= float(wrecks)
		for key in (scene.drivers as Dictionary).keys():
			var state := (scene.drivers as Dictionary)[key] as Dictionary
			if not is_instance_valid(state.get("agent")) or bool(state.get("boarded", false)):
				continue
			var agent := state.agent as Node
			var body := agent.get("body") as Node3D
			var at_phone_step := int(state.step) < (state.program as Array).size() and ((state.program as Array)[int(state.step)] as Dictionary).has("phone")
			var distance := body.global_position.distance_to(wreck_centre)
			if at_phone_step:
				min_distance = minf(min_distance, distance)
				if not wreck_shot:
					wreck_shot = true
					await _shot("standing_clear_of_the_wreck", wreck_centre, Vector3(0.0, 9.0, 16.0))
			var icon := body.get_node_or_null("CallIcon")
			if icon != null and bool(icon.call("is_showing")):
				seen_icon = true
				if not phone_shot:
					phone_shot = true
					await _shot("calling_badge", body.global_position)
		for call_value in record.get("calls", []):
			seen_ringing = seen_ringing or str((call_value as Dictionary).get("state", "")) in ["ringing", "talking"]
		var log_text := "\n".join((_room.get("_events") as Array).slice(0, 14))
		if log_text != last_log:
			last_log = log_text
		if wreck_shot and phone_shot and (record.get("calls", []) as Array).size() >= 3 and (record.get("calls", []) as Array).all(func(call: Dictionary) -> bool: return str(call.state) == "done"):
			break
	var file := FileAccess.open("%s/event_log.txt" % OUTPUT_DIR, FileAccess.WRITE)
	file.store_string(last_log)
	file.close()
	print("INCIDENT_CALLS|ringing_seen=%s|badge_seen=%s|closest_standing_distance=%.1f|shots=%d" % [seen_ringing, seen_icon, min_distance, _shots])
	print(last_log)
	if not seen_ringing or not seen_icon:
		_fail("no call was ever shown")
		return
	if min_distance < SAFE_MINIMUM:
		_fail("a caller stood only %.1f m from the wreckage" % min_distance)
		return
	quit(0)
