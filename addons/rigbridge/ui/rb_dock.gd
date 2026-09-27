@tool
## Bottom-panel dock: pick a target model + animation files, review/override the
## automatic bone mapping, then apply import settings and build the library.
class_name RBDock
extends Control

const MODES: PackedStringArray = ["both", "import", "rewrite"]
const ROOT_MOTION: PackedStringArray = ["keep", "in_place", "flatten_y"]

var editor: EditorInterface = null
var pipeline: RBPipeline = null

var target_model := ""
var target_player_path := ""
var anim_files := PackedStringArray()
var out_dir := "res://animations"
var library_name := "Mixamo"
var skeleton_name := "GeneralSkeleton"
var overrides := {}      # {rig_key: {profile_bone: source_bone}}
var analyses := {}       # {rig_key: analysis info}
var rig_keys := {}       # {display name: rig_key}
var selected_rig := ""

var _target_option: OptionButton
var _rig_select: OptionButton
var _file_list: ItemList
var _mode: OptionButton
var _root_motion: OptionButton
var _retarget_method: OptionButton
var _unmapped_mode: OptionButton
var _chk_as_library: CheckButton
var _extra_checks: Array[CheckButton] = []
var _chk_clean: CheckButton
var _chk_drop: CheckButton
var _chk_loop: CheckButton
var _chk_library: CheckButton
var _chk_individual: CheckButton
var _chk_attach: CheckButton
var _chk_save_scene: CheckButton
var _chk_presets: CheckButton
var _chk_config_target: CheckButton
var _edit_out: LineEdit
var _edit_lib: LineEdit
var _edit_skel: LineEdit
var _tree: Tree
var _report: RichTextLabel
var _status: Label
var _progress: ProgressBar
var _menu: PopupMenu
var _menu_target := ""
var _menu_candidates: Array = []
var _dialog: FileDialog


