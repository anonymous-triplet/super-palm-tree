extends SceneTree

## Renders the "calling" badge above a real responder-contract civilian: ringing (fast arcs, shaking badge),
## talking (slow arcs) and idle (hidden). Needs a display: godot --display-driver x11 --script tests/render_call_icon.gd

const CallIcon := preload("res://scripts/incidents/call_icon.gd")
const OUTPUT_DIR := "/tmp/city_call_icon"

func _init() -> void:
	call_deferred("_run")

func _shot(name: String) -> int:
	for unused in 3:
		await process_frame
	return root.get_texture().get_image().save_png("%s/%s" % [OUTPUT_DIR, name])

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	root.size = Vector2i(960, 720)
	var city := (load("res://scenes/City.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(city)
	for canvas in city.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	for unused in 40:
		await process_frame
	var manager := city.get_node("Incidents")
	var spot := Vector3(-40.0, 0.17, -12.0)
	var agent := manager.call("spawn_civilian", "res://assets/rocketbox/Business_Male_01/Export/Business_Male_01.fbx", spot, PI) as Node
	if agent == null:
		push_error("CALL ICON RENDER: could not spawn a civilian")
		quit(1)
		return
	var camera := Camera3D.new()
	camera.fov = 38.0
	city.add_child(camera)
	camera.current = true
	camera.look_at_from_position(spot + Vector3(0.0, 2.1, 5.2), spot + Vector3(0.9, 1.9, 0.0), Vector3.UP)
	agent.call("perform", "PhoneText", -1.0, null)
	var icon := CallIcon.attach(agent.get("body") as Node3D)
	var errors := 0
	icon.call("set_mode", "")
	errors += int(await _shot("0_idle.png") != OK)
	icon.call("set_mode", "ringing")
	await create_timer(0.6).timeout
	errors += int(await _shot("1_ringing_a.png") != OK)
	await create_timer(0.17).timeout
	errors += int(await _shot("1_ringing_b.png") != OK)
	icon.call("set_mode", "talking")
	await create_timer(0.8).timeout
	errors += int(await _shot("2_talking.png") != OK)
	icon.call("set_mode", "")
	await create_timer(0.8).timeout
	var hidden := not bool(icon.call("is_showing"))
	errors += int(await _shot("3_hung_up.png") != OK)
	print("CALL_ICON_RENDER|hidden_after_hangup=", hidden, "|output=", OUTPUT_DIR)
	quit(0 if errors == 0 and hidden else 1)
