extends SceneTree

## Real citizens interrupt their current lives for a local earthquake or building fire, leave by the
## sidewalk network with staggered reactions, retain their identities, and resume their agendas.

const Sectors := preload("res://scripts/city_sectors.gd")

func _init() -> void:
	call_deferred("_run")

func _fail(message: String) -> void:
	push_error("CITIZEN EVACUATION TEST FAILED: " + message)
	print("CITIZEN EVACUATION TEST FAILED: " + message)
	quit(1)

func _wait(seconds: float, scale := 1.0) -> void:
	Engine.time_scale = scale
	await create_timer(seconds / scale, true, false, true).timeout
	Engine.time_scale = 1.0

func _states(npc: Node) -> Array[Dictionary]:
	return npc.call("get_agent_debug") as Array[Dictionary]

func _run() -> void:
	var city := (load("res://scenes/City.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(city)
	for frame in 35:
		await process_frame
	await create_timer(0.6).timeout
	var npc := city.get_node("NpcAi")
	var earthquakes := city.get_node("Earthquakes")
	var initial := _states(npc)
	if initial.size() < 24:
		_fail("only %d persistent citizens were available" % initial.size())
		return
	var expected_ids := {}
	var positions := {}
	for state in initial:
		var person := state.node as Node3D
		positions[str(state.citizen_id)] = person.global_position
		if Sectors.sector_of_position(person.global_position) == "F":
			expected_ids[str(state.citizen_id)] = true
	if expected_ids.is_empty():
		_fail("the test scene has no citizens in Sector F")
		return
	var event := earthquakes.call("trigger", "F", 6.4) as Dictionary
	if event.has("error"):
		_fail("could not start the Sector F earthquake")
		return
	# Sample inside the deliberately staggered 1.05-2.29 s reaction window.
	await _wait(1.55)
	var reacting := 0
	var moving := 0
	var running := 0
	var bracing := 0
	var evacuated_ids := {}
	for state in _states(npc):
		if bool(state.evacuating):
			evacuated_ids[str(state.citizen_id)] = true
			reacting += int(str(state.evacuation_phase) == "reacting")
			moving += int(str(state.evacuation_phase) == "moving")
			running += int(str(state.evacuation_phase) == "moving" and str(state.animation_clip) == "Running")
			bracing += int(str(state.evacuation_phase) == "reacting" and str(state.animation_clip) == "EarthquakeBrace")
		elif expected_ids.has(str(state.citizen_id)):
			_fail("affected citizen %s did not react" % str(state.citizen_id))
			return
	if evacuated_ids.size() != expected_ids.size():
		_fail("Sector F selected %d citizens but %d evacuated" % [expected_ids.size(), evacuated_ids.size()])
		return
	if reacting == 0 or moving == 0:
		_fail("reactions were synchronized instead of staggered: reacting=%d moving=%d" % [reacting, moving])
		return
	if running != moving or bracing != reacting:
		_fail("earthquake choreography used generic motion: running=%d/%d bracing=%d/%d" % [running, moving, bracing, reacting])
		return
	await _wait(2.0)
	var visibly_moving := 0
	for state in _states(npc):
		if evacuated_ids.has(str(state.citizen_id)):
			var distance := (state.node as Node3D).global_position.distance_to(positions[str(state.citizen_id)] as Vector3)
			visibly_moving += int(distance > 0.7 and (float(state.speed_mps) > 1.8 or str(state.evacuation_phase) == "safe"))
	if visibly_moving < maxi(1, evacuated_ids.size() / 2):
		_fail("only %d/%d evacuees visibly moved at a brisk pace" % [visibly_moving, evacuated_ids.size()])
		return
	earthquakes.call("clear_all")
	await _wait(130.0, 8.0)
	for state in _states(npc):
		if evacuated_ids.has(str(state.citizen_id)) and bool(state.evacuating):
			_fail("%s never left emergency mode (%s route %d/%d at %s, blocked by %s)" % [str(state.citizen_id), str(state.evacuation_phase), int(state.evacuation_route_index), int(state.evacuation_route_size), str((state.node as Node3D).global_position), str(state.last_block_reason)])
			return
		if str(state.citizen_id).is_empty():
			_fail("a citizen lost their SocietyKernel identity")
			return

	# Feed the exact live incident record shape that IncidentManager receives from the bridge.
	var fire_anchor := (_states(npc)[0].node as Node3D).global_position
	var incidents := city.get_node("Incidents")
	incidents.set("last_state", {"incidents": [{
		"id": "FIRE-TEST", "kind": "building_fire", "phase": "working",
		"location": {"x": fire_anchor.x, "z": fire_anchor.z},
		"scene": {"fire": {"intensity": 0.8}},
	}]})
	await _wait(0.5)
	var fire_count := 0
	var non_fire_count := 0
	var fire_reactions := 0
	var column := clampi(floori((fire_anchor.x + 380.0) / 95.0), 0, 7)
	var row := clampi(floori((fire_anchor.z + 380.0) / 95.0), 0, 7)
	var fire_area := Rect2(-380.0 + column * 95.0, -380.0 + row * 95.0, 95.0, 95.0)
	for state in _states(npc):
		var in_block := fire_area.has_point(Vector2((state.node as Node3D).global_position.x, (state.node as Node3D).global_position.z))
		if bool(state.evacuating) and str(state.evacuation_hazard_id) == "FIRE-TEST":
			fire_count += 1
			fire_reactions += int(str(state.animation_clip) == "FireAlarmReaction")
			if not in_block:
				_fail("building fire pulled a citizen from another block")
				return
		elif not in_block:
			non_fire_count += 1
	if fire_count == 0 or non_fire_count == 0:
		_fail("building fire did not isolate one occupied block: fire=%d outside=%d" % [fire_count, non_fire_count])
		return
	if fire_reactions != fire_count:
		_fail("fire citizens did not use the captured alarm reaction: %d/%d" % [fire_reactions, fire_count])
		return
	incidents.set("last_state", {"incidents": []})
	print("CITIZEN EVACUATION TEST PASSED: %d Sector F citizens reacted asynchronously, moved on safe routes, resumed their real lives; %d citizens fled only the burning block" % [evacuated_ids.size(), fire_count])
	quit(0)