func _ready() -> void:
	custom_minimum_size = Vector2(700, 480)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	pipeline = RBPipeline.new()
	pipeline.editor = editor
	pipeline.progress.connect(_on_progress)
	pipeline.logged.connect(_on_logged)
	_build_ui()
	_refresh_targets()
	_log("info", "RigBridge ready: pick a target model, add animation files, then Analyze mapping.")


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var trow := HBoxContainer.new()
	root.add_child(trow)
	trow.add_child(_label("Target"))
	_target_option = OptionButton.new()
	_target_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_option.tooltip_text = "Either the source model file (for its BoneMap) or an AnimationPlayer in the edited scene (to attach the library to)"
	_target_option.item_selected.connect(_on_target_selected)
	trow.add_child(_target_option)
	_add_button(trow, "Model...", _pick_target_model)
	_add_button(trow, "Rescan", _refresh_targets)

	var fbox := VBoxContainer.new()
	root.add_child(fbox)
	var frow := HBoxContainer.new()
	fbox.add_child(frow)
	frow.add_child(_label("Animation files (Mixamo FBX/GLB/DAE)"))
	_add_button(frow, "Add files...", _pick_files)
	_add_button(frow, "Add folder...", _pick_folder)
	_add_button(frow, "Remove selected", _remove_selected_files)
	_add_button(frow, "Clear", _clear_files)
	_file_list = ItemList.new()
	_file_list.select_mode = ItemList.SELECT_MULTI
	_file_list.custom_minimum_size = Vector2(0, 88)
	_file_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fbox.add_child(_file_list)

	var opts := GridContainer.new()
	opts.columns = 4
	root.add_child(opts)
	opts.add_child(_label("Mode"))
	_mode = OptionButton.new()
	for m in MODES:
		_mode.add_item(m)
	_mode.tooltip_text = "both = engine retarget + animation surgery fallback\nimport = only .import retarget settings\nrewrite = only Animation resource surgery"
	opts.add_child(_mode)
	opts.add_child(_label("Root motion"))
	_root_motion = OptionButton.new()
	for r in ROOT_MOTION:
		_root_motion.add_item(r)
	_root_motion.tooltip_text = "in_place = zero Hips translation, flatten_y = keep stride remove bob, keep = as authored"
	opts.add_child(_root_motion)
	opts.add_child(_label("Retarget method"))
	_retarget_method = OptionButton.new()
	for m in RBImport.RETARGET_METHODS.keys():
		_retarget_method.add_item(String(m))
	_retarget_method.selected = 1
	_retarget_method.tooltip_text = "Written as the INT enum retarget/rest_fixer/retarget_method. overwrite_axis compensates differing bone axes (the usual fix for twisted limbs)."
	opts.add_child(_retarget_method)
	opts.add_child(_label("Unmapped bones"))
	_unmapped_mode = OptionButton.new()
	for m in RBImport.UNMAPPED_MODES.keys():
		_unmapped_mode.add_item(String(m))
	_unmapped_mode.selected = 1
	_unmapped_mode.tooltip_text = "retarget/remove_tracks/unmapped_bones: remove = strip tracks with no target bone, separate_library = park them in a second library."
	opts.add_child(_unmapped_mode)
	opts.add_child(_label("Skeleton node"))
	_edit_skel = LineEdit.new()
	_edit_skel.text = skeleton_name
	_edit_skel.tooltip_text = "Unique node name the retarget importer gives the Skeleton3D; track paths become @<name>:<profile bone>"
	opts.add_child(_edit_skel)

	opts.add_child(_label("Library"))
	_edit_lib = LineEdit.new()
	_edit_lib.text = library_name
	opts.add_child(_edit_lib)
	opts.add_child(_label("Out folder"))
	_edit_out = LineEdit.new()
	_edit_out.text = out_dir
	opts.add_child(_edit_out)
	_add_button(opts, "Choose", _pick_out_dir)
	_add_button(opts, "Analyze mapping", _on_analyze)

	var checks := HBoxContainer.new()
	root.add_child(checks)
	_chk_clean = _check(checks, "clean clip names", true)
	_chk_drop = _check(checks, "drop unmapped tracks", true)
	_chk_loop = _check(checks, "loop all", false)
	_chk_presets = _check(checks, "reuse presets", true)
	_chk_config_target = _check(checks, "configure target", true)
	var checks2 := HBoxContainer.new()
	root.add_child(checks2)
	_chk_library = _check(checks2, "save library .tres", true)
	_chk_individual = _check(checks2, "save each clip", false)
	_chk_attach = _check(checks2, "attach to player", true)
	_chk_save_scene = _check(checks2, "save scene", false)
	_chk_as_library = _check(checks2, "import anim files as AnimationLibrary", false)
	_chk_as_library.tooltip_text = "Mode A only: the file imports straight to an AnimationLibrary (.res). Disable it if a Godot build rejects that key."
	for ex in RBImport.EXTRA_GROUPS.keys():
		_extra_checks.append(_check_extra(checks2, String(ex)))

	var actions := HBoxContainer.new()
	root.add_child(actions)
	_add_button(actions, "Apply import + reimport", _on_apply_import)
	_add_button(actions, "Build library", _on_build)
	_add_button(actions, "Run all", _on_run_all)
	_add_button(actions, "Calibrate keys...", _on_calibrate)
	_add_button(actions, "Save preset", _on_save_preset)

	var hbox := HBoxContainer.new()
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(hbox)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(left)
	var rigrow := HBoxContainer.new()
	left.add_child(rigrow)
	rigrow.add_child(_label("Rig"))
	_rig_select = OptionButton.new()
	_rig_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rig_select.item_selected.connect(_on_rig_selected)
	rigrow.add_child(_rig_select)
	left.add_child(_label("double-click a row to override the mapped bone"))
	_tree = Tree.new()
	_tree.columns = 4
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.set_column_title(0, "profile bone")
	_tree.set_column_title(1, "source bone")
	_tree.set_column_title(2, "score")
	_tree.set_column_title(3, "why")
	_tree.item_activated.connect(_on_tree_item_activated)
	left.add_child(_tree)
	_menu = PopupMenu.new()
	_menu.name = "OverrideMenu"
	_menu.id_pressed.connect(_on_override_picked)
	add_child(_menu)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(right)
	right.add_child(_label("Report"))
	_report = RichTextLabel.new()
	_report.bbcode_enabled = true
	_report.scroll_following = true
	_report.selection_enabled = true
	_report.custom_minimum_size = Vector2(300, 120)
	_report.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_report)
	_progress = ProgressBar.new()
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(0, 8)
	right.add_child(_progress)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_status)


