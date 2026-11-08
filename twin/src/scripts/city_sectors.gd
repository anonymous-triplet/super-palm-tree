extends RefCounted

## The city's 16 sectors. The 8 x 8 block grid (95 m blocks, 380 m half extent) is cut into a 4 x 4 grid of sectors of
## 2 x 2 blocks (190 m square), called sectors. Sector A is the top-left corner and the letters run along the rows, so
##   A B C D
##   E F G H
##   I J K L
##   M N O P

const HALF_EXTENT := 380.0
const SECTOR_SIZE := 190.0
const COLUMNS := 4
const IDS := ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P"]

static func sector_of(x: float, z: float) -> String:
	var column := clampi(floori((x + HALF_EXTENT) / SECTOR_SIZE), 0, COLUMNS - 1)
	var row := clampi(floori((z + HALF_EXTENT) / SECTOR_SIZE), 0, COLUMNS - 1)
	return IDS[row * COLUMNS + column]

static func sector_of_position(position: Vector3) -> String:
	return sector_of(position.x, position.z)

static func is_sector(sector: String) -> bool:
	return sector.to_upper() in IDS

static func centre(sector: String) -> Vector3:
	var index := IDS.find(sector.to_upper())
	if index < 0:
		return Vector3.ZERO
	return Vector3(-HALF_EXTENT + (index % COLUMNS + 0.5) * SECTOR_SIZE, 0.0, -HALF_EXTENT + (index / COLUMNS + 0.5) * SECTOR_SIZE)

static func rect(sector: String) -> Rect2:
	var middle := centre(sector)
	return Rect2(middle.x - SECTOR_SIZE * 0.5, middle.z - SECTOR_SIZE * 0.5, SECTOR_SIZE, SECTOR_SIZE)

static func neighbours(sector: String) -> Array:
	var index := IDS.find(sector.to_upper())
	var out: Array = []
	if index < 0:
		return out
	var row := index / COLUMNS
	var column := index % COLUMNS
	for step in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
		var r: int = row + step.x
		var c: int = column + step.y
		if r >= 0 and r < COLUMNS and c >= 0 and c < COLUMNS:
			out.append(IDS[r * COLUMNS + c])
	return out

static func label(sector: String) -> String:
	return "Sector %s" % sector.to_upper()

static func block_label(position: Vector3) -> String:
	## A block inside its sector, when one must be named: blocks 1 2 / 3 4, so "A.1" or "D.3".
	var column := clampi(floori((position.x + HALF_EXTENT) / (SECTOR_SIZE * 0.5)), 0, COLUMNS * 2 - 1)
	var row := clampi(floori((position.z + HALF_EXTENT) / (SECTOR_SIZE * 0.5)), 0, COLUMNS * 2 - 1)
	return "%s.%d" % [sector_of_position(position), row % 2 * 2 + column % 2 + 1]
