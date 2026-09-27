@tool
## Orchestration: rig analysis -> concept mapping (with preset cache) -> BoneMap
## generation -> per-node `.import` retarget settings -> one batch reimport ->
## clip extraction -> name/bone repair -> AnimationLibrary assembly -> attach.
##
## Modes
##  * `import`  : configure Godot's retarget importer and lift the resulting clips
##                (best quality: bone rest unification, track pruning, path unification
##                all happen inside the engine).
##  * `rewrite` : pure `Animation` surgery into profile space; never touches `.import`,
##                so it also works for formats whose importer lacks retarget options.
##  * `both`    : import where the file is importable, rewrite for the rest.
extends RefCounted

signal progress(stage: String, step: int, total: int, msg: String)
signal logged(level: String, msg: String)

const RBAnim := preload("./rb_anim.gd")
const RBBoneMapBuilder := preload("./rb_bonemap.gd")
const RBBones := preload("./rb_bones.gd")
const RBImport := preload("./rb_import.gd")
const RBLibrary := preload("./rb_library.gd")
const RBMatcher := preload("./rb_matcher.gd")
const RBPreset := preload("./rb_preset.gd")
const RBRig := preload("./rb_rig.gd")



var editor: EditorInterface = null
var last_report: Dictionary = {}
var _roots: Array[Node] = []


func _log(level: String, msg: String) -> void:
	logged.emit(level, msg)
	if level == "error":
		push_error("RigBridge: " + msg)


func _fs() -> EditorFileSystem:
	if editor == null:
		return null
	return editor.get_resource_filesystem()


