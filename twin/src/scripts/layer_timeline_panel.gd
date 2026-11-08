extends VBoxContainer

## The Timeline tab: everything that moves between the three layers, as it happens.
##
## Three lanes (Twin, City Brain, Guardian) run down the left; each entry is a row with an arrow from the sender's lane to the
## receiver's (a dot when it stays in one layer), its time and what it says. Requests, answers, briefings and the twin's own
## detections and actions all appear, in order, with millisecond time stamps. Click a row to see its details and payload.
## The entries come from the partner gateway through SimApi (timeline_push); the same lines are in the run logs.

const ROW_HEIGHT := 36.0
const LANE_AREA := 132.0
const LANES := {"twin": 0, "brain": 1, "guardian": 2}
const LANE_NAMES := ["TWIN", "BRAIN", "GUARDIAN"]
const COLOURS := {"twin": Color("6ea7cf"), "brain": Color("c49be6"), "guardian": Color("85c58b"), "operator": Color("e2b96d")}
const TEXT := Color("e5e5e5")
const MUTED := Color("a9a9a9")
const RED := Color("df8585")
const ROW_SELECTED := Color(0.43, 0.65, 0.81, 0.22)
const MAX_ROWS := 600

var sim_api: Node
var _entries: Array = []
var _status := {}
var _selected := -1
var _status_label: RichTextLabel
var _scroll: ScrollContainer
var _rows: Control
var _details: TextEdit
var _follow := true


func setup(api: Node) -> void:
	sim_api = api


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var caption := Label.new()
	caption.text = "LAYER TIMELINE  ·  TWIN ⇄ CITY BRAIN ⇄ GUARDIAN"
	caption.add_theme_font_size_override("font_size", 12)
	caption.add_theme_color_override("font_color", Color("6ea7cf"))
	add_child(caption)
	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.scroll_active = false
	_status_label.add_theme_font_size_override("normal_font_size", 11)
	_status_label.text = "[color=#a9a9a9]Waiting for the partner gateway…[/color]"
	add_child(_status_label)
	var lanes_header := Control.new()
	lanes_header.custom_minimum_size = Vector2(0, 16)
	lanes_header.draw.connect(_draw_header.bind(lanes_header))
	add_child(lanes_header)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(0, 260)
	add_child(_scroll)
	_rows = Control.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.mouse_filter = Control.MOUSE_FILTER_STOP
	_rows.clip_contents = true
	_rows.draw.connect(_draw_rows)
	_rows.gui_input.connect(_on_rows_input)
	_scroll.add_child(_rows)
	_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void:
		var bar := _scroll.get_v_scroll_bar()
		_follow = bar.value >= bar.max_value - bar.page - 4.0
		_rows.queue_redraw())
	var hint := Label.new()
	hint.text = "Click a row for its details and payload."
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", MUTED)
	add_child(hint)
	_details = TextEdit.new()
	_details.editable = false
	_details.custom_minimum_size = Vector2(0, 150)
	_details.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_details.add_theme_font_size_override("font_size", 11)
	_details.placeholder_text = "No entry selected"
	add_child(_details)


func add_entries(entries: Array, status: Dictionary) -> void:
	for value in entries:
		_entries.append(value)
	if _entries.size() > MAX_ROWS:
		var dropped := _entries.size() - MAX_ROWS
		_entries = _entries.slice(dropped)
		_selected = maxi(-1, _selected - dropped)
	if not status.is_empty():
		_status = status
		_render_status()
	if _rows == null:
		return
	_rows.custom_minimum_size = Vector2(0, _entries.size() * ROW_HEIGHT)
	_rows.queue_redraw()
	if _follow:
		_scroll.call_deferred("set_v_scroll", int(_entries.size() * ROW_HEIGHT))


func entry_count() -> int:
	return _entries.size()


func _render_status() -> void:
	var parts: Array[String] = []
	var twin := _status.get("twin", {}) as Dictionary
	parts.append("[color=#6ea7cf]●[/color] Twin %s" % str(twin.get("url", "")))
	var partners := _status.get("partners", {}) as Dictionary
	for role in ["brain", "guardian"]:
		var link := partners.get(role, {}) as Dictionary
		if link.is_empty():
			continue
		var colour := "#85c58b" if bool(link.get("healthy", false)) else "#df8585"
		parts.append("[color=%s]●[/color] %s %s%s" % [colour, "City Brain" if role == "brain" else "Guardian", "connected" if bool(link.get("healthy", false)) else "unreachable",
			" (stand-in)" if bool(link.get("standin", false)) else ""])
	parts.append("Dispatch decided by: %s" % ("the City Brain" if str(_status.get("dispatch", "")) == "brain" else "the twin"))
	_status_label.text = "   ".join(parts)


