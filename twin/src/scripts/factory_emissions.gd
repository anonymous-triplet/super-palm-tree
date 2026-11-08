extends Node3D

## The city's two factories, on edge blocks at opposite corners of the city. Each works in shifts with short breaks and, while it works, its stacks
## release gas clouds: puffs that rise, drift with the wind across the city, spread out, thin and vanish. The air they foul is
## what the air-quality monitors read through air_load_at(): a haze at full strength anywhere in the factory's own sector that
## falls off with distance from that sector, the way shaking falls off from an earthquake's sector (so neighbouring sectors read a
## weaker version of it), plus whatever part of a cloud is passing overhead. Rain washes it out. A collapsed factory stops emitting.

const Sectors := preload("res://scripts/city_sectors.gd")
const WorldTime := preload("res://scripts/world_time.gd")
const SMOG_SHADER := preload("res://shaders/factory_smog.gdshader")
const FX_LAYER := 8
const MAX_PUFFS := 620
const LOBES := 2
const BYTES_PER_INSTANCE := 20
const SMALL_STACK_HEIGHT := 1.92
const LARGE_STACK_HEIGHT := 1.70
const RUN_SECONDS := Vector2(75.0, 140.0)
const BREAK_SECONDS := Vector2(12.0, 30.0)
const PUFF_INTERVAL := [5.5, 8.0]
## The dense column right above a stack: small short-lived puffs that feed the big clouds.
const JET_INTERVAL := 0.9
const JET_LIFE := Vector2(12.0, 20.0)
const JET_END_RADIUS := Vector2(14.0, 21.0)
## A city draws air in from its edges (the urban heat island), which carries the clouds over the blocks.
const WIND_SHARE := 0.8
const INWARD_PULL := 3.0
const PUFF_LIFE := Vector2(115.0, 170.0)
const PUFF_START_RADIUS := 5.0
const PUFF_END_RADIUS := Vector2(40.0, 58.0)
const LEVEL_RISE_SECONDS := 20.0
const LEVEL_FALL_SECONDS := 35.0
## PM2.5 a factory adds across its own sector (µg/m³) and how far beyond the sector its haze reaches.
const HAZE_AT_SOURCE := 78.0
const HAZE_REACH := 60.0
const HAZE_FALLOFF := 2.2
const CLOUD_AT_GROUND := 0.3

var factories: Array[Dictionary] = []
var puffs: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _environment: Node
var _multimesh: MultiMesh
var _material: ShaderMaterial
var _buffer := PackedFloat32Array()
var _render := true
var _light_timer := 0.0


func _ready() -> void:
	_rng.seed = 7741
	_environment = get_parent().get_node_or_null("EnvironmentSystem")
	_render = DisplayServer.get_name() != "headless"
	_discover()
	if _render:
		_build_renderer()


func _discover() -> void:
	var by_id := {}
	for value in get_tree().get_nodes_in_group("factory_buildings"):
		var building := value as Node3D
		var factory_id := str(building.get_meta("factory_id", ""))
		if not by_id.has(factory_id):
			by_id[factory_id] = []
		(by_id[factory_id] as Array).append(building)
	var ids := by_id.keys()
	ids.sort()
	for factory_id in ids:
		var buildings := by_id[factory_id] as Array
		var block := (buildings[0] as Node3D).get_parent() as Node3D
		var stacks: Array[Dictionary] = []
		for value in buildings:
			var building := value as Node3D
			if str(building.get_meta("factory_part", "")) != "stack":
				continue
			stacks.append({"top": building.global_transform * Vector3(0.0, LARGE_STACK_HEIGHT, 0.0), "building": building, "next": 0.0, "jet_next": 0.0, "interval": PUFF_INTERVAL[0]})
			var second := building.get_node_or_null("SecondStack") as Node3D
			if second != null:
				stacks.append({"top": second.global_transform * Vector3(0.0, SMALL_STACK_HEIGHT, 0.0), "building": building, "next": 1.5, "jet_next": 0.3, "interval": PUFF_INTERVAL[1]})
		# Staggered so the factories do not all pause together.
		factories.append({"id": str(factory_id), "name": "Factory %s" % Sectors.block_label(block.global_position), "block": Sectors.block_label(block.global_position), "centre": block.global_position,
			"sector": Sectors.sector_of_position(block.global_position), "buildings": buildings, "stacks": stacks, "mode": "auto", "running": true, "level": 0.6,
			"phase_until": _rng.randf_range(RUN_SECONDS.x * 0.3, RUN_SECONDS.y)})


