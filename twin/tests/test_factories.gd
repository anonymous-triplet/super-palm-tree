extends SceneTree

## Factories sit on the outermost ring of blocks; they work in shifts with short breaks; their clouds rise, drift with the wind,
## spread, and vanish; the air-quality monitors in the factory's own sector read the worst air and those in neighbouring sectors a
## weaker version of it; a stopped factory's air clears; rain washes it out; a collapsed factory stops; the device API and modes work.

const Sectors := preload("res://scripts/city_sectors.gd")

var _api: Node

func _init() -> void:
	call_deferred("_run")

func _fail(message: String) -> void:
	push_error("FACTORY TEST FAILED: " + message)
	print("FACTORY TEST FAILED: " + message)
	quit(1)

func _ask(method: String, params := {}) -> Dictionary:
	return _api.call("handle_request", {"id": 1, "method": method, "params": params}) as Dictionary

func _air(sector: String) -> Dictionary:
	for row in (_ask("air_report").result as Dictionary).sectors:
		if str((row as Dictionary).sector) == sector:
			return row as Dictionary
	return {}

func _neighbours_of(sector: String) -> Array:
	return Sectors.neighbours(sector)

func _run() -> void:
	var room := (load("res://scenes/ControlRoom.tscn") as PackedScene).instantiate()
	root.add_child(room)
	for i in 120:
		await process_frame
	_api = room.get("_sim_api")
	_api.set("snapshot_ttl_ms", 0)
	var city := room.get("_city") as Node3D
	var system := city.get_node("Factories")
	var factories := system.get("factories") as Array
	if factories.size() != 2:
		_fail("%d factories, expected two" % factories.size())
		return
	# Opposite sides: the two compounds mirror each other through the city centre.
	if ((factories[0] as Dictionary).centre as Vector3 + (factories[1] as Dictionary).centre as Vector3).length() > 1.0:
		_fail("the factories are not on opposite sides of the city")
		return
	var sectors := {}
	for value in factories:
		var factory := value as Dictionary
		var centre := factory.centre as Vector3
		# Edge blocks: inside the 8 x 8 grid, in its outermost ring, not beyond it.
		if maxf(absf(centre.x), absf(centre.z)) != 332.5:
			_fail("%s at %s is not on an edge block" % [factory.id, centre])
			return
		sectors[str(factory.sector)] = true
		if (factory.stacks as Array).size() < 2:
			_fail("%s has too few stacks" % factory.id)
			return
	if sectors.size() != factories.size():
		_fail("two factories share a sector")
		return
	if int((_ask("list_buildings", {"limit": 1}).result as Dictionary).total) != 224:
		_fail("the factories changed the number of buildings")
		return
	var report := _ask("air_report").result as Dictionary
	if (report.sectors as Array).size() != 16:
		_fail("%d of 16 sectors have an air monitor" % (report.sectors as Array).size())
		return
	# Shifts: over twenty minutes every factory breaks, and spends far more time working than resting.
	var worked := {}
	var rested := {}
	for step in 2400:
		system.call("simulate", 0.5)
		for value in factories:
			var factory := value as Dictionary
			if bool(factory.emitting):
				worked[factory.id] = int(worked.get(factory.id, 0)) + 1
			else:
				rested[factory.id] = int(rested.get(factory.id, 0)) + 1
	for value in factories:
		var factory_id := str((value as Dictionary).id)
		if int(rested.get(factory_id, 0)) == 0 or int(worked.get(factory_id, 0)) < int(rested.get(factory_id, 0)) * 2:
			_fail("%s worked %d and rested %d half-seconds" % [factory_id, int(worked.get(factory_id, 0)), int(rested.get(factory_id, 0))])
			return
	# One factory alone: on-site worst, neighbours weaker but clearly raised, far side near clean.
	var source := factories[0] as Dictionary
	system.call("set_mode", "", "off")
	system.call("simulate", 500.0)
	var clean := float(_air(str(source.sector)).pm2_5)
	if (system.get("puffs") as Array).size() != 0:
		_fail("clouds did not all vanish after the factories stopped")
		return
	system.call("set_mode", str(source.id), "on")
	system.call("simulate", 150.0)
	var on_site := float(_air(str(source.sector)).pm2_5)
	var neighbours := Sectors.neighbours(str(source.sector))
	var nearby := 0.0
	for sector in neighbours:
		var reading := float(_air(str(sector)).pm2_5)
		nearby = maxf(nearby, reading)
		if reading >= on_site:
			_fail("neighbour %s reads %.1f, not below the factory sector %s at %.1f" % [sector, reading, source.sector, on_site])
			return
	var far_sector := "P" if str(source.sector) in ["A", "B", "E", "F"] else "A" if str(source.sector) in ["K", "L", "O", "P"] else "M"
	var far := float(_air(far_sector).pm2_5)
	if on_site < clean + 40.0:
		_fail("the factory sector barely reacted: %.1f from %.1f" % [on_site, clean])
		return
	if nearby < clean + 12.0:
		_fail("neighbouring sectors did not notice: %.1f from %.1f" % [nearby, clean])
		return
	if far > nearby:
		_fail("far sector %s reads %.1f, above the neighbours at %.1f" % [far_sector, far, nearby])
		return
	if str(_air(str(source.sector)).category) == "good":
		_fail("the factory sector still reports good air at PM2.5 %.1f" % on_site)
		return
	# Clouds rise, drift downwind, grow; the oldest are well away from the stack.
	var puffs := (system.get("puffs") as Array).filter(func(puff: Dictionary) -> bool: return not bool(puff.jet))
	if puffs.size() < 10:
		_fail("only %d clouds from a running factory" % puffs.size())
		return
	var oldest := puffs[0] as Dictionary
	var youngest := puffs[puffs.size() - 1] as Dictionary
	var travelled := Vector2((oldest.position as Vector3).x - (source.centre as Vector3).x, (oldest.position as Vector3).z - (source.centre as Vector3).z).length()
	if travelled < 150.0 or float(oldest.radius) <= float(youngest.radius) * 2.0 or (oldest.position as Vector3).y <= (youngest.position as Vector3).y:
		_fail("clouds do not drift and spread: %.0f m, radius %.0f vs %.0f" % [travelled, oldest.radius, youngest.radius])
		return
	# Rain washes the air.
	var env := city.get_node("EnvironmentSystem")
	env.call("set_weather", "storm")
	if float(_air(str(source.sector)).pm2_5) >= on_site - 10.0:
		_fail("rain did not wash the air")
		return
	env.call("set_weather", "clear")
	# A collapsed factory stops emitting.
	var stack := ((source.stacks as Array)[0] as Dictionary).building as Node3D
	stack.set_meta("collapsed", true)
	system.call("simulate", 1.0)
	if bool(source.emitting):
		_fail("a collapsed factory keeps emitting")
		return
	stack.remove_meta("collapsed")
	# Device API and commands.
	var device := _ask("read", {"id": str(source.id)})
	if not bool(device.ok) or not (device.result.readings as Dictionary).has("emission_rate") or str(device.result.get("kind", "actuator")) == "sensor":
		_fail("factory device: " + JSON.stringify(device).substr(0, 300))
		return
	if not bool(_ask("command", {"id": str(source.id), "command": "off"}).ok) or str(source.mode) != "off" or bool(_ask("command", {"id": str(source.id), "command": "explode"}).ok):
		_fail("factory commands")
		return
	if not bool(_ask("command", {"id": "FACTORIES", "command": "auto"}).ok) or str((factories[1] as Dictionary).mode) != "auto":
		_fail("FACTORIES auto")
		return
	system.call("simulate", 400.0)
	var air := _ask("read", {"id": str(_api.call("public_id", "AIR-01"))})
	if not (air.result.readings as Dictionary).has("air_quality_index") or not (air.result.readings as Dictionary).has("sulphur_dioxide"):
		_fail("monitors do not report AQI and SO2")
		return
	print("FACTORY TEST PASSED: %d factories on edge blocks, PM2.5 %.1f clean -> %.1f on site, %.1f next door, %.1f far away" % [factories.size(), clean, on_site, nearby, far])
	quit(0)
