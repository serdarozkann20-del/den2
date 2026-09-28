@tool
## Pulls `Animation` resources out of imported model files, normalizes their names,
## optionally rewrites them into profile space, and assembles `AnimationLibrary`
## resources. Pure resource work: no editor calls, so the same code runs headless.
extends RefCounted

const RBAnim := preload("./rb_anim.gd")
const RBName := preload("./rb_name.gd")
const RBPreset := preload("./rb_preset.gd")
## `{animations: Array, errors: PackedStringArray, source_bones: PackedStringArray,
##    skeleton: String}` where each element is `{name, anim, origin, lib}`.
static func extract(path: String, opts: Dictionary = {}) -> Dictionary:
	var errors := PackedStringArray()
	var result: Array = []
	var source_bones := PackedStringArray()
	var skeleton_name := ""
	# `animation_library` import mode yields an AnimationLibrary directly.
	var direct = RBPreset.load_any(path)
	if direct is AnimationLibrary:
		var dlib := direct as AnimationLibrary
		for n in dlib.get_animation_list():
			var an := dlib.get_animation(StringName(String(n)))
			if an == null:
				continue
			if bool(opts.get("deep", true)):
				an = an.duplicate(true) as Animation
			result.append({"name": String(n), "anim": an, "origin": path, "lib": ""})
		return {
			"animations": result,
			"errors": errors,
			"source_bones": source_bones,
			"skeleton": "",
			"library_mode": true,
		}
	var root := RBPreset.load_imported_root(path)
	if root == null:
		# Naming the stage is the difference between "your file is wrong" and "the plugin
		# cannot see it": the fixes could not be more different.
		if direct == null:
			errors.append("nothing readable at %s - is the file imported?" % path)
		elif direct is PackedScene:
			errors.append("%s is a PackedScene with no instantiable state" % path.get_file())
		else:
			errors.append("%s loaded as %s, not a scene or an AnimationLibrary" % [path.get_file(), direct.get_class()])
		return {
			"animations": result,
			"errors": errors,
			"source_bones": source_bones,
			"skeleton": "",
		}
	var players := RBPreset.find_animation_players(root)
	if players.is_empty():
		if root.get_child_count() == 0:
			# The classic script-built-scene trap: `PackedScene.pack()` writes a node only when
			# its `owner` is the root, so a scene built and packed by code can save "empty".
			errors.append("%s instantiated with no children - were their `owner`s set before packing?"
				% path.get_file())
		else:
			errors.append("no AnimationPlayer in " + path)
	var skel := RBPreset.find_skeleton(root)
	if skel != null:
		skeleton_name = String(skel.get_name())
		for i in range(skel.get_bone_count()):
			source_bones.append(String(skel.get_bone_name(i)))
	for pl in players:
		for entry in _collect_from_player(pl as AnimationPlayer):
			var anim: Animation = entry["anim"]
			if anim == null:
				continue
			if bool(opts.get("deep", true)):
				anim = anim.duplicate(true) as Animation
			result.append({
				"name": String(entry["name"]),
				"anim": anim,
				"origin": path,
				"lib": String(entry["lib"]),
			})
	RBPreset.free_node(root)
	return {
		"animations": result,
		"errors": errors,
		"source_bones": source_bones,
		"skeleton": skeleton_name,
	}


static func _collect_from_player(player: AnimationPlayer) -> Array:
	var out: Array = []
	if player == null:
		return out
	if player.has_method("get_animation_library_list"):
		var lib_names: Array = player.get_animation_library_list()
		for ln in lib_names:
			var lib := player.get_animation_library(StringName(String(ln)))
			if lib == null:
				continue
			var names: Array = lib.get_animation_list()
			for an in names:
				out.append({
					"lib": String(ln),
					"name": String(an),
					"anim": lib.get_animation(StringName(String(an))),
				})
		if not out.is_empty():
			return out
	var flat: Array = player.get_animation_list()
	for fn in flat:
		out.append({"lib": "", "name": String(fn), "anim": player.get_animation(StringName(String(fn)))})
	return out


