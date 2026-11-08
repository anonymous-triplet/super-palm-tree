extends SceneTree

## Close visual regression frames for the captured hazard reaction and real run
## cycle. The camera follows one live SocietyKernel citizen; no isolated model
## or mocked animation state is used.

const OUTPUT_DIR := "/tmp/city_emergency_motion"

func _init() -> void:
	call_deferred("_run")


func _frame_subject(camera: Camera3D, subject: Node3D, side := 1.0) -> void:
	var target := subject.global_position + Vector3.UP * 0.95
	var forward := -subject.global_transform.basis.z.normalized()
	var right := subject.global_transform.basis.x.normalized()
	var camera_position := target - forward * 4.2 + right * (1.35 * side) + Vector3.UP * 0.55
	camera.look_at_from_position(camera_position, target, Vector3.UP)


func _capture(camera: Camera3D, subject: Node3D, file_name: String, side := 1.0) -> int:
	_frame_subject(camera, subject, side)
	for unused in 3:
		await process_frame
	return root.get_texture().get_image().save_png("%s/%s" % [OUTPUT_DIR, file_name])


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	root.size = Vector2i(1024, 768)
	var city := (load("res://scenes/City.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(city)
	for canvas in city.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	var environment := (city.get_node("WorldEnvironment") as WorldEnvironment).environment
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.22, 0.30, 0.40)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.88, 0.92, 1.0)
	environment.ambient_light_energy = 0.75
	environment.fog_enabled = false
	(city.get_node("Sun") as DirectionalLight3D).light_energy = 1.8
	var camera := Camera3D.new()
	camera.fov = 42.0
	city.add_child(camera)
	camera.current = true
	for unused in 40:
		await process_frame
	await create_timer(0.5).timeout
	var npc := city.get_node("NpcAi")
	var earthquakes := city.get_node("Earthquakes")
	earthquakes.call("trigger", "F", 6.4)
	await create_timer(0.45).timeout
	var subject: Node3D
	for state in npc.call("get_agent_debug") as Array[Dictionary]:
		if bool(state.evacuating) and str(state.evacuation_phase) == "reacting":
			subject = state.node as Node3D
			break
	if subject == null:
		push_error("EMERGENCY MOTION RENDER: no reacting Sector F citizen")
		quit(1)
		return
	var errors := 0
	errors += int(await _capture(camera, subject, "01_earthquake_brace.png", 1.0) != OK)
	# Wait for this same persistent citizen to enter the running state.
	var deadline := Time.get_ticks_msec() + 4500
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var state := npc.call("get_agent_state", subject) as Dictionary
		if str(state.get("evacuation_phase", "")) == "moving" and str(state.get("animation_clip", "")) == "Running":
			break
	for frame_index in 4:
		await create_timer(0.11).timeout
		errors += int(await _capture(camera, subject, "run_%02d.png" % frame_index, -1.0) != OK)
	var final_state := npc.call("get_agent_state", subject) as Dictionary
	print("EMERGENCY_MOTION_RENDER|clip=", final_state.get("animation_clip", ""), "|speed=", final_state.get("speed_mps", 0.0), "|output=", OUTPUT_DIR)
	quit(0 if errors == 0 and str(final_state.get("animation_clip", "")) == "Running" else 1)