func _build_renderer() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = 91
	noise.frequency = 0.012
	noise.fractal_octaves = 4
	var texture := ImageTexture.create_from_image(noise.get_seamless_image(256, 256))
	_material = ShaderMaterial.new()
	_material.shader = SMOG_SHADER
	_material.set_shader_parameter("noise_map", texture)
	var quad := QuadMesh.new()
	quad.material = _material
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.use_custom_data = true
	_multimesh.mesh = quad
	_multimesh.instance_count = MAX_PUFFS * LOBES
	_multimesh.visible_instance_count = 0
	var instance := MultiMeshInstance3D.new()
	instance.name = "GasClouds"
	instance.multimesh = _multimesh
	instance.layers = FX_LAYER
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.custom_aabb = AABB(Vector3(-1600.0, -10.0, -1600.0), Vector3(3200.0, 500.0, 3200.0))
	add_child(instance)
	_buffer.resize(MAX_PUFFS * LOBES * BYTES_PER_INSTANCE)


func _process(delta: float) -> void:
	if _paused():
		return
	_step(delta)
	if _render:
		_draw_clouds(delta)


func simulate(seconds: float) -> void:
	## Runs the emissions forward at once (tests).
	var left := seconds
	while left > 0.0:
		_step(minf(left, 0.25))
		left -= 0.25


func _paused() -> bool:
	return WorldTime.paused


func _wind() -> Vector3:
	## Where the wind blows to (metres per second, in the ground plane), from the same values the weather stations report.
	var speed := 2.8
	var from_degrees := 210.0
	if _environment != null and _environment.has_method("get_wind"):
		var wind := _environment.call("get_wind") as Dictionary
		speed = float(wind.speed)
		from_degrees = float(wind.direction)
	var heading := deg_to_rad(from_degrees + 180.0)
	return Vector3(sin(heading), 0.0, -cos(heading)) * speed


func _washout() -> float:
	if _environment == null:
		return 0.0
	var weather := str(_environment.get("weather"))
	return 0.55 if weather == "storm" else 0.4 if weather == "rain" else 0.0


func _step(delta: float) -> void:
	for factory in factories:
		_step_factory(factory, delta)
	var wind := _wind()
	var washout := _washout()
	var index := puffs.size() - 1
	while index >= 0:
		var puff := puffs[index]
		var age := float(puff.age) + delta * (1.0 + washout)
		puff.age = age
		if age >= float(puff.life):
			puffs.remove_at(index)
			index -= 1
			continue
		var position_value := puff.position as Vector3
		var seed_value := float(puff.seed)
		var swirl := Vector3(sin(age * 0.11 + seed_value * 6.3), 0.0, cos(age * 0.09 + seed_value * 4.1)) * 1.1
		var inward := Vector3(-position_value.x, 0.0, -position_value.z).normalized() * INWARD_PULL
		position_value += (wind * WIND_SHARE + inward + swirl) * delta
		# Hot gas climbs out of the stack, then floats at its own height.
		position_value.y += (4.5 * exp(-age / 10.0) + 0.1) * delta
		puff.position = position_value
		var grown := 1.0 - exp(-age / (6.0 if bool(puff.jet) else 26.0))
		puff.radius = lerpf(PUFF_START_RADIUS, float(puff.end_radius), grown)
		index -= 1