func _lane_x(index: int) -> float:
	return 22.0 + index * (LANE_AREA - 46.0) / 2.0


func _lane_of(layer: String) -> int:
	return int(LANES.get(layer, -1))


func _draw_header(control: Control) -> void:
	var font := get_theme_default_font()
	for index in 3:
		var text: String = LANE_NAMES[index]
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
		control.draw_string(font, Vector2(clampf(_lane_x(index) - width * 0.5, 0.0, LANE_AREA), 12.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9,
			COLOURS[["twin", "brain", "guardian"][index]])


func _draw_rows() -> void:
	var font := get_theme_default_font()
	var width := _rows.size.x
	var top := _scroll.scroll_vertical
	var first := maxi(0, int(top / ROW_HEIGHT) - 1)
	var last := mini(_entries.size(), first + int(_scroll.size.y / ROW_HEIGHT) + 3)
	for index in 3:
		var x := _lane_x(index)
		_rows.draw_line(Vector2(x, first * ROW_HEIGHT), Vector2(x, last * ROW_HEIGHT), Color(1, 1, 1, 0.10), 1.0)
	for row in range(first, last):
		var entry := _entries[row] as Dictionary
		var y := row * ROW_HEIGHT
		if row == _selected:
			_rows.draw_rect(Rect2(0, y, width, ROW_HEIGHT), ROW_SELECTED)
		var source := str(entry.get("from", ""))
		var target := str(entry.get("to", ""))
		var colour: Color = COLOURS.get(source, TEXT)
		var kind := str(entry.get("kind", ""))
		if kind == "security":
			colour = RED
		var middle := y + ROW_HEIGHT * 0.5
		var from_lane := _lane_of(source)
		var to_lane := _lane_of(target)
		if source == "operator":
			_draw_arrow(Vector2(0.0, middle), Vector2(_lane_x(0), middle), colour)
		elif from_lane >= 0 and to_lane >= 0 and from_lane != to_lane:
			_draw_arrow(Vector2(_lane_x(from_lane), middle), Vector2(_lane_x(to_lane), middle), colour)
		elif from_lane >= 0:
			_rows.draw_circle(Vector2(_lane_x(from_lane), middle), 3.5, colour)
		var route := source.to_upper() + ((" → " + target.to_upper()) if not target.is_empty() else "")
		var text_width := maxf(40.0, width - LANE_AREA - 8.0)
		_rows.draw_string(font, Vector2(LANE_AREA + 4.0, y + 14.0), "%s   %s" % [str(entry.get("time", "")).left(12), route], HORIZONTAL_ALIGNMENT_LEFT, text_width, 10, colour)
		_rows.draw_string(font, Vector2(LANE_AREA + 4.0, y + 29.0), str(entry.get("text", "")), HORIZONTAL_ALIGNMENT_LEFT, text_width, 11,
			TEXT if kind != "security" else RED)


func _draw_arrow(start: Vector2, end: Vector2, colour: Color) -> void:
	_rows.draw_line(start, end, colour, 1.6, true)
	var direction := (end - start).normalized()
	var normal := Vector2(-direction.y, direction.x)
	_rows.draw_colored_polygon(PackedVector2Array([end, end - direction * 6.0 + normal * 3.5, end - direction * 6.0 - normal * 3.5]), colour)


func _on_rows_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or click.button_index != MOUSE_BUTTON_LEFT:
		return
	var row := int(click.position.y / ROW_HEIGHT)
	if row < 0 or row >= _entries.size():
		return
	_selected = row
	_rows.queue_redraw()
	_show_details(_entries[row] as Dictionary)


func _show_details(entry: Dictionary) -> void:
	var source := str(entry.get("from", "")).to_upper()
	var target := str(entry.get("to", "")).to_upper()
	var lines: Array[String] = ["%s   %s%s" % [str(entry.get("time", "")), source, (" → " + target) if not target.is_empty() else ""], str(entry.get("text", ""))]
	if not str(entry.get("incident", "")).is_empty():
		lines.append("Incident: %s   Run log: logs/%s" % [str(entry.incident), str(entry.get("run", "(session log)"))])
	if bool(entry.get("briefed", false)):
		lines.append("Briefed by the %s (its own account of this step)." % str(entry.get("from", "")))
	var payload := ""
	if sim_api != null:
		var full := sim_api.call("read_timeline", {"seq": int(entry.get("seq", 0))}) as Dictionary
		var found := full.get("entry", {}) as Dictionary
		payload = str(found.get("payload", ""))
	lines.append("")
	lines.append("Payload:" if not payload.is_empty() else "No payload.")
	if not payload.is_empty():
		lines.append(payload)
	_details.text = "\n".join(lines)