# ---------------------------------------------------------------- widgets
func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _add_button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _check(parent: Node, text: String, on: bool) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = on
	parent.add_child(c)
	return c


func _check_extra(parent: Node, key: String) -> CheckButton:
	var c := CheckButton.new()
	c.text = key
	c.button_pressed = key == "unimportant_positions"
	c.set_meta("key", key)
	var lines := PackedStringArray()
	var g: Dictionary = RBImport.EXTRA_GROUPS[key]
	for k in g.keys():
		lines.append("%s = %s" % [String(k), str(g[k])])
	c.tooltip_text = "Ticked => writes to the skeleton node's section:\n" + "\n".join(lines)
	if key == "except_bone_transform":
		c.tooltip_text += "\n\nKNOWN BUG in Godot 4.7.2 (#123782): this silently deletes bone tracks.\nPrefer Mode B (track surgery), which needs no import options at all."
	parent.add_child(c)
	return c


func _log(level: String, msg: String) -> void:
	if _report == null:
		return
	var color := "#8ab4ff"
	if level == "error":
		color = "#ff6b6b"
	elif level == "warn":
		color = "#ffcc66"
	_report.append_text("[color=%s]%s[/color] %s\n" % [color, level.to_upper().left(5), msg])


func _on_logged(level: String, msg: String) -> void:
	_log(level, msg)


func _on_progress(stage: String, step: int, total: int, msg: String) -> void:
	_progress.max_value = float(maxi(1, total))
	_progress.value = float(step)
	_status.text = "%s %d/%d  %s" % [stage, step, maxi(1, total), msg]


# ---------------------------------------------------------------- picking
func _open_dialog(title: String, mode: int, filters: PackedStringArray, receiver: String) -> void:
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = FileDialog.new()
	_dialog.title = title
	_dialog.access = FileDialog.ACCESS_RESOURCES
	_dialog.file_mode = mode
	for f in filters:
		_dialog.add_filter(f)
	add_child(_dialog)
	if receiver == "file":
		_dialog.file_selected.connect(_on_dialog_file)
	elif receiver == "files":
		_dialog.files_selected.connect(_on_dialog_files)
	elif receiver == "dir":
		_dialog.dir_selected.connect(_on_dialog_dir)
	_dialog.popup_centered_ratio(0.7)


func _on_dialog_file(p: String) -> void:
	if _dialog != null and _dialog.title.begins_with("Target"):
		target_model = p
		_refresh_targets()
		_log("info", "target model = " + p)
	elif _dialog != null and _dialog.title.begins_with("Output"):
		out_dir = p
		_edit_out.text = p
	elif _dialog != null and _dialog.title.begins_with("Calibrate"):
		_apply_calibration(p)


func _on_dialog_files(p: PackedStringArray) -> void:
	for f in p:
		if not (f in anim_files):
			anim_files.append(String(f))
	_refresh_files()


func _on_dialog_dir(p: String) -> void:
	var found := RBPreset.collect_files(p, true)
	for f in found:
		if not (f in anim_files):
			anim_files.append(String(f))
	_refresh_files()
	_log("info", "added %d file(s) from %s" % [found.size(), p])


func _pick_target_model() -> void:
	_open_dialog("Target model file", FileDialog.FILE_MODE_OPEN_FILE,
		PackedStringArray(["*.fbx, *.glb, *.gltf, *.dae ; 3D model"]), "file")


func _pick_out_dir() -> void:
	_open_dialog("Output folder", FileDialog.FILE_MODE_OPEN_DIR, PackedStringArray(), "dir")