func _step_factory(factory: Dictionary, delta: float) -> void:
	var collapsed := false
	for stack_value in factory.stacks as Array:
		collapsed = collapsed or (stack_value as Dictionary).building.has_meta("collapsed")
	var mode := str(factory.mode)
	if mode == "on":
		factory.running = true
	elif mode == "off":
		factory.running = false
	else:
		factory.phase_until = float(factory.phase_until) - delta
		if float(factory.phase_until) <= 0.0:
			factory.running = not bool(factory.running)
			var span: Vector2 = RUN_SECONDS if bool(factory.running) else BREAK_SECONDS
			factory.phase_until = _rng.randf_range(span.x, span.y)
	var emitting := bool(factory.running) and not collapsed
	factory.collapsed = collapsed
	factory.emitting = emitting
	var time_constant := LEVEL_RISE_SECONDS if emitting else LEVEL_FALL_SECONDS
	factory.level = lerpf(float(factory.level), 1.0 if emitting else 0.0, 1.0 - exp(-delta / time_constant))
	if not emitting:
		return
	for stack_value in factory.stacks as Array:
		var stack := stack_value as Dictionary
		stack.next = float(stack.next) - delta
		stack.jet_next = float(stack.jet_next) - delta
		if float(stack.next) <= 0.0:
			stack.next = float(stack.interval) * _rng.randf_range(0.85, 1.15)
			_emit(factory, stack, false)
		if float(stack.jet_next) <= 0.0:
			stack.jet_next = JET_INTERVAL * _rng.randf_range(0.8, 1.2)
			_emit(factory, stack, true)


func _emit(factory: Dictionary, stack: Dictionary, jet: bool) -> void:
	if puffs.size() >= MAX_PUFFS:
		puffs.remove_at(0)
	var life: Vector2 = JET_LIFE if jet else PUFF_LIFE
	var end_radius: Vector2 = JET_END_RADIUS if jet else PUFF_END_RADIUS
	puffs.append({"factory": str(factory.id), "jet": jet, "position": stack.top as Vector3, "age": 0.0, "life": _rng.randf_range(life.x, life.y), "radius": PUFF_START_RADIUS,
		"end_radius": _rng.randf_range(end_radius.x, end_radius.y), "seed": _rng.randf()})


# --- What the air-quality monitors read --------------------------------------------------------

func air_load_at(point: Vector3) -> float:
	## Extra PM2.5 (µg/m³) at a point on the ground.
	var total := 0.0
	var ground := Vector2(point.x, point.z)
	for factory in factories:
		var sector := Sectors.rect(str(factory.sector))
		var nearest := ground.clamp(sector.position, sector.end)
		total += float(factory.level) * HAZE_AT_SOURCE / (1.0 + pow(ground.distance_to(nearest) / HAZE_REACH, HAZE_FALLOFF))
	for puff in puffs:
		if bool(puff.jet):
			continue
		var position_value := puff.position as Vector3
		var radius := float(puff.radius)
		var offset := Vector2(position_value.x, position_value.z).distance_squared_to(ground)
		if offset > radius * radius * 9.0:
			continue
		var fade := 1.0 - float(puff.age) / float(puff.life)
		total += CLOUD_AT_GROUND * fade * exp(-offset / (2.0 * radius * radius))
	return total * (1.0 - _washout())


func factory_report(factory: Dictionary) -> Dictionary:
	var clouds := 0
	for puff in puffs:
		clouds += int(str(puff.factory) == str(factory.id) and not bool(puff.jet))
	var state := "collapsed" if bool(factory.get("collapsed", false)) else "running" if bool(factory.get("emitting", factory.running)) else "stopped" if str(factory.mode) == "off" else "on_break"
	return {"id": str(factory.id), "name": str(factory.name), "block": str(factory.block), "sector": str(factory.sector), "centre": factory.centre, "mode": str(factory.mode), "state": state,
		"emission_percent": snappedf(float(factory.level) * 100.0, 0.1), "clouds": clouds, "next_change_s": snappedf(maxf(0.0, float(factory.phase_until)), 0.1) if str(factory.mode) == "auto" else -1.0}


