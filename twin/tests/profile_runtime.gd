extends SceneTree

## Frame-time profile of the real control room against a live SUMO bridge (default ports, start scripts/sumo_bridge.py first).
## Reports the frame-time distribution, hitches, render timings and what each top-level system costs per frame, so an
## optimisation can be judged by numbers. godot --display-driver x11 --script tests/profile_runtime.gd -- seconds=45 out=/tmp/p.json
## Options: incident=rear_end  speed=4  stream=1 (samples the 100 ms MCP snapshot the dashboard asks for)

const WARMUP_SECONDS := 15.0

class Probe extends Node:
	var sink: Dictionary
	var label := ""
	var stamp: Array
	var physics_stamp: Variant = null
	func _process(_delta: float) -> void:
		_mark()
	func _physics_process(_delta: float) -> void:
		if physics_stamp != null:
			var now := Time.get_ticks_usec()
			if not (physics_stamp[0] as String).is_empty():
				var key: String = "physics/" + str(physics_stamp[0])
				var row: Array = sink.get(key, [0, 0])
				var cost: int = now - int(physics_stamp[1])
				row[0] = int(row[0]) + cost
				row[1] = maxi(int(row[1]), cost)
				sink[key] = row
			physics_stamp[0] = label
			physics_stamp[1] = now
	func _mark() -> void:
		var now := Time.get_ticks_usec()
		if not (stamp[0] as String).is_empty():
			var key: String = stamp[0]
			var row: Array = sink.get(key, [0, 0])
			var cost: int = now - int(stamp[1])
			row[0] = int(row[0]) + cost
			row[1] = maxi(int(row[1]), cost)
			sink[key] = row
		stamp[0] = label
		stamp[1] = now

## Times each scripted node's _process / _physics_process by calling it from one driver node, in priority order.
class Driver extends Node:
	var sink: Dictionary
	var process_list: Array = []
	var physics_list: Array = []
	var frame_costs := {}
	func _run(items: Array, method: String, delta: float, prefix: String) -> void:
		for item in items:
			if not is_instance_valid(item[0]):
				continue
			var node: Node = item[0]
			var t := Time.get_ticks_usec()
			node.call(method, delta)
			var cost := Time.get_ticks_usec() - t
			var key: String = prefix + str(item[1])
			var row: Array = sink.get(key, [0, 0, 0])
			row[0] = int(row[0]) + cost
			row[1] = maxi(int(row[1]), cost)
			sink[key] = row
			frame_costs[key] = int(frame_costs.get(key, 0)) + cost
	var positions := {}
	var jitter: Array = []
	func _process(delta: float) -> void:
		_run(process_list, "_process", delta, "script/")
		# Motion smoothness: how much a moving vehicle's on-screen speed changes from one frame to the next.
		for value in get_tree().get_nodes_in_group("vehicles"):
			var node := value as Node3D
			if node == null or not node.visible:
				continue
			var key := node.get_instance_id()
			var here := node.global_position
			var known: Variant = positions.get(key, null)
			if known != null and delta > 0.0:
				var velocity: float = (here - ((known as Array)[0] as Vector3)).length() / delta
				var previous: float = float((known as Array)[1])
				if previous > 2.0 and velocity > 0.5:
					jitter.append(absf(velocity - previous) / previous)
				positions[key] = [here, velocity]
			else:
				positions[key] = [here, 0.0]
	func _physics_process(delta: float) -> void:
		_run(physics_list, "_physics_process", delta, "physics-script/")

var _costs := {}
var _driver: Driver
var _stamp: Array = ["", 0]
var _physics_stamp: Array = ["", 0]
var _options := {"seconds": "45", "out": "/tmp/profile.json", "incident": "", "speed": "1", "stream": "0"}

func _init() -> void:
	for argument in OS.get_cmdline_user_args():
		var parts := argument.split("=", true, 1)
		if parts.size() == 2:
			_options[parts[0]] = parts[1]
	call_deferred("_run")

func _probe_between_children(parent: Node, prefix: String) -> void:
	for child in parent.get_children():
		var probe := Probe.new()
		probe.sink = _costs
		probe.stamp = _stamp
		probe.physics_stamp = _physics_stamp
		probe.label = prefix + child.name
		probe.process_priority = 0
		parent.add_child(probe)
		parent.move_child(probe, child.get_index())

func _percentile(sorted: Array, fraction: float) -> float:
	return float(sorted[clampi(int(sorted.size() * fraction), 0, sorted.size() - 1)])