func _pick_files() -> void:
	_open_dialog("Animation files", FileDialog.FILE_MODE_OPEN_FILES,
		PackedStringArray(["*.fbx, *.glb, *.gltf, *.dae ; 3D animation"]), "files")


func _pick_folder() -> void:
	_open_dialog("Folder with animations", FileDialog.FILE_MODE_OPEN_DIR, PackedStringArray(), "dir")


func _clear_files() -> void:
	anim_files = PackedStringArray()
	_refresh_files()


func _remove_selected_files() -> void:
	var sel: PackedInt32Array = _file_list.get_selected_items()
	var keep := PackedStringArray()
	for i in range(anim_files.size()):
		if not sel.has(i):
			keep.append(anim_files[i])
	anim_files = keep
	_refresh_files()


func _refresh_files() -> void:
	_file_list.clear()
	for f in anim_files:
		var tag := ""
		if not RBImport.exists(String(f)):
			tag = "   [no .import - import it once]"
		_file_list.add_item(String(f).get_file() + tag)


func _refresh_targets() -> void:
	_target_option.clear()
	if not target_model.is_empty():
		_target_option.add_item("model: " + target_model.get_file())
	var players: Array = []
	if editor != null:
		var scene := editor.get_edited_scene_root()
		if scene != null:
			players = RBPreset.find_animation_players(scene)
	for p in players:
		_target_option.add_item("player: " + String((p as Node).get_path()))
	if _target_option.item_count == 0:
		_target_option.add_item("(nothing selected)")
		_target_option.disabled = true
	else:
		_target_option.disabled = false
		_target_option.selected = 0
		_on_target_selected(0)


func _on_target_selected(idx: int) -> void:
	var offset := 0 if target_model.is_empty() else 1
	var players: Array = []
	if editor != null:
		var scene := editor.get_edited_scene_root()
		if scene != null:
			players = RBPreset.find_animation_players(scene)
	if idx < offset:
		target_player_path = ""
		return
	var real := idx - offset
	if real >= 0 and real < players.size():
		target_player_path = String((players[real] as Node).get_path())


# ---------------------------------------------------------------- options
func _collect_opts() -> Dictionary:
	var extras := PackedStringArray()
	for c in _extra_checks:
		if c.button_pressed:
			extras.append(String(c.get_meta("key")))
	skeleton_name = _edit_skel.text.strip_edges()
	if skeleton_name.is_empty():
		skeleton_name = "GeneralSkeleton"
		_edit_skel.text = skeleton_name
	library_name = _edit_lib.text.strip_edges()
	if library_name.is_empty():
		library_name = "Mixamo"
	out_dir = _edit_out.text.strip_edges()
	if out_dir.is_empty():
		out_dir = "res://animations"
	return {
		"mode": MODES[maxi(0, _mode.selected)],
		"root_motion": ROOT_MOTION[maxi(0, _root_motion.selected)],
		"extras": extras,
		"retarget_method": String(RBImport.RETARGET_METHODS.keys()[maxi(0, _retarget_method.selected)]),
		"unmapped_bones_mode": String(RBImport.UNMAPPED_MODES.keys()[maxi(0, _unmapped_mode.selected)]),
		"as_animation_library": _chk_as_library.button_pressed,
		"clean_names": _chk_clean.button_pressed,
		"drop_unmapped": _chk_drop.button_pressed,
		"loop": _chk_loop.button_pressed,
		"loop_detect": true,
		"use_presets": _chk_presets.button_pressed,
		"save_presets": _chk_presets.button_pressed,
		"configure_target": _chk_config_target.button_pressed,
		"save_library": _chk_library.button_pressed,
		"save_individual": _chk_individual.button_pressed,
		"attach": _chk_attach.button_pressed,
		"save_scene": _chk_save_scene.button_pressed,
		"skeleton_name": skeleton_name,
		"library_name": library_name,
		"out_dir": out_dir,
		"target_model": target_model,
		"anim_files": anim_files,
		"overrides_by_rig": overrides,
		"verify_keys": true,
	}


