extends SceneTree

## The run log (bottom window) and the Timeline tab of the control room. Timeline entries go in the way the partner gateway
## sends them (SimApi timeline_push); the bottom window must show exactly their lines (time, route, text, no payload), the
## Timeline tab one row each with the payload on demand, and read_timeline must return them. Windowed, it also saves a
## screenshot of the whole control room with the Timeline tab open.
##     godot --path src --script tests/test_layer_timeline_ui.gd            (add --display-driver x11 for the screenshot)

const SHOT := "/tmp/city_layer_timeline.png"
const ENTRIES := [
	["operator", "twin", "briefing", "", "Scenario T01 Rear-end collision: every system steady for 1 s, starting now"],
	["operator", "twin", "request", "", "Trigger rear end (T01 Rear-end collision)"],
	["twin", "", "event", "INC-0001", "INC-0001: Impact at 30 km/h (moderate)"],
	["twin", "", "event", "INC-0001", "INC-0001: Response plan: traffic_control, medical, recovery, recovery"],
	["twin", "brain", "request", "INC-0001", "Reported INC-0001: rear-end collision at B.4, moderate: callers need police (traffic control), ambulance (medical), tow (recovery), tow (recovery)"],
	["brain", "twin", "response", "INC-0001", "Acknowledged INC-0001: 4 call(s) taken; verifying the report with the Guardian"],
	["brain", "guardian", "briefing", "INC-0001", "Asked the Guardian whether the INC-0001 report can be trusted"],
	["guardian", "twin", "request", "INC-0001", "Read vehicle civ_087"],
	["twin", "guardian", "response", "INC-0001", "Vehicle civ_087: 0.0 m/s in sector B"],
	["guardian", "brain", "briefing", "INC-0001", "Verdict on INC-0001: trusted (civ_087 is at the scene (3 m, 0.0 m/s), stopped)"],
	["brain", "twin", "request", "INC-0001", "Read the emergency fleet"],
	["twin", "brain", "response", "INC-0001", "Fleet: 15 units, 15 free"],
	["brain", "twin", "request", "INC-0001", "Dispatch decision for INC-0001: POL-4 for INC-0001-R1, AMB-1 for INC-0001-R2, TOW-1 for INC-0001-R3, TOW-2 for INC-0001-R4"],
	["twin", "brain", "response", "INC-0001", "Dispatch accepted: INC-0001-R1: POL-4; INC-0001-R2: AMB-1; INC-0001-R3: TOW-1; INC-0001-R4: TOW-2"],
	["twin", "", "event", "INC-0001", "INC-0001: The driver of civ_081 called Hospital F.4 EMS [EMS line]"],
	["twin", "", "event", "INC-0001", "INC-0001: AMB-1 dispatched (medical)"],
	["twin", "", "security", "", "Refused a connection from 127.0.0.1:59236: peer did not return a certificate"],
	["twin", "brain", "request", "INC-0001", "INC-0001 is resolved: scene cleared, units AMB-1, TOW-2, POL-4, TOW-1 released"],
	["brain", "twin", "response", "INC-0001", "Closed case INC-0001: 4 dispatch decision(s) on record"],
]

func _init() -> void:
	call_deferred("_run")

func _fail(message: String) -> void:
	print("LAYER TIMELINE UI TEST FAILED: " + message)
	quit(1)

func _run() -> void:
	var room := (load("res://scenes/ControlRoom.tscn") as PackedScene).instantiate()
	root.add_child(room)
	for i in 30:
		await process_frame
	var api := room.get("_sim_api") as Node
	if api == null:
		_fail("no SimApi")
		return
	var entries: Array = []
	var stamp := 1762605902351
	for index in ENTRIES.size():
		var spec: Array = ENTRIES[index]
		var at := stamp + index * 137
		entries.append({"t": at, "time": "13:45:%02d.%03d" % [2 + index / 7, at % 1000], "from": spec[0], "to": spec[1], "kind": spec[2], "incident": spec[3], "text": spec[4],
			"payload": {"tool": "example", "index": index}, "run": "2026-11-08_13-45-02_t01-rear-end-collision_INC-0001_rear-end-collision.log" if spec[3] != "" else ""})
	var status := {"twin": {"identity": "city-twin", "url": "https://127.0.0.1:8740/mcp"}, "dispatch": "brain",
		"partners": {"brain": {"healthy": true, "standin": true, "identity": "city-brain"}, "guardian": {"healthy": true, "standin": true, "identity": "guardian"}}}
	var pushed := api.call("handle_request", {"id": 1, "method": "timeline_push", "params": {"entries": entries, "status": status}}) as Dictionary
	if not bool(pushed.get("ok", false)) or int((pushed.result as Dictionary).added) != ENTRIES.size():
		_fail("timeline_push: %s" % JSON.stringify(pushed))
		return
	await process_frame
	# The bottom window: exactly the lines, in order, and nothing else.
	var log_label := room.find_child("RunLog", true, false) as RichTextLabel
	var shown := log_label.get_parsed_text().strip_edges().split("\n")
	if shown.size() != ENTRIES.size():
		_fail("the bottom window shows %d lines for %d entries" % [shown.size(), ENTRIES.size()])
		return
	for index in ENTRIES.size():
		var spec: Array = ENTRIES[index]
		var line := str(shown[index])
		if not line.ends_with(str(spec[4])) or not line.begins_with(str(entries[index].time)) or line.contains("payload") or not line.contains(str(spec[0]).to_upper()):
			_fail("bottom line %d is '%s'" % [index, line])
			return
	# Operator actions no longer reach the bottom window (they stay in read_event_log).
	room.call("_add_event", "Viewport switched directly to CAM-01")
	await process_frame
	if log_label.get_parsed_text().contains("CAM-01"):
		_fail("an operator event appeared in the run log window")
		return
	# The Timeline tab: one row per entry; the payload is read back on demand.
	var panel := room.find_child("LayerTimeline", true, false)
	if panel == null or int(panel.call("entry_count")) != ENTRIES.size():
		_fail("the Timeline tab does not hold every entry")
		return
	var tabs := room.find_child("ControlTabs", true, false) as TabContainer
	tabs.current_tab = tabs.get_tab_count() - 1
	if tabs.get_tab_title(tabs.current_tab) != "Timeline":
		_fail("the last tab is '%s'" % tabs.get_tab_title(tabs.current_tab))
		return
	panel.call("_show_details", (panel.get("_entries") as Array)[12])
	var details := (panel.get("_details") as TextEdit).text
	if not details.contains("BRAIN → TWIN") or not details.contains("\"index\": 12"):
		_fail("the details box does not show the entry and its payload: %s" % details.left(200))
		return
	var read := api.call("handle_request", {"id": 2, "method": "read_timeline", "params": {"incident": "INC-0001"}}) as Dictionary
	var rows := (read.result as Dictionary).entries as Array
	if rows.size() != ENTRIES.size() - 3 or (rows[0] as Dictionary).has("payload"):
		_fail("read_timeline by incident returned %d rows" % rows.size())
		return
	if DisplayServer.get_name() != "headless":
		panel.set("_selected", 12)
		for i in 20:
			await process_frame
		root.get_texture().get_image().save_png(SHOT)
		print("screenshot: " + SHOT)
	print("LAYER TIMELINE UI TEST PASSED: %d entries in the bottom run log and the Timeline tab, payloads on demand" % ENTRIES.size())
	quit(0)
