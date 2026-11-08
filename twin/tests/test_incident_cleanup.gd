extends SceneTree

## An incident must end: after the wrecks are cleared, every responder and driver boards and the scene reports itself empty,
## so the incident resolves on its own (no supervisor timeout). Runs one incident kind against a live SUMO bridge on the
## default ports, at 4x speed, and prints who is still out if the cleanup stalls.
##     python3 src/scripts/sumo_bridge.py --rate 15 &   then   godot --path src --script tests/test_incident_cleanup.gd -- red_light_tbone

const LIMIT_SECONDS := 420.0

var _room: Node
var _api: Node
var _city: Node3D
var _manager: Node

func _init() -> void:
	call_deferred("_run")

func _ask(method: String, params := {}) -> Dictionary:
	return _api.call("handle_request", {"id": 1, "method": method, "params": params}) as Dictionary

func _run() -> void:
	var kind := "red_light_tbone"
	for argument in OS.get_cmdline_user_args():
		kind = argument
	_room = (load("res://scenes/ControlRoom.tscn") as PackedScene).instantiate()
	root.add_child(_room)
	for i in 150:
		await process_frame
	_api = _room.get("_sim_api")
	_city = _room.get("_city") as Node3D
	_manager = _city.get_node("Incidents")
	_ask("command", {"id": "CLOCK", "command": "set_speed", "value": 4})
	_ask("command", {"id": "INCIDENTS", "command": "trigger", "value": kind})
	var started := Time.get_ticks_msec()
	var incident_id := ""
	var cleanup_since := -1
	var seen_notes := {}
	while Time.get_ticks_msec() - started < LIMIT_SECONDS * 1000.0:
		await create_timer(1.0, true, false, true).timeout
		var listed := _ask("list_incidents").get("result", {}) as Dictionary
		var open := listed.get("incidents", []) as Array
		if incident_id.is_empty() and not open.is_empty():
			incident_id = str((open[0] as Dictionary).id)
		var record := {}
		for value in open:
			if str((value as Dictionary).id) == incident_id:
				record = value as Dictionary
		for note in record.get("timeline", []):
			var key := "%s|%s" % [str((note as Dictionary).t), str((note as Dictionary).text)]
			if not seen_notes.has(key):
				seen_notes[key] = true
				print("  %6.1f  %s" % [float((note as Dictionary).t), str((note as Dictionary).text)])
		if not incident_id.is_empty() and record.is_empty():
			var supervised := false
			for key in seen_notes:
				supervised = supervised or str(key).contains("supervisor")
			var unconfirmed := false
			for key in seen_notes:
				unconfirmed = unconfirmed or str(key).contains("not confirmed in time")
			if unconfirmed:
				print("INCIDENT CLEANUP TEST FAILED: %s %s: the scene never reported itself empty" % [kind, incident_id])
				quit(1)
				return
			if supervised:
				print("(the scene ran past its normal duration and the supervisor ordered it cleared)")
			print("INCIDENT CLEANUP TEST PASSED: %s %s resolved on its own in %.0f s" % [kind, incident_id, (Time.get_ticks_msec() - started) / 1000.0])
			quit(0)
			return
		for participant_value in record.get("participants", []):
			var participant := participant_value as Dictionary
			if str(participant.get("status", "")) == "loading" and OS.get_environment("CGZ_DEBUG_WINCH") == "1":
				var life := _city.get_node("CityLife")
				var Layout := load("res://scripts/incidents/scene_layout.gd")
				print("loading %s tow=%s tow_keyed=%s wreck_pose_empty=%s" % [participant.id, participant.get("tow"), life.call("has_keyed_vehicle", str(participant.get("tow", ""))),
					(Layout.call("vehicle_pose", life, str(participant.id)) as Dictionary).is_empty()])
		if str(record.get("phase", "")) == "cleanup":
			if cleanup_since < 0:
				cleanup_since = Time.get_ticks_msec()
			elif Time.get_ticks_msec() - cleanup_since > 110000:
				_dump(incident_id)
				print("INCIDENT CLEANUP TEST FAILED: %s %s stuck in cleanup" % [kind, incident_id])
				quit(1)
				return
	print("INCIDENT CLEANUP TEST FAILED: %s did not finish in %.0f s" % [kind, LIMIT_SECONDS])
	quit(1)

func _dump(incident_id: String) -> void:
	var presenter := _manager.get("scene_presenter") as Node
	var scenes := presenter.get("scenes") as Dictionary
	var scene := scenes.get(incident_id, {}) as Dictionary
	print("scene keys: ", scene.keys())
	print("operational_cleanup=%s cleanup_reported=%s closing=%s" % [scene.get("operational_cleanup"), scene.get("cleanup_reported"), scene.get("closing")])
	for unit_id in (scene.get("crews", {}) as Dictionary):
		var crew := (scene.crews as Dictionary)[unit_id] as Dictionary
		for agent_state_value in crew.agents:
			var agent_state := agent_state_value as Dictionary
			print("crew %s %s step=%s program=%s boarded=%s valid=%s transit=%s alighting=%s" % [unit_id, agent_state.get("role"), agent_state.get("step"), agent_state.get("program"),
				agent_state.get("boarded"), is_instance_valid(agent_state.get("agent")), agent_state.get("boarding_transit"), agent_state.get("alighting")])
	for vehicle_id in (scene.get("drivers", {}) as Dictionary):
		var driver := (scene.drivers as Dictionary)[vehicle_id] as Dictionary
		print("driver %s step=%s program=%s boarded=%s valid=%s transit=%s alighting=%s leaving=%s" % [vehicle_id, driver.get("step"), driver.get("program"), driver.get("boarded"),
			is_instance_valid(driver.get("agent")), driver.get("boarding_transit"), driver.get("alighting"), driver.get("leaving")])