func find_factory(factory_id: String) -> Dictionary:
	for factory in factories:
		if str(factory.id) == factory_id:
			return factory
	return {}


func set_mode(factory_id: String, mode: String) -> bool:
	## auto (shifts with breaks), on (runs without a break) or off. Empty id: every factory.
	if not mode in ["auto", "on", "off"]:
		return false
	var found := false
	for factory in factories:
		if factory_id.is_empty() or str(factory.id) == factory_id:
			factory.mode = mode
			if mode == "auto":
				factory.running = true
				factory.phase_until = _rng.randf_range(RUN_SECONDS.x, RUN_SECONDS.y)
			found = true
	return found


func cloud_positions() -> Array:
	## Compact, for live maps: [x, z, radius, opacity 0-1].
	var rows: Array = []
	for puff in puffs:
		if bool(puff.jet):
			continue
		var position_value := puff.position as Vector3
		rows.append([snappedf(position_value.x, 0.1), snappedf(position_value.z, 0.1), snappedf(float(puff.radius), 0.1), snappedf(_opacity(puff), 0.01)])
	return rows


# --- Drawing ----------------------------------------------------------------------------------

func _opacity(puff: Dictionary, washout := -1.0) -> float:
	if washout < 0.0:
		washout = _washout()
	var life_fraction := float(puff.age) / float(puff.life)
	if bool(puff.jet):
		return 0.55 * smoothstep(0.0, 0.05, life_fraction) * (1.0 - smoothstep(0.35, 1.0, life_fraction))
	# Big clouds grow out of the column (they show once the jet has thinned) and thin out as they spread.
	return 0.3 * smoothstep(0.03, 0.14, life_fraction) * (1.0 - smoothstep(0.4, 1.0, life_fraction)) * (1.0 - washout * 0.5)


func _draw_clouds(delta: float) -> void:
	_light_timer -= delta
	if _light_timer <= 0.0 and _environment != null:
		_light_timer = 1.0
		var night := float((_environment.call("get_conditions") as Dictionary).get("night_factor", 0.0))
		_material.set_shader_parameter("light_level", lerpf(1.0, 0.2, night))
	var cursor := 0
	var washout := _washout()
	for puff in puffs:
		var position_value := puff.position as Vector3
		var radius := float(puff.radius)
		var seed_value := float(puff.seed)
		var life_fraction := float(puff.age) / float(puff.life)
		var opacity := _opacity(puff, washout)
		var jet := bool(puff.jet)
		var shade := lerpf(0.24, 0.38, life_fraction) if jet else lerpf(0.36, 0.56, smoothstep(0.0, 0.7, life_fraction))
		for lobe in (1 if jet else LOBES):
			var angle := seed_value * TAU + float(lobe) * 2.4
			var centre := position_value + Vector3(cos(angle), sin(angle * 1.7) * 0.25, sin(angle)) * radius * 0.42
			var size := radius * (2.3 if lobe == 0 else 1.8)
			var at := cursor * BYTES_PER_INSTANCE
			_buffer[at] = size
			_buffer[at + 1] = 0.0
			_buffer[at + 2] = 0.0
			_buffer[at + 3] = centre.x
			_buffer[at + 4] = 0.0
			_buffer[at + 5] = size
			_buffer[at + 6] = 0.0
			_buffer[at + 7] = centre.y
			_buffer[at + 8] = 0.0
			_buffer[at + 9] = 0.0
			_buffer[at + 10] = 1.0
			_buffer[at + 11] = centre.z
			_buffer[at + 12] = shade
			_buffer[at + 13] = shade * 0.95
			_buffer[at + 14] = shade * 0.80
			_buffer[at + 15] = opacity
			_buffer[at + 16] = fposmod(seed_value * 7.3 + float(lobe) * 0.37, 1.0)
			_buffer[at + 17] = life_fraction
			_buffer[at + 18] = 0.0
			_buffer[at + 19] = 0.0
			cursor += 1
	_multimesh.buffer = _buffer
	_multimesh.visible_instance_count = cursor
