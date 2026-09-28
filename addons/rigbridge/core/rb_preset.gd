@tool
## Project-side caches, preset storage and file walking helpers.
##
## Presets are keyed by a hash of the rig's *bone name set*, so a given source rig
## shape only ever needs one manual mapping pass; every later animation file that
## shares that skeleton reuses the stored mapping instantly.
extends RefCounted

const ROOT := "res://.rigbridge"
const PRESET_DIR := ROOT + "/presets"
const SCAN_GLOB: PackedStringArray = ["glb", "gltf", "fbx", "dae", "obj"]
const MODEL_SUFFIXES: PackedStringArray = ["fbx", "glb", "gltf", "dae"]

## Imported scenes are instantiated in the editor to read their skeleton; they are parked
## here so the Skeleton3D pointers stay valid until the pipeline frees them.
static var _keep: Array[Node] = []


static func sanitize(raw: String) -> String:
	var out := ""
	for c in raw.to_lower():
		var code := c.unicode_at(0)
		var ok: bool = (code >= 97 and code <= 122) or (code >= 48 and code <= 57)
		if ok:
			out += c
		elif c == "_" or c == "-" or c == "." or c == " " or c == ":":
			if not out.ends_with("_"):
				out += "_"
	if out.is_empty():
		return "rig"
	return out


## Deterministic key for a bone-name set (order independent).
static func key_for(names: PackedStringArray) -> String:
	var arr := names.duplicate()
	arr.sort()
	var joined := "|".join(arr)
	return "%x-%d" % [joined.hash(), arr.size()]


static func ensure_dirs() -> void:
	for d in [ROOT, PRESET_DIR]:
		var gpath := ProjectSettings.globalize_path(d)
		if not DirAccess.dir_exists_absolute(gpath):
			DirAccess.make_dir_recursive_absolute(gpath)


static func preset_path(key: String) -> String:
	return PRESET_DIR.path_join(key + ".json")


static func save_preset(key: String, data: Dictionary) -> Error:
	ensure_dirs()
	var f := FileAccess.open(preset_path(key), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return OK


static func load_preset(key: String) -> Dictionary:
	var path := preset_path(key)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary


static func list_presets() -> PackedStringArray:
	var out := PackedStringArray()
	ensure_dirs()
	var d := DirAccess.open(PRESET_DIR)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.get_extension() == "json":
			out.append(PRESET_DIR.path_join(n))
		n = d.get_next()
	d.list_dir_end()
	return out


## Every supported 3D file under `dir`, recursively, skipping hidden folders.
static func collect_files(dir: String, recursive: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not n.begins_with(".") and not n.begins_with("_"):
			var p := dir.path_join(n)
			if d.current_is_dir():
				if recursive:
					out.append_array(collect_files(p, recursive))
			elif n.get_extension().to_lower() in SCAN_GLOB:
				out.append(p)
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out


static func has_import_file(model_path: String) -> bool:
	return FileAccess.file_exists(model_path + ".import")


## Load a resource, including one this very session wrote to disk.
##
## `ResourceLoader.exists()` answers from the resource cache and the editor's import
## bookkeeping, so a `.tres`/`.tscn` saved a moment ago - especially into `user://`, which the
## editor does not scan at all - can report "does not exist", and a read-back then silently
## yields nothing. Mode B writes `Animation`/`AnimationLibrary`/`BoneMap` files and reads them
## back in the same run, so every read-back in this plugin goes through here.
static func load_any(path: String, type: String = "") -> Resource:
	if path.is_empty():
		return null
	if ResourceLoader.exists(path):
		var cached := ResourceLoader.load(path, type)
		if cached != null:
			return cached
	if not FileAccess.file_exists(path):
		return null
	return ResourceLoader.load(path, type, ResourceLoader.CACHE_MODE_REPLACE)


## Load the imported scene for a model/animation file (returns null before import).
static func load_imported_root(path: String) -> Node:
	var res := load_any(path)
	if res is PackedScene:
		var ps := res as PackedScene
		if ps.can_instantiate():
			return ps.instantiate()
	return null


## First Skeleton3D below `node` (depth first).
static func find_skeleton(node: Node) -> Skeleton3D:
	if node == null:
		return null
	if node is Skeleton3D:
		return node as Skeleton3D
	for c in node.get_children():
		var r := find_skeleton(c)
		if r != null:
			return r
	return null


static func find_skeletons(node: Node) -> Array:
	var out: Array = []
	_collect(node, out, "Skeleton3D")
	return out


static func find_animation_players(node: Node) -> Array:
	var out: Array = []
	_collect(node, out, "AnimationPlayer")
	return out


static func _collect(node: Node, out: Array, class_name_str: String) -> void:
	if node == null:
		return
	if is_class_of(node, class_name_str):
		out.append(node)
	for c in node.get_children():
		_collect(c, out, class_name_str)


static func is_class_of(node: Node, wanted: String) -> bool:
	var c := node.get_class()
	if c == wanted:
		return true
	return ClassDB.is_parent_class(c, wanted)


## Skeleton3D of a project file, or null. Caller should `free_node()` the returned
## scene root via `node.owner`-less handle `handle` when done.
static func find_skeleton_in_file(path: String) -> Skeleton3D:
	var root := load_imported_root(path)
	if root == null:
		return null
	var skel := find_skeleton(root)
	if skel == null:
		free_node(root)
		return null
	# Keep the instance alive: the skeleton is a child of it.
	_keep.append(root)
	return skel


static func free_kept() -> void:
	for n in _keep:
		if is_instance_valid(n):
			n.free()
	_keep.clear()


static func free_node(n: Node) -> void:
	if is_instance_valid(n):
		n.free()


## `res://x/y.glb` + `GeneralSkeleton` -> the node path Godot's retarget importer
## uses when `unique_node/make_unique` is on.
static func general_skeleton_path(skeleton_name: String) -> String:
	return "@" + skeleton_name