## Re-run the importers so `.import` edits take effect.
func reimport(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var fs := _fs()
	if fs == null:
		_log("warn", "no EditorFileSystem (headless run?): skipped reimport of %d file(s); run `godot --headless --import`" % paths.size())
		return
	fs.reimport_files(paths)


func free_temp_nodes() -> void:
	for n in _roots:
		if is_instance_valid(n):
			n.free()
	_roots.clear()


## Loads the imported scene. If the file is currently in `animation_library` import
## mode there is no scene to load, so temporarily switch it back to `scene`.
func _load_scene_root(path: String) -> Node:
	var root := RBPreset.load_imported_root(path)
	if root != null:
		return root
	if RBImport.exists(path) and RBImport.get_import_type(path) == "animation_library":
		RBImport.set_import_type(path, "scene")
		reimport(PackedStringArray([path]))
		root = RBPreset.load_imported_root(path)
		if root != null:
			_log("info", "%s: read while temporarily in scene import mode" % path.get_file())
	return root


func ensure_imported(path: String) -> bool:
	var root := _load_scene_root(path)
	if root != null:
		if not _roots.has(root):
			_roots.append(root)
		return true
	if RBImport.exists(path):
		reimport(PackedStringArray([path]))
		var again := _load_scene_root(path)
		if again != null:
			_roots.append(again)
			return true
		_log("error", "imported but no loadable scene for " + path)
		return false
	_log("error", "no .import sidecar: select the file once in the FileSystem dock so Godot imports it, then retry (" + path + ")")
	return false


## Concept mapping for the first skeleton of `path`. Reuses a saved preset when the
## rig shape matches, so a rig you already fixed by hand stays fixed forever.
func map_file(path: String, profile: SkeletonProfile, opts: Dictionary) -> Dictionary:
	var root := _load_scene_root(path)
	if root == null:
		return {"error": "cannot load imported scene: " + path}
	var skel := RBPreset.find_skeleton(root)
	if skel == null:
		return {"error": "no Skeleton3D in " + path}
	var names := PackedStringArray()
	for i in range(skel.get_bone_count()):
		names.append(String(skel.get_bone_name(i)))
	var node_key := "PATH:" + String(root.get_path_to(skel))
	var fam := RBBones.detect_family(names)
	var source := RBRig.from_skeleton(skel, String(fam["family"]))
	var target := RBRig.from_profile(profile, "godot_humanoid")
	var report := RBMatcher.match_rigs(source, target, opts)
	var preset_key := RBPreset.key_for(names)
	var used_preset := false
	if opts.has("overrides_by_rig"):
		var by_rig: Dictionary = opts["overrides_by_rig"]
		if by_rig.has(preset_key):
			var ov: Dictionary = by_rig[preset_key]
			for k in ov.keys():
				var v := String(ov[k])
				if v.is_empty():
					report["mapping"].erase(k)
				else:
					report["mapping"][String(k)] = v
			report["overridden"] = ov.size()
	if bool(opts.get("use_presets", true)):
		var preset := RBPreset.load_preset(preset_key)
		var pm: Dictionary = preset.get("mapping", {})
		if not pm.is_empty() and int(preset.get("bone_count", -1)) == names.size():
			if not report.has("overridden"):
				report["mapping"] = pm
				report["from_preset"] = true
				used_preset = true
				_log("info", "%s: reused saved mapping preset" % path.get_file())
	return {
		"rig": source,
		"target_rig": target,
		"report": report,
		"family": fam,
		"names": names,
		"node_key": node_key,
		"skeleton": String(skel.get_name()),
		"pose": RBAnim.pose_hint(skel),
		"preset_key": preset_key,
		"used_preset": used_preset,
	}


func save_mapping_preset(path: String, info: Dictionary) -> void:
	RBPreset.ensure_dirs()
	var rep: Dictionary = info["report"]
	var data := {
		"source": path,
		"bone_count": (info["names"] as PackedStringArray).size(),
		"bones": info["names"],
		"family": info["family"],
		"mapping": rep["mapping"],
		"scores": rep.get("scores", {}),
		"godot": String(RBImport.version()["string"]),
	}
	RBPreset.save_preset(String(info["preset_key"]), data)


## Write + reload the BoneMap for a mapping. Returns `{path, resource}`.
func save_bonemap(info: Dictionary, profile: SkeletonProfile, out_dir: String, tag: String) -> Dictionary:
	var rep: Dictionary = info["report"]
	var map := RBBoneMapBuilder.build(profile, rep["mapping"])
	var names: PackedStringArray = info["names"]
	var hash_part := String(RBPreset.key_for(names)).get_slice("-", 0)
	var target := out_dir.path_join("%s_%s_bonemap.tres" % [RBPreset.sanitize(tag), hash_part])
	var err := RBBoneMapBuilder.save(map, target)
	if err != OK:
		_log("error", "cannot save BoneMap %s (code %d)" % [target, err])
		return {}
	var res := ResourceLoader.load(target, "", ResourceLoader.CACHE_MODE_REPLACE)
	if res == null:
		_log("error", "BoneMap saved but cannot be reloaded: " + target)
		return {}
	_log("info", "BoneMap -> %s  (%d bones mapped)" % [target, int(rep["matched"])])
	return {"path": target, "resource": res}


func _import_opts(info: Dictionary, opts: Dictionary, as_library: bool) -> Dictionary:
	var extras: PackedStringArray = PackedStringArray(opts.get("extras", PackedStringArray(["unimportant_positions"])))
	if "except_bone_transform" in extras:
		# godotengine/godot#123782: on 4.7.2 this silently erases bone tracks.
		_log("warn", "extras: 'except_bone_transform' is broken in Godot 4.7.2 (tracks get erased); using Mode B instead")
	var pose := String(info.get("pose", {}).get("pose", "unknown"))
	if pose == "a" and not ("fix_silhouette" in extras):
		extras.append("fix_silhouette")
		_log("info", "%s: A-pose detected -> enabling fix_silhouette" % String(info.get("skeleton", "?")))
	return {
		"node_key": String(info.get("node_key", "")),
		"skeleton_name": String(opts.get("skeleton_name", "GeneralSkeleton")),
		"extras": extras,
		"retarget_method": String(opts.get("retarget_method", "overwrite_axis")),
		"unmapped_bones_mode": String(opts.get("unmapped_bones_mode", "remove")),
		"as_animation_library": as_library and bool(opts.get("as_animation_library", false)),
	}


## Full batch run. Option table in the README.
func run(opts: Dictionary) -> Dictionary:
	var mode := String(opts.get("mode", "both"))
	var target_model := String(opts.get("target_model", ""))
	var anim_files: PackedStringArray = opts.get("anim_files", PackedStringArray())
	var out_dir := String(opts.get("out_dir", "res://animations"))
	var lib_name := String(opts.get("library_name", "Mixamo"))
	var skeleton_name := String(opts.get("skeleton_name", "GeneralSkeleton"))
	var profile := opts.get("profile", null) as SkeletonProfile
	if profile == null:
		profile = RBBoneMapBuilder.humanoid_profile()
	var do_reimport := bool(opts.get("do_reimport", true))

	var report := {
		"mode": mode,
		"skeleton_name": skeleton_name,
		"warnings": PackedStringArray(),
		"errors": PackedStringArray(),
		"files": [],
		"godot": RBImport.version(),
	}
	RBPreset.ensure_dirs()
	var per_by_file := {}
	var to_reimport := PackedStringArray()
	var bone_maps := {}

	# --- 1. target rig -------------------------------------------------------
	var target_info := {}
	if not target_model.is_empty():
		progress.emit("target", 0, 1, "Mapping " + target_model.get_file())
		if not ensure_imported(target_model):
			report["errors"].append("target model not readable: " + target_model)
		else:
			target_info = map_file(target_model, profile, opts)
			if target_info.has("error"):
				report["errors"].append(String(target_info["error"]))
				target_info = {}
	if not target_info.is_empty():
		var trep: Dictionary = target_info["report"]
		report["target"] = {
			"file": target_model,
			"quality": String(trep["quality"]),
			"matched": int(trep["matched"]),
			"bones": (target_info["names"] as PackedStringArray).size(),
			"family": target_info["family"],
			"pose": target_info["pose"],
			"node_key": target_info["node_key"],
			"required_missing": trep["required_missing"],
			"scores": trep.get("scores", {}),
			"mapping": trep.get("mapping", {}),
		}
		_log("info", "target: %d bones, %d mapped, quality %s, pose %s" % [
			(target_info["names"] as PackedStringArray).size(),
			int(trep["matched"]), String(trep["quality"]), String(target_info["pose"]["pose"]),
		])
		if String(trep["quality"]) == "poor":
			report["warnings"].append("target rig mapped poorly - review the mapping table before importing animations")
		if bool(opts.get("save_presets", true)) and not bool(target_info["used_preset"]):
			save_mapping_preset(target_model, target_info)
		var tbm := save_bonemap(target_info, profile, out_dir, target_model.get_file().get_basename() + "_target")
		if tbm.is_empty():
			report["warnings"].append("could not write the target BoneMap")
		elif mode != "rewrite" and bool(opts.get("configure_target", true)):
			var tcres := RBImport.configure(target_model, tbm["resource"], _import_opts(target_info, opts, false))
			if bool(tcres["ok"]):
				to_reimport.append(target_model)
				report["target"]["import_mode"] = "node:" + String(tcres["node_key"])
				bone_maps[target_model] = tbm
			else:
				report["warnings"].append("target: " + String(tcres["error"]))

	# --- 2. animation files -------------------------------------------------
	var total := anim_files.size()
	for fi in range(total):
		var file := String(anim_files[fi])
		progress.emit("map", fi, total, file.get_file())
		var per := {"file": file}
		if not ensure_imported(file):
			per["error"] = "not readable"
			report["errors"].append("not readable: " + file)
			report["files"].append(per)
			per_by_file[file] = per
			continue
		var info := map_file(file, profile, opts)
		if info.is_empty() or info.has("error"):
			per["error"] = String(info.get("error", "mapping failed"))
			report["errors"].append("%s: %s" % [file.get_file(), per["error"]])
			report["files"].append(per)
			per_by_file[file] = per
			continue
		var frep: Dictionary = info["report"]
		per["family"] = info["family"]
		per["matched"] = int(frep["matched"])
		per["quality"] = String(frep["quality"])
		per["pose"] = info["pose"]
		per["node_key"] = info["node_key"]
		per["required_missing"] = frep["required_missing"]
		per["mapping"] = frep.get("mapping", {})
		per["names"] = info["names"]
		per["preset_key"] = info["preset_key"]
		if bool(opts.get("save_presets", true)) and not bool(info["used_preset"]):
			save_mapping_preset(file, info)
		var rm: Array = frep["required_missing"]
		if not rm.is_empty():
			report["warnings"].append("%s: %d required profile bones unmapped (%s)" % [
				file.get_file(), rm.size(), ", ".join(PackedStringArray(rm).slice(0, 6)),
			])
		if mode != "rewrite" and int(frep["matched"]) > 0:
			var bm := save_bonemap(info, profile, out_dir, file.get_file().get_basename())
			if not bm.is_empty():
				var cres := RBImport.configure(file, bm["resource"], _import_opts(info, opts, true))
				if bool(cres["ok"]):
					to_reimport.append(file)
					per["import_mode"] = "node:" + String(cres["node_key"])
					per["written_keys"] = cres["written"]
					bone_maps[file] = bm
				else:
					per["import_error"] = String(cres["error"])
					report["warnings"].append("%s: %s" % [file.get_file(), cres["error"]])
		report["files"].append(per)
		per_by_file[file] = per

	# --- 3. one batch reimport ---------------------------------------------
	if do_reimport and not to_reimport.is_empty():
		progress.emit("reimport", 0, to_reimport.size(), "Reimporting %d file(s)" % to_reimport.size())
		reimport(to_reimport)
		if bool(opts.get("verify_keys", true)):
			for vpath in to_reimport:
				var vp := String(vpath)
				var pinf: Dictionary = per_by_file.get(vp, {})
				if not pinf.has("written_keys"):
					continue
				var nk := String(pinf.get("node_key", ""))
				var chk := RBImport.verify(vp, nk, PackedStringArray(pinf["written_keys"]))
				if not bool(chk["ok"]):
					report["warnings"].append("%s: retarget keys not present after reimport (missing %s) - configure one file by hand and press Calibrate" % [
						vp.get_file(), ", ".join(chk["missing"]),
					])

	# --- 4. extract + repair ------------------------------------------------
	var entries: Array = []
	for fi2 in range(total):
		var file2 := String(anim_files[fi2])
		progress.emit("extract", fi2, total, file2.get_file())
		var per2: Dictionary = per_by_file.get(file2, {})
		if per2.is_empty() or per2.has("error"):
			continue
		var via_import: bool = per2.has("import_mode") and mode != "rewrite"
		var extracted := RBLibrary.extract(file2, {"deep": true})
		var anims: Array = extracted["animations"]
		if anims.is_empty():
			report["warnings"].append("%s: no animations found" % file2.get_file())
			continue
		var mapping: Dictionary = per2.get("mapping", {})
		var hips := PackedStringArray()
		for k in mapping.keys():
			var kk := String(k).to_lower()
			if kk == "hips" or kk == "root":
				hips.append(String(mapping[k]))
		if hips.is_empty():
			hips = PackedStringArray(["Hips", "mixamorig:Hips"])
		var clip_opts := {
			"skeleton_name": skeleton_name,
			"clean_names": bool(opts.get("clean_names", true)),
			"strip_names": not via_import,
			"to_profile_space": not via_import,
			"drop_unmapped": bool(opts.get("drop_unmapped", true)),
			"remove_unimportant_positions": bool(opts.get("remove_unimportant_positions", via_import)),
			"loop": bool(opts.get("loop", false)),
			"loop_detect": bool(opts.get("loop_detect", true)),
			"root_motion": String(opts.get("root_motion", "keep")),
		}
		var ctx := {
			"opts": clip_opts,
			"bone_to_profile": RBMatcher.invert(mapping),
			"hips_bones": hips,
		}
		var moved_total := 0
		var dropped_total := 0
		var idx := 0
		for e in anims:
			var rb := RBLibrary.process_clip(e, ctx)
			e["name"] = String(RBLibrary.clip_name(String(e["name"]), file2, idx, clip_opts))
			e["report"] = rb
			entries.append(e)
			moved_total += int(rb.get("moved", 0))
			dropped_total += (rb.get("dropped", []) as Array).size()
			idx += 1
		per2["clips"] = anims.size()
		per2["moved"] = moved_total
		per2["dropped"] = dropped_total
		if bool(opts.get("save_individual", false)):
			var saved := PackedStringArray()
			for e2 in anims:
				var p := out_dir.path_join("clips").path_join(RBPreset.sanitize(String(e2["name"])) + ".tres")
				if RBAnim.save_anim(e2["anim"], p) == OK:
					saved.append(p)
			per2["saved"] = saved
		if dropped_total > 0:
			report["warnings"].append("%s: dropped %d unmapped bone track(s) - fix the mapping to keep them" % [file2.get_file(), dropped_total])
	free_temp_nodes()

	# --- 5. library ---------------------------------------------------------
	progress.emit("library", 0, 1, "Assembling %d clip(s)" % entries.size())
	var lib := RBLibrary.build_library(entries, opts)
	var lib_path := out_dir.path_join(RBPreset.sanitize(lib_name) + ".tres")
	var lib_ok := false
	if bool(opts.get("save_library", true)) and lib.get_animation_list().size() > 0:
		lib_ok = RBLibrary.save_library(lib, lib_path) == OK
		if not lib_ok:
			report["errors"].append("cannot save library " + lib_path)
	report["library"] = {
		"clips": entries.size(),
		"names": lib.get_animation_list(),
		"path": lib_path if lib_ok else "",
		"summary": RBLibrary.library_summary(lib),
	}

	# --- 6. attach ----------------------------------------------------------
	var player := opts.get("player", null) as AnimationPlayer
	if player != null and bool(opts.get("attach", true)):
		var attach_res := attach_library(player, lib, lib_name, opts)
		report["attach"] = attach_res
		if bool(attach_res["ok"]):
			_log("info", "attached '%s' to %s (merged %d, added %d)" % [
				lib_name, String(attach_res["player"]), int(attach_res["merged"]), int(attach_res["added"]),
			])
		else:
			report["errors"].append(String(attach_res.get("error", "attach failed")))

	report["reimported"] = to_reimport
	report["bone_maps"] = bone_maps.keys()
	last_report = report
	progress.emit("done", total, total, "done")
	return report


## Attach (or merge into) an AnimationPlayer.
func attach_library(player: AnimationPlayer, lib: AnimationLibrary, lib_name: String, opts: Dictionary = {}) -> Dictionary:
	if player == null:
		return {"ok": false, "error": "no AnimationPlayer"}
	if lib == null:
		return {"ok": false, "error": "no library"}
	var res := {"ok": true, "player": String(player.get_path()), "merged": 0, "added": 0}
	if player.has_animation_library(lib_name):
		res["merged"] = RBLibrary.merge(player.get_animation_library(lib_name), lib).size()
	else:
		var err := player.add_animation_library(lib_name, lib)
		if err != OK:
			return {"ok": false, "error": "add_animation_library failed (code %d)" % err}
		res["added"] = lib.get_animation_list().size()
	if editor != null and bool(opts.get("mark_dirty", true)):
		if editor.has_method("mark_scene_as_unsaved"):
			editor.mark_scene_as_unsaved()
		if bool(opts.get("save_scene", false)) and editor.has_method("save_scene"):
			res["saved"] = int(editor.save_scene()) == OK
	return res


## Human readable summary for the dock / CLI.
static func format_report(report: Dictionary) -> String:
	var lines := PackedStringArray()
	if report.has("target"):
		var t: Dictionary = report["target"]
		lines.append("Target   %s  mapped %d/%d  quality %s  pose %s" % [
			String(t["file"]).get_file(), int(t["matched"]), int(t.get("bones", 0)),
			String(t["quality"]), String((t.get("pose", {}) as Dictionary).get("pose", "?")),
		])
		var tmissing: Array = t.get("required_missing", [])
		if not tmissing.is_empty():
			lines.append("         missing required: " + ", ".join(PackedStringArray(tmissing)))
	for f in report.get("files", []):
		var fd: Dictionary = f
		var note := ""
		if fd.has("error"):
			note = "ERROR " + String(fd["error"])
		else:
			note = "%d clip(s), %d track(s) rewritten, %d dropped, quality %s" % [
				int(fd.get("clips", 0)), int(fd.get("moved", 0)), int(fd.get("dropped", 0)), String(fd.get("quality", "?")),
			]
			if fd.has("import_mode"):
				note += "  [" + String(fd["import_mode"]) + "]"
		lines.append("%-30s %s" % [String(fd["file"]).get_file(), note])
	if report.has("library"):
		lines.append("Library  " + String((report["library"] as Dictionary)["summary"]))
		var lp := String((report["library"] as Dictionary)["path"])
		if not lp.is_empty():
			lines.append("Saved    " + lp)
	for w in report.get("warnings", []):
		lines.append("! " + String(w))
	for e in report.get("errors", []):
		lines.append("x " + String(e))
	return "\n".join(lines)