func _apply_overrides(rig_key: String, report: Dictionary) -> void:
	if not overrides.has(rig_key):
		return
	var ov: Dictionary = overrides[rig_key]
	var mapping: Dictionary = report["mapping"]
	for k in ov.keys():
		var v := String(ov[k])
		if v.is_empty():
			mapping.erase(k)
		else:
			mapping[String(k)] = v
	report["mapping"] = mapping


func _profile() -> SkeletonProfile:
	return RBBoneMapBuilder.humanoid_profile()


# ---------------------------------------------------------------- actions
func _on_analyze() -> void:
	analyses.clear()
	rig_keys.clear()
	var opts := _collect_opts()
	if not target_model.is_empty():
		_index_rig(target_model, "TARGET " + target_model.get_file(), opts)
	for f in anim_files:
		_index_rig(String(f), String(f).get_file(), opts)
	_rig_select.clear()
	for dn in rig_keys.keys():
		_rig_select.add_item(String(dn))
	if _rig_select.item_count > 0:
		_rig_select.selected = 0
		selected_rig = String(rig_keys[_rig_select.get_item_text(0)])
	_rebuild_tree()
	_refresh_files()


func _index_rig(path: String, display: String, opts: Dictionary) -> void:
	if not pipeline.ensure_imported(path):
		_log("error", "%s: %s" % [display, "cannot read imported scene (import it once first)"])
		return
	var info := pipeline.map_file(path, _profile(), opts)
	if info.has("error"):
		_log("error", "%s: %s" % [display, String(info["error"])])
		return
	var key := String(info["preset_key"])
	_apply_overrides(key, info["report"])
	analyses[key] = info
	rig_keys[display] = key
	var rep: Dictionary = info["report"]
	_log("info", "%s: %d/%d bones mapped, quality %s, family guess '%s'" % [
		display, int(rep["matched"]), (info["names"] as PackedStringArray).size(),
		String(rep["quality"]), String((info["family"] as Dictionary)["family"]),
	])


func _on_rig_selected(idx: int) -> void:
	if idx < 0:
		return
	selected_rig = String(rig_keys[_rig_select.get_item_text(idx)])
	_rebuild_tree()


func _rebuild_tree() -> void:
	_tree.clear()
	if selected_rig.is_empty() or not analyses.has(selected_rig):
		_status.text = "no rig analysed yet"
		return
	var info: Dictionary = analyses[selected_rig]
	var report: Dictionary = info["report"]
	var mapping: Dictionary = report["mapping"]
	var scores: Dictionary = report.get("scores", {})
	var reasons: Dictionary = report.get("reasons", {})
	var target_rig: Dictionary = info["target_rig"]
	var names: PackedStringArray = target_rig["names"]
	for i in range(names.size()):
		var pb := String(names[i])
		var is_req: bool = int(target_rig["required"][i]) == 1
		if not mapping.has(pb) and not is_req:
			continue
		var it := _tree.create_item()
		it.set_text(0, pb)
		it.set_metadata(0, pb)
		if mapping.has(pb):
			it.set_text(1, String(mapping[pb]))
			var sc := float(scores.get(pb, 0.0))
			it.set_text(2, "%.2f" % sc)
			it.set_text(3, ", ".join(PackedStringArray(reasons.get(pb, []))))
			if sc >= 0.85:
				it.set_custom_color(2, Color(0.55, 0.9, 0.55))
			elif sc >= 0.66:
				it.set_custom_color(2, Color(0.95, 0.8, 0.35))
			else:
				it.set_custom_color(2, Color(1.0, 0.45, 0.4))
		else:
			it.set_text(1, "(unmapped - required)")
			it.set_custom_color(1, Color(1.0, 0.4, 0.4))
	_status.text = "mapped %d, required missing %d%s" % [
		int(report["matched"]),
		(report["required_missing"] as Array).size(),
		"  (from preset)" if bool(report.get("from_preset", false)) else "",
	]


