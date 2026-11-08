extends Node3D

## The "calling" badge above a person who is on the phone: a green round badge
## with a white handset, and three sound arcs that pulse outward from it in turn
## (quickly while the line rings, slowly and steadily while someone is talking).
## It fades in when the call starts and out when the person hangs up, always faces
## the camera, and grows with distance so it stays readable from the overview.

const TEX := 128
const PIXEL := 0.0052
const HEIGHT := 2.45
const RINGING_RATE := 2.6
const TALKING_RATE := 1.25

static var _badge_texture: ImageTexture
static var _arc_textures: Array[ImageTexture] = []

var _badge: Sprite3D
var _arcs: Array[Sprite3D] = []
var _time := 0.0
var _level := 0.0
var _mode := ""


static func attach(body: Node3D) -> Node3D:
	var icon := (load("res://scripts/incidents/call_icon.gd") as GDScript).new() as Node3D
	icon.name = "CallIcon"
	body.add_child(icon)
	return icon


func _ready() -> void:
	position = Vector3(0.0, HEIGHT, 0.0)
	_build()
	visible = false


func set_mode(mode: String) -> void:
	## "ringing", "talking" or "" (not on the phone).
	_mode = mode


func is_showing() -> bool:
	return visible


func _process(delta: float) -> void:
	var active := _mode != ""
	_level = move_toward(_level, 1.0 if active else 0.0, delta * 4.0)
	visible = _level > 0.01
	if not visible:
		return
	_time += delta
	var rate := RINGING_RATE if _mode == "ringing" else TALKING_RATE
	for index in _arcs.size():
		var phase := fposmod(_time * rate - float(index) * 0.2, 1.0)
		var pulse := pow(maxf(sin(phase * PI), 0.0), 1.4)
		_arcs[index].modulate.a = (0.12 + 0.88 * pulse) * _level
	# The badge pops in, and trembles a little while the phone rings.
	var pop := 0.55 + 0.45 * smoothstep(0.0, 1.0, _level)
	var shake := sin(_time * 38.0) * 0.07 if _mode == "ringing" else 0.0
	_badge.rotation.z = shake
	_badge.modulate.a = _level
	var camera := get_viewport().get_camera_3d()
	var grow := 1.0
	if camera != null:
		grow = clampf(camera.global_position.distance_to(global_position) / 16.0, 1.0, 5.5)
	scale = Vector3.ONE * pop * grow


func _build() -> void:
	if _badge_texture == null:
		_badge_texture = _make_badge()
		for radius in [26.0, 48.0, 70.0]:
			_arc_textures.append(_make_arc(radius))
	_badge = _sprite(_badge_texture)
	add_child(_badge)
	for texture in _arc_textures:
		var arc := _sprite(texture)
		# The arcs' origin sits at the badge's upper-right rim.
		arc.position = Vector3(96.0, 96.0, 0.0) * PIXEL
		add_child(arc)
		_arcs.append(arc)


func _sprite(texture: Texture2D) -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.texture = texture
	sprite.pixel_size = PIXEL
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.double_sided = true
	sprite.transparent = true
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sprite.render_priority = 4
	return sprite


static func _coverage(signed_distance: float) -> float:
	return clampf(0.5 - signed_distance, 0.0, 1.0)


static func _make_badge() -> ImageTexture:
	var image := Image.create(TEX, TEX, true, Image.FORMAT_RGBA8)
	var centre := Vector2(TEX * 0.5, TEX * 0.5)
	# The handset: a quarter ring with a fat earpiece and mouthpiece at its ends.
	var ring_centre := centre + Vector2(15.0, 15.0)
	var radius := 31.0
	var thickness := 13.0
	var end_a := ring_centre + Vector2(-radius, 0.0)
	var end_b := ring_centre + Vector2(0.0, -radius)
	for y in TEX:
		for x in TEX:
			var p := Vector2(x + 0.5, y + 0.5)
			var disc := _coverage(p.distance_to(centre) - 60.0)
			if disc <= 0.0:
				image.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var rim := _coverage(p.distance_to(centre) - 56.0)
			var colour := Color(1.0, 1.0, 1.0, 1.0).lerp(Color(0.10, 0.62, 0.34, 1.0), rim)
			var relative := p - ring_centre
			var angle := fposmod(atan2(relative.y, relative.x), TAU)
			var arc_distance: float
			if angle >= PI and angle <= PI * 1.5:
				arc_distance = absf(relative.length() - radius) - thickness * 0.5
			else:
				arc_distance = minf(p.distance_to(end_a), p.distance_to(end_b)) - thickness * 0.5
			var glyph := _coverage(minf(arc_distance, minf(p.distance_to(end_a), p.distance_to(end_b)) - thickness * 0.95))
			colour = colour.lerp(Color(1, 1, 1, 1), glyph)
			colour.a = disc
			image.set_pixel(x, y, colour)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


static func _make_arc(radius: float) -> ImageTexture:
	var image := Image.create(TEX, TEX, true, Image.FORMAT_RGBA8)
	var origin := Vector2(10.0, TEX - 10.0)
	var thickness := 9.0
	var start := deg_to_rad(-86.0)
	var finish := deg_to_rad(-4.0)
	var end_a := origin + Vector2(cos(start), sin(start)) * radius
	var end_b := origin + Vector2(cos(finish), sin(finish)) * radius
	for y in TEX:
		for x in TEX:
			var p := Vector2(x + 0.5, y + 0.5)
			var relative := p - origin
			var angle := atan2(relative.y, relative.x)
			var distance: float
			if angle >= start and angle <= finish:
				distance = absf(relative.length() - radius) - thickness * 0.5
			else:
				distance = minf(p.distance_to(end_a), p.distance_to(end_b)) - thickness * 0.5
			var alpha := _coverage(distance)
			image.set_pixel(x, y, Color(0.16, 0.86, 0.45, alpha) if alpha > 0.0 else Color(0, 0, 0, 0))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)