## Applies naming, profile-space rewrite, track pruning and looping to one clip.
## Returns a small report dictionary.
static func process_clip(entry: Dictionary, ctx: Dictionary) -> Dictionary:
	var anim: Animation = entry["anim"]
	var rep := {"renamed": 0, "moved": 0, "dropped": [], "pos_removed": 0, "loop": false}
	if anim == null:
		return rep
	var opts: Dictionary = ctx.get("opts", {})

	if bool(opts.get("to_profile_space", true)):
		var map: Dictionary = ctx.get("bone_to_profile", {})
		if not map.is_empty():
			var r := RBAnim.to_profile_space(
				anim,
				map,
				String(opts.get("skeleton_name", "GeneralSkeleton")),
				bool(opts.get("drop_unmapped", true)),
				PackedStringArray(ctx.get("source_bones", []))
			)
			rep["moved"] = int(r["moved"])
			rep["dropped"] = r["dropped"]

	if bool(opts.get("strip_names", true)):
		var renames := {}
		for i in range(anim.get_track_count()):
			if not RBAnim.is_bone_track(anim, i):
				continue
			var b := RBAnim.bone_of(anim, i)
			var cleaned := String(RBName.strip_prefixes(b))
			if cleaned != b and not cleaned.is_empty():
				renames[b] = cleaned
		if not renames.is_empty():
			rep["renamed"] = int(RBAnim.rename_bones(anim, renames)["renamed"])

	var keep := PackedStringArray(["Root", "Hips"])
	if bool(opts.get("remove_unimportant_positions", false)):
		rep["pos_removed"] = RBAnim.remove_position_tracks_except(anim, keep)

	var hips := PackedStringArray(ctx.get("hips_bones", ["Hips"]))
	if String(opts.get("root_motion", "keep")) == "in_place":
		RBAnim.zero_position(anim, hips)
	elif String(opts.get("root_motion", "keep")) == "flatten_y":
		RBAnim.flatten_y(anim, hips, bool(opts.get("subtract_first", true)))

	var loop: bool = bool(opts.get("loop", false))
	if bool(opts.get("loop_detect", true)) and RBName.has_loop_hint(String(entry["name"])):
		loop = true
	RBAnim.set_loop(anim, loop)
	rep["loop"] = loop
	return rep


static func clip_name(raw: String, origin: String, index: int, opts: Dictionary) -> StringName:
	if bool(opts.get("clean_names", true)):
		var c := RBName.clean_anim_name(raw)
		if not c.is_empty():
			return StringName(c)
	var base := raw
	if base.is_empty():
		base = origin.get_file().get_basename()
	if index > 0:
		base += "_" + str(index)
	return StringName(RBPreset.sanitize(base))


## Build a library from `{name, anim}` entries, de-duplicating names.
## Assemble the library. `opts`: `library_prefix` (String, default "") and
## `on_duplicate` = `rename` (default) | `skip` (first wins) | `replace` (last wins).
static func build_library(entries: Array, opts: Dictionary = {}) -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	var prefix := String(opts.get("library_prefix", ""))
	var on_dup := String(opts.get("on_duplicate", "rename"))
	var used := {}
	for e in entries:
		var nm := prefix + String(e["name"])
		var anim: Animation = e["anim"]
		if anim == null or String(e["name"]).is_empty():
			continue
		var final_name := nm
		var n := 2
		while used.has(final_name):
			if on_dup == "skip":
				break
			if on_dup == "replace":
				break
			final_name = "%s_%d" % [nm, n]
			n += 1
		used[final_name] = true
		var sn := StringName(final_name)
		if lib.has_animation(sn):
			if on_dup == "rename":
				continue
			if on_dup == "skip":
				continue
			lib.remove_animation(sn)
		var err := lib.add_animation(sn, anim)
		if err != OK:
			push_warning("RigBridge: add_animation(%s) failed" % final_name)
	return lib


static func save_library(lib: AnimationLibrary, path: String) -> Error:
	if lib == null or path.is_empty():
		return ERR_INVALID_PARAMETER
	var dir := path.get_base_dir()
	var gp := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(gp):
		DirAccess.make_dir_recursive_absolute(gp)
	return ResourceSaver.save(lib, path, ResourceSaver.FLAG_CHANGE_PATH)


static func library_summary(lib: AnimationLibrary) -> String:
	if lib == null:
		return "empty"
	var names: Array = lib.get_animation_list()
	return "%d animations: %s" % [names.size(), ", ".join(PackedStringArray(names).slice(0, mini(12, names.size())))]


## Merge `src` into `dst`, returning the names that were added.
static func merge(dst: AnimationLibrary, src: AnimationLibrary) -> PackedStringArray:
	var added := PackedStringArray()
	if dst == null or src == null:
		return added
	var names: Array = src.get_animation_list()
	for n in names:
		var nm := String(n)
		if dst.has_animation(StringName(nm)):
			continue
		if dst.add_animation(StringName(nm), src.get_animation(StringName(nm))) == OK:
			added.append(nm)
	return added
