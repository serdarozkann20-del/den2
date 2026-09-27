@tool
## Reads, patches and verifies Godot's `.import` sidecars so the engine's own retarget
## pipeline does the heavy lifting (bone rest unification, track pruning, unique-node
## track paths). Nothing here re-implements retargeting math.
##
## Option layout, verified against Godot 4.7 sources:
##  * `retarget/bone_map` and every `retarget/*` key belongs to the
##    `INTERNAL_IMPORT_CATEGORY_SKELETON_3D_NODE` category, i.e. it lives inside
##    `[params] _subresources.nodes."PATH:<skeleton path>"` - NOT in `[params]` directly.
##    Keys the importer does not know are inert, so a wrong guess can never corrupt an
##    asset; it just does nothing. `calibrate_from_reference()` exists to close that gap.
##  * `[remap] importer="animation_library"` + `type="AnimationLibrary"` switches a file
##    to animation-library import (`ResourceImporterScene::get_importer_name()`).
##
## Node option defaults are filled in by the importer at import time, so a partial node
## entry is safe: we only write what we actually want to change.
class_name RBImport
extends RefCounted

const SKELETON_NAME := "GeneralSkeleton"
const FALLBACK_NODE_KEYS: PackedStringArray = [
	"PATH:Armature/Skeleton3D", "PATH:Skeleton3D", "PATH:RootNode/Skeleton3D",
]

## Per-node (SKELETON_3D_NODE) retarget keys. Names/defaults copied from
## editor/import/3d/post_import_plugin_skeleton_{renamer,rest_fixer,track_organizer}.cpp
const NODE_KEYS := {
	"bone_map": "retarget/bone_map",
	"rename_bones": "retarget/bone_renamer/rename_bones",
	"make_unique": "retarget/bone_renamer/unique_node/make_unique",
	"skeleton_name": "retarget/bone_renamer/unique_node/skeleton_name",
	"apply_node_transforms": "retarget/rest_fixer/apply_node_transforms",
	"normalize_position_tracks": "retarget/rest_fixer/normalize_position_tracks",
	"reset_poses": "retarget/rest_fixer/reset_all_bone_poses_after_import",
	"retarget_method": "retarget/rest_fixer/retarget_method",
	"keep_global_rest": "retarget/rest_fixer/keep_global_rest_on_leftovers",
	"use_global_pose": "retarget/rest_fixer/use_global_pose",
	"original_skeleton_name": "retarget/rest_fixer/original_skeleton_name",
	"fix_silhouette": "retarget/rest_fixer/fix_silhouette/enable",
	"silhouette_threshold": "retarget/rest_fixer/fix_silhouette/threshold",
	"base_height_adjustment": "retarget/rest_fixer/fix_silhouette/base_height_adjustment",
	"except_bone_transform": "retarget/remove_tracks/except_bone_transform",
	"unimportant_positions": "retarget/remove_tracks/unimportant_positions",
	"unmapped_bones": "retarget/remove_tracks/unmapped_bones",
}

## retarget_method: None, Overwrite Axis, Use Retarget Modifier
const RETARGET_METHODS := { "none": 0, "overwrite_axis": 1, "modifier": 2 }
## remove_tracks/unmapped_bones: None, Remove, Separate Library
const UNMAPPED_MODES := { "none": 0, "remove": 1, "separate_library": 2 }

## Options the user may tick in the dock. Each maps to node keys written when enabled.
const EXTRA_GROUPS := {
	"overwrite_axis": { "retarget/rest_fixer/retarget_method": 1 },
	"fix_silhouette": {
		"retarget/rest_fixer/fix_silhouette/enable": true,
		"retarget/rest_fixer/fix_silhouette/threshold": 15.0,
	},
	"unimportant_positions": { "retarget/remove_tracks/unimportant_positions": true },
	"unmapped_bones": { "retarget/remove_tracks/unmapped_bones": 1 },
	"except_bone_transform": { "retarget/remove_tracks/except_bone_transform": true },
	"skip_unmapped": { "retarget/remove_tracks/unmapped_bones": 0 },
	"modifier_mode": { "retarget/rest_fixer/retarget_method": 2 },
	"keep_rest_leftovers": { "retarget/rest_fixer/keep_global_rest_on_leftovers": true },
}


static func version() -> Dictionary:
	var info := Engine.get_version_info()
	return {
		"major": int(info["major"]),
		"minor": int(info["minor"]),
		"patch": int(info.get("patch", 0)),
		"string": String(info.get("string", "?")),
	}


static func sidecar(model_path: String) -> String:
	return model_path + ".import"


static func exists(model_path: String) -> bool:
	return FileAccess.file_exists(sidecar(model_path))