func _run() -> void:
	var room := (load("res://scenes/ControlRoom.tscn") as PackedScene).instantiate()
	root.add_child(room)
	var api: Node = null
	await create_timer(WARMUP_SECONDS, true, false, true).timeout
	api = room.get("_sim_api")
	var city := room.get("_city") as Node3D
	var viewport := room.get("_city_viewport") as SubViewport
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	var driver := Driver.new()
	_driver = driver
	driver.sink = _costs
	var nodes: Array = [room]
	var index := 0
	while index < nodes.size():
		var node: Node = nodes[index]
		index += 1
		nodes.append_array(node.get_children())
		var script := node.get_script() as Script
		if script == null:
			continue
		var label := script.resource_path.get_file()
		if label.is_empty():
			label = node.get_class()
		if node.is_processing() and node.has_method("_process"):
			node.set_process(false)
			driver.process_list.append([node, label, node.process_priority])
		if node.is_physics_processing() and node.has_method("_physics_process"):
			node.set_physics_process(false)
			driver.physics_list.append([node, label, node.process_physics_priority])
	driver.process_list.sort_custom(func(a: Array, b: Array) -> bool: return int(a[2]) < int(b[2]))
	driver.physics_list.sort_custom(func(a: Array, b: Array) -> bool: return int(a[2]) < int(b[2]))
	driver.process_priority = 1000
	root.add_child(driver)
	var counts := {}
	for item in driver.process_list + driver.physics_list:
		counts[item[1]] = int(counts.get(item[1], 0)) + 1
	if _options.has("time"):
		api.call("handle_request", {"id": 1, "method": "command", "params": {"id": "CLOCK", "command": "set_time", "value": str(_options.time)}})
	var incident := str(_options.incident)
	if float(_options.speed) != 1.0:
		api.call("handle_request", {"id": 1, "method": "command", "params": {"id": "CLOCK", "command": "set_speed", "value": float(_options.speed)}})
	if not incident.is_empty():
		api.call("handle_request", {"id": 1, "method": "command", "params": {"id": "INCIDENTS", "command": "trigger", "value": incident}})
	var stream := str(_options.stream) == "1"
	# Where a frame goes: physics, process (scripts + animation + transforms), draw submission, swap / wait.
	var phase := {"physics": 0, "process": 0, "draw": 0, "after_draw": 0, "last": Time.get_ticks_usec(), "mode": "after_draw"}
	var mark := func(next: String) -> void:
		var t := Time.get_ticks_usec()
		var was: String = phase.mode
		phase[was] = int(phase[was]) + t - int(phase.last)
		phase.last = t
		phase.mode = next
	physics_frame.connect(func() -> void:
		if phase.mode != "physics":
			mark.call("physics"))
	process_frame.connect(func() -> void: mark.call("process"))
	RenderingServer.frame_pre_draw.connect(func() -> void: mark.call("draw"))
	RenderingServer.frame_post_draw.connect(func() -> void: mark.call("after_draw"))
	var frames: Array = []
	var gpu := 0.0
	var cpu := 0.0
	var stream_cost: Array = []
	var next_stream := 0.0
	var started := Time.get_ticks_usec()
	var last := started
	var seconds := float(_options.seconds)
	var jitter: Array = driver.jitter
	var hitches: Array = []
	while Time.get_ticks_usec() - started < int(seconds * 1000000.0):
		await process_frame
		var now := Time.get_ticks_usec()
		_stamp[0] = "(rest of frame: scene tree after city, rendering, vsync)" if not (_stamp[0] as String).is_empty() else ""
		frames.append((now - last) / 1000.0)
		if now - last > 100000:
			var top: Array = []
			for key in _driver.frame_costs:
				if int(_driver.frame_costs[key]) > 5000:
					top.append("%s %d" % [key, int(_driver.frame_costs[key]) / 1000])
			hitches.append([snappedf((now - started) / 1000000.0, 0.1), int((now - last) / 1000.0), top])
		_driver.frame_costs.clear()
		last = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(viewport.get_viewport_rid())
		if stream and (now - started) / 1000000.0 >= next_stream:
			next_stream += 0.1
			var t := Time.get_ticks_usec()
			api.call("handle_line", JSON.stringify({"id": 1, "method": "ping", "params": {}}))
			api.set("_last_live_request_msec", Time.get_ticks_msec())
			api.call("handle_request", {"id": 1, "method": "snapshot", "params": {}})
			stream_cost.append((Time.get_ticks_usec() - t) / 1000.0)
	var sorted := frames.duplicate()
	sorted.sort()
	var count := float(frames.size())
	var total := 0.0
	for value in frames:
		total += float(value)
	var systems: Array = []
	for key in _costs:
		var row := _costs[key] as Array
		systems.append({"system": key, "ms_per_frame": snappedf(float(row[0]) / 1000.0 / count, 0.01), "worst_ms": snappedf(float(row[1]) / 1000.0, 0.1)})
	systems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.ms_per_frame) > float(b.ms_per_frame))
	jitter.sort()
	var report := {
		"frames": frames.size(), "fps": snappedf(count / (total / 1000.0), 0.1), "mean_ms": snappedf(total / count, 0.01),
		"p50_ms": snappedf(_percentile(sorted, 0.5), 0.1), "p95_ms": snappedf(_percentile(sorted, 0.95), 0.1), "p99_ms": snappedf(_percentile(sorted, 0.99), 0.1), "max_ms": snappedf(float(sorted[-1]), 0.1),
		"over_33ms": sorted.filter(func(v: float) -> bool: return v > 33.4).size(), "over_50ms": sorted.filter(func(v: float) -> bool: return v > 50.0).size(), "over_100ms": sorted.filter(func(v: float) -> bool: return v > 100.0).size(),
		"viewport_gpu_ms": snappedf(gpu / count, 0.01), "viewport_cpu_ms": snappedf(cpu / count, 0.01),
		"process_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01), "physics_ms": snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), "primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "video_mem_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 1.0),
		"vehicle_speed_jitter_p50": snappedf(_percentile(jitter, 0.5), 0.001) if not jitter.is_empty() else 0.0, "vehicle_speed_jitter_p95": snappedf(_percentile(jitter, 0.95), 0.001) if not jitter.is_empty() else 0.0,
		"stream_ms": snappedf(stream_cost.reduce(func(a: float, b: float) -> float: return a + b, 0.0) / maxf(stream_cost.size(), 1.0), 0.1) if stream else 0.0,
		"hitches": hitches.slice(0, 30), "node_counts": counts,
		"systems": systems.slice(0, 30),
	}
	var perf := {}
	var perf_class: Variant = load("res://scripts/_perf.gd") if ResourceLoader.exists("res://scripts/_perf.gd") else null
	if perf_class != null:
		var rows: Dictionary = perf_class.get("rows")
		for key in rows:
			perf[key] = {"ms_per_frame": snappedf(float(rows[key][0]) / 1000.0 / count, 0.02), "worst": snappedf(float(rows[key][1]) / 1000.0, 0.1), "calls_per_frame": snappedf(float(rows[key][2]) / count, 0.01)}
	report["perf"] = perf
	report["phases_ms"] = {"physics": snappedf(float(phase.physics) / 1000.0 / count, 0.1), "process": snappedf(float(phase.process) / 1000.0 / count, 0.1), "draw": snappedf(float(phase.draw) / 1000.0 / count, 0.1), "after_draw": snappedf(float(phase.after_draw) / 1000.0 / count, 0.1)}
	var meshes := {}
	var census: Array = [city]
	var at := 0
	while at < census.size():
		var node: Node = census[at]
		at += 1
		census.append_array(node.get_children())
		if node is MeshInstance3D or node is MultiMeshInstance3D:
			var path := str(city.get_path_to(node)).split("/")
			var top := path[0] + ("/" + path[1] if path.size() > 1 and path[0] in ["SmartCityAssets", "CityBackdrop", "Vehicles"] else "")
			var row: Array = meshes.get(top, [0, 0, 0])
			var visual := node as GeometryInstance3D
			var camera_at := viewport.get_camera_3d().global_position
			var in_range := visual.visibility_range_end <= 0.0 or camera_at.distance_to(visual.global_position) <= visual.visibility_range_end
			if visual.is_visible_in_tree() and not visual.has_meta(&"static_batched") and in_range:
				row[0] = int(row[0]) + 1
				var mesh: Mesh = (node as MeshInstance3D).mesh if node is MeshInstance3D else null
				var multi: MultiMesh = (node as MultiMeshInstance3D).multimesh if node is MultiMeshInstance3D else null
				if multi != null:
					mesh = multi.mesh
				var tris := 0
				if mesh != null:
					for surface in mesh.get_surface_count():
						var arrays := mesh.surface_get_arrays(surface) if mesh is ArrayMesh else []
						if not arrays.is_empty():
							var idx: Variant = arrays[Mesh.ARRAY_INDEX]
							tris += (idx as PackedInt32Array).size() / 3 if idx != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
				row[1] = int(row[1]) + tris * (multi.instance_count if multi != null else 1)
				if visual.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					row[2] = int(row[2]) + 1
			meshes[top] = row
	var census_rows: Array = []
	for key in meshes:
		census_rows.append({"group": key, "visible_meshes": meshes[key][0], "triangles": meshes[key][1], "shadow_casters": meshes[key][2]})
	census_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.triangles) > int(b.triangles))
	report["census"] = census_rows
	var props := {}
	var npc_nodes: Array = [city.get_node("NpcAi")]
	at = 0
	while at < npc_nodes.size():
		var node: Node = npc_nodes[at]
		at += 1
		npc_nodes.append_array(node.get_children())
		if node is MeshInstance3D and (node as MeshInstance3D).mesh is ArrayMesh and (node as MeshInstance3D).is_visible_in_tree():
			var mesh := (node as MeshInstance3D).mesh as ArrayMesh
			var tris := 0
			for surface in mesh.get_surface_count():
				var idx: Variant = mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX]
				if idx != null:
					tris += (idx as PackedInt32Array).size() / 3
			var owner_scene: Node = node
			while owner_scene != null and owner_scene.scene_file_path.is_empty():
				owner_scene = owner_scene.get_parent()
			var label: String = owner_scene.scene_file_path.get_file() if owner_scene != null and owner_scene != city else str(node.name)
			var row: Array = props.get(label, [0, 0, 0])
			row[0] = int(row[0]) + 1
			row[1] = int(row[1]) + tris
			row[2] = int(row[2]) + mesh.get_surface_count()
			props[label] = row
	report["npc_props"] = props
	var file := FileAccess.open(str(_options.out), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("PROFILE_DONE ", str(_options.out))
	quit(0)