func _on_tree_item_activated() -> void:
	var it := _tree.get_selected()
	if it == null or not analyses.has(selected_rig):
		return
	var pb := String(it.get_metadata(0))
	if pb.is_empty():
		return
	var info: Dictionary = analyses[selected_rig]
	_menu_candidates = RBMatcher.suggest(info["rig"], info["target_rig"], pb, 14, {})
	_menu_target = pb
	_menu.clear()
	_menu.add_item("(clear this mapping)")
	for c in _menu_candidates:
		_menu.add_item("%s   (%.2f) %s" % [String(c["source"]), float(c["score"]), ", ".join(PackedStringArray(c["reasons"]))])
	_menu.popup()


func _on_override_picked(id: int) -> void:
	var chosen := ""
	if id == 0:
		chosen = ""
	else:
		var ci := id - 1
		if ci < 0 or ci >= _menu_candidates.size():
			return
		chosen = String(_menu_candidates[ci]["source"])
	if not overrides.has(selected_rig):
		overrides[selected_rig] = {}
	overrides[selected_rig][_menu_target] = chosen
	_log("info", "override %s -> %s" % [_menu_target, chosen if not chosen.is_empty() else "(none)"])
	_reapply_selected()


func _reapply_selected() -> void:
	if not analyses.has(selected_rig):
		return
	var info: Dictionary = analyses[selected_rig]
	var report := RBMatcher.match_rigs(info["rig"], info["target_rig"], {})
	info["report"] = report
	_apply_overrides(selected_rig, report)
	analyses[selected_rig] = info
	_rebuild_tree()


func _on_apply_import() -> void:
	var opts := _collect_opts()
	opts["mode"] = "import"
	opts["attach"] = false
	opts["save_library"] = false
	opts["save_individual"] = false
	_run(opts)


func _on_build() -> void:
	var opts := _collect_opts()
	if String(opts["mode"]) == "import":
		opts["mode"] = "both"
	opts["do_reimport"] = false
	opts["configure_target"] = false
	_run(opts)


func _on_run_all() -> void:
	_run(_collect_opts())


func _run(opts: Dictionary) -> void:
	pipeline.editor = editor
	var player: AnimationPlayer = null
	if not target_player_path.is_empty() and editor != null:
		var scene := editor.get_edited_scene_root()
		if scene != null and scene.has_node_or_null(target_player_path):
			player = scene.get_node(target_player_path) as AnimationPlayer
	if player != null:
		opts["player"] = player
	elif bool(opts.get("attach", false)):
		_log("warn", "no AnimationPlayer in Target dropdown: library is written to disk only")
	var rep := pipeline.run(opts)
	_log("info", RBPipeline.format_report(rep))


func _on_calibrate() -> void:
	_open_dialog("Calibrate reference file", FileDialog.FILE_MODE_OPEN_FILE,
		PackedStringArray(["*.fbx, *.glb, *.gltf, *.dae ; configured model"]), "file")


func _apply_calibration(reference: String) -> void:
	var snap := RBImport.calibrate_snapshot(reference)
	var count := int(snap["count"])
	_log("info", "snapshot from %s: %d key(s)" % [reference.get_file(), count])
	if count == 0:
		_log("error", "that file has no retarget/remove_tracks keys - configure it in the Import dock first")
		return
	var n := 0
	for f in anim_files:
		if bool(RBImport.calibrate_apply(snap, String(f), null)["ok"]):
			n += 1
	if not anim_files.is_empty():
		pipeline.reimport(anim_files)
	_log("info", "applied calibrated keys to %d file(s), reimported" % n)


func _on_save_preset() -> void:
	if selected_rig.is_empty() or not analyses.has(selected_rig):
		_log("error", "nothing to save - run Analyze mapping first")
		return
	var info: Dictionary = analyses[selected_rig]
	var display := ""
	for dn in rig_keys.keys():
		if String(rig_keys[dn]) == selected_rig:
			display = String(dn)
	pipeline.save_mapping_preset(display, info)
	_log("info", "preset saved: " + RBPreset.PRESET_DIR + "/" + String(info["preset_key"]) + ".json")