static func load_config(model_path: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	var err := cfg.load(ProjectSettings.globalize_path(sidecar(model_path)))
	if err != OK:
		return null
	return cfg


static func save_config(cfg: ConfigFile, model_path: String) -> Error:
	return cfg.save(ProjectSettings.globalize_path(sidecar(model_path)))


static func _read_subresources(cfg: ConfigFile) -> Dictionary:
	if not cfg.has_section_key("params", "_subresources"):
		return {}
	var raw = cfg.get_value("params", "_subresources")
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	return (raw as Dictionary).duplicate(true)


static func _write_subresources(cfg: ConfigFile, sub: Dictionary) -> void:
	cfg.set_value("params", "_subresources", sub)


static func node_entries(model_path: String) -> Dictionary:
	var cfg := load_config(model_path)
	if cfg == null:
		return {}
	var sub := _read_subresources(cfg)
	var nodes = sub.get("nodes", {})
	if typeof(nodes) != TYPE_DICTIONARY:
		return {}
	return nodes as Dictionary


## Which `_subresources.nodes` key belongs to the skeleton; -1 style fallback to the
## conventional names if the file has no entries yet.
static func find_node_key(model_path: String, preferred: String = "") -> String:
	var nodes := node_entries(model_path)
	if not preferred.is_empty() and nodes.has(preferred):
		return preferred
	for k in nodes.keys():
		if String(k).contains("Skeleton3D"):
			return String(k)
	for k in nodes.keys():
		var v = nodes[k]
		if typeof(v) == TYPE_DICTIONARY and (v as Dictionary).has(NODE_KEYS["bone_map"]):
			return String(k)
	return ""


## The whole dictionary the engine reads for `node_key`.
static func node_values(model_path: String, node_key: String) -> Dictionary:
	var nodes := node_entries(model_path)
	var v = nodes.get(node_key, {})
	if typeof(v) != TYPE_DICTIONARY:
		return {}
	return v as Dictionary


## Merge `values` into the node entry, leaving every other node/param untouched.
static func write_node_values(model_path: String, node_key: String, values: Dictionary) -> Error:
	var cfg := load_config(model_path)
	if cfg == null:
		return ERR_FILE_NOT_FOUND
	var sub := _read_subresources(cfg)
	var nodes: Dictionary = sub.get("nodes", {})
	var entry: Dictionary = {}
	var cur = nodes.get(node_key, {})
	if typeof(cur) == TYPE_DICTIONARY:
		entry = (cur as Dictionary).duplicate(true)
	for k in values.keys():
		var key := String(k)
		var val = values[k]
		if val == null:
			entry.erase(key)
		else:
			entry[key] = val
	nodes[node_key] = entry
	sub["nodes"] = nodes
	_write_subresources(cfg, sub)
	return save_config(cfg, model_path)


static func write_flat_params(model_path: String, params: Dictionary) -> Error:
	var cfg := load_config(model_path)
	if cfg == null:
		return ERR_FILE_NOT_FOUND
	for k in params.keys():
		cfg.set_value("params", String(k), params[k])
	return save_config(cfg, model_path)


static func flat_params(model_path: String) -> Dictionary:
	var cfg := load_config(model_path)
	var out := {}
	if cfg == null:
		return out
	for key in cfg.get_section_keys("params"):
		var k := String(key)
		if k == "_subresources":
			continue
		out[k] = cfg.get_value("params", key)
	return out


## `[remap]` switching: "animation_library" or "scene".
## AnimationLibrary mode writes a `.res` AnimationLibrary instead of a PackedScene,
## which is the tidy way to ship a clip set.
static func set_import_type(model_path: String, kind: String) -> Error:
	var cfg := load_config(model_path)
	if cfg == null:
		return ERR_FILE_NOT_FOUND
	var importer := "scene"
	var res_type := "PackedScene"
	if kind == "animation_library":
		importer = "animation_library"
		res_type = "AnimationLibrary"
	elif kind != "scene":
		return ERR_INVALID_PARAMETER
	cfg.set_value("remap", "importer", importer)
	cfg.set_value("remap", "type", res_type)
	return save_config(cfg, model_path)


static func get_import_type(model_path: String) -> String:
	var cfg := load_config(model_path)
	if cfg == null:
		return ""
	return String(cfg.get_value("remap", "importer", ""))


## Compose the node values for a retarget-configured file.
static func build_node_values(bone_map: Resource, opts: Dictionary) -> Dictionary:
	var out := {}
	if bone_map != null:
		out[String(NODE_KEYS["bone_map"])] = bone_map
	out[String(NODE_KEYS["rename_bones"])] = bool(opts.get("rename_bones", true))
	out[String(NODE_KEYS["make_unique"])] = bool(opts.get("make_unique", true))
	out[String(NODE_KEYS["skeleton_name"])] = String(opts.get("skeleton_name", SKELETON_NAME))
	out[String(NODE_KEYS["apply_node_transforms"])] = bool(opts.get("apply_node_transforms", true))
	out[String(NODE_KEYS["normalize_position_tracks"])] = bool(opts.get("normalize_position_tracks", true))
	out[String(NODE_KEYS["reset_poses"])] = bool(opts.get("reset_poses", true))
	var method: String = String(opts.get("retarget_method", "overwrite_axis"))
	if RETARGET_METHODS.has(method):
		out[String(NODE_KEYS["retarget_method"])] = int(RETARGET_METHODS[method])
	var extras: Array = opts.get("extras", ["unimportant_positions"])
	for e in extras:
		var key := String(e)
		if EXTRA_GROUPS.has(key):
			var g: Dictionary = EXTRA_GROUPS[key]
			for gk in g.keys():
				out[String(gk)] = g[gk]
	# `unmapped_bones` mode overrides if requested explicitly.
	if opts.has("unmapped_bones_mode"):
		var m: String = String(opts["unmapped_bones_mode"])
		if UNMAPPED_MODES.has(m):
			out[String(NODE_KEYS["unmapped_bones"])] = int(UNMAPPED_MODES[m])
	return out


## Configure one file for retargeting.
static func configure(model_path: String, bone_map: Resource, opts: Dictionary = {}) -> Dictionary:
	if not exists(model_path):
		return {"ok": false, "error": "no .import sidecar (import the file once first)"}
	var node_key := String(opts.get("node_key", ""))
	if node_key.is_empty():
		node_key = find_node_key(model_path)
	if node_key.is_empty():
		node_key = String(opts.get("preferred_node_key", ""))
	if node_key.is_empty():
		node_key = FALLBACK_NODE_KEYS[0]
	var values := build_node_values(bone_map, opts)
	var err := write_node_values(model_path, node_key, values)
	if err != OK:
		return {"ok": false, "error": "cannot write .import (code %d)" % err}
	if bool(opts.get("also_flat", false)):
		write_flat_params(model_path, values)
	if bool(opts.get("as_animation_library", false)):
		set_import_type(model_path, "animation_library")
	elif bool(opts.get("as_scene", false)):
		set_import_type(model_path, "scene")
	return {"ok": true, "node_key": node_key, "keys": values.size(), "written": values.keys()}


## Keys we wrote that are still present after a reimport.
static func verify(model_path: String, node_key: String, expected: PackedStringArray) -> Dictionary:
	var present := PackedStringArray()
	var missing := PackedStringArray()
	var vals := node_values(model_path, node_key)
	for k in expected:
		var key := String(k)
		if vals.has(key):
			present.append(key)
		else:
			missing.append(key)
	return {
		"present": present,
		"missing": missing,
		"node_key_found": not node_key.is_empty(),
		"ok": missing.is_empty() and not node_key.is_empty(),
	}


## Snapshot a hand-configured reference file so the exact key set can be cloned.
static func calibrate_snapshot(reference_path: String) -> Dictionary:
	var node_key := find_node_key(reference_path)
	var vals := node_values(reference_path, node_key)
	var flat := flat_params(reference_path)
	var flat_useful := {}
	for k in flat.keys():
		var key := String(k)
		if key.begins_with("retarget/") or key.begins_with("nodes/import_as_skeleton_bones") or key.begins_with("animation/"):
			flat_useful[key] = flat[k]
	return {
		"reference": reference_path,
		"node_key": node_key,
		"node_values": vals,
		"flat": flat_useful,
		"import_type": get_import_type(reference_path),
		"count": vals.size() + flat_useful.size(),
	}


## Apply a calibration snapshot to a batch. `bone_map` overrides the snapshot's map so
## every file still gets its own per-rig BoneMap.
static func calibrate_apply(snapshot: Dictionary, target_path: String, bone_map: Resource) -> Dictionary:
	if not exists(target_path):
		return {"ok": false, "error": "no .import file"}
	var node_key := String(snapshot.get("node_key", ""))
	var vals: Dictionary = snapshot.get("node_values", {})
	var applied := 0
	if not vals.is_empty():
		var clone := {}
		for k in vals.keys():
			var key := String(k)
			if key == String(NODE_KEYS["bone_map"]):
				if bone_map != null:
					clone[key] = bone_map
				else:
					continue
			elif key == String(NODE_KEYS["skeleton_name"]):
				clone[key] = String(vals[k])
			else:
				clone[key] = vals[k]
		if write_node_values(target_path, node_key, clone) == OK:
			applied += clone.size()
	var flat: Dictionary = snapshot.get("flat", {})
	if not flat.is_empty():
		write_flat_params(target_path, flat)
		applied += flat.size()
	var itype := String(snapshot.get("import_type", ""))
	if not itype.is_empty():
		set_import_type(target_path, itype)
	if applied == 0:
		return {"ok": false, "error": "reference file had no retarget keys to copy"}
	return {"ok": true, "applied": applied, "node_key": node_key}

