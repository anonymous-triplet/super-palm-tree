extends SceneTree

## Frames of the factories and their gas clouds: a factory up close, the plume drifting off, and the whole city.
## Needs a display: godot --display-driver x11 --script tests/render_factories.gd

const OUTPUT_DIR := "/tmp/city_factories"

func _init() -> void:
	call_deferred("_run")

func _shot(camera: Camera3D, name: String, from: Vector3, to: Vector3) -> void:
	camera.look_at_from_position(from, to, Vector3.UP)
	for unused in 6:
		await process_frame
	root.get_texture().get_image().save_png("%s/%s.png" % [OUTPUT_DIR, name])

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	root.size = Vector2i(1280, 720)
	var city := (load("res://scenes/City.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(city)
	for canvas in city.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	for unused in 30:
		await process_frame
	var system := city.get_node("Factories")
	system.call("set_mode", "", "on")
	system.call("simulate", 170.0)
	var camera := Camera3D.new()
	camera.fov = 52.0
	camera.far = 3000.0
	city.add_child(camera)
	camera.current = true
	var factory := (system.get("factories") as Array)[0] as Dictionary
	var centre := factory.centre as Vector3
	await _shot(camera, "1_factory_close", centre + Vector3(-62.0, 22.0, 74.0), centre + Vector3(0.0, 14.0, 0.0))
	await _shot(camera, "2_plume", centre + Vector3(-150.0, 70.0, 210.0), centre + Vector3(30.0, 45.0, 30.0))
	await _shot(camera, "3_city", Vector3(720.0, 520.0, 720.0), Vector3(0.0, 0.0, 0.0))
	await _shot(camera, "4_street_in_haze", Vector3(160.0, 2.0, -250.0), Vector3(240.0, 30.0, -330.0))
	print("FACTORY_RENDER|clouds=", (system.get("puffs") as Array).size(), "|output=", OUTPUT_DIR)
	quit(0)
