extends Node3D

## Marks the 16 city sectors on the ground: a very faint colour wash per sector and a large letter above its centre, so
## the overview camera reads the city as sectors A to P. Both are presentation only (no collisions, no shadows).
## Everything starts hidden: the operator shows all sectors or only chosen ones (Assets tab, or the device interface).

const Sectors := preload("res://scripts/city_sectors.gd")
const WASH_Y := 0.215
const LETTER_Y := 62.0

func _ready() -> void:
	name = "SectorOverlay"
	for index in Sectors.IDS.size():
		var sector := str(Sectors.IDS[index])
		var colour := Color.from_hsv(fmod(float(index) * 0.17 + 0.05, 1.0), 0.55, 0.95)
		var centre := Sectors.centre(sector)
		var wash := MeshInstance3D.new()
		wash.name = "SectorWash_%s" % sector
		var quad := PlaneMesh.new()
		quad.size = Vector2(Sectors.SECTOR_SIZE - 1.0, Sectors.SECTOR_SIZE - 1.0)
		wash.mesh = quad
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(colour.r, colour.g, colour.b, 0.085)
		material.no_depth_test = false
		material.disable_receive_shadows = true
		wash.material_override = material
		wash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		wash.position = Vector3(centre.x, WASH_Y, centre.z)
		wash.set_meta("sector", sector)
		wash.visible = false
		add_child(wash)
		var letter := Label3D.new()
		letter.name = "SectorLetter_%s" % sector
		letter.text = sector
		letter.font_size = 360
		letter.pixel_size = 0.075
		letter.outline_size = 40
		letter.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		letter.modulate = Color(colour.r, colour.g, colour.b, 0.9)
		letter.outline_modulate = Color(0.05, 0.08, 0.12, 0.95)
		letter.no_depth_test = false
		letter.shaded = false
		letter.fixed_size = false
		letter.position = Vector3(centre.x, LETTER_Y, centre.z)
		letter.set_meta("sector", sector)
		letter.visible = false
		add_child(letter)

func set_sector_visible(sector: String, shown: bool) -> void:
	for child in get_children():
		if str(child.get_meta("sector", "")) == sector.to_upper():
			(child as Node3D).visible = shown

func set_all_visible(shown: bool) -> void:
	for sector in Sectors.IDS:
		set_sector_visible(str(sector), shown)

func shown_sectors() -> Array:
	var out: Array = []
	for child in get_children():
		if child is MeshInstance3D and (child as Node3D).visible:
			out.append(str(child.get_meta("sector", "")))
	out.sort()
	return out
