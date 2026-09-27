@tool
## Direct `Animation` resource surgery: rewrite bone track paths, prune tracks,
## normalize clip names, set looping, strip/keep root motion, estimate T/A pose.
##
## This is the "fix the bones inside a Mixamo animation" half of the plugin and it
## works without touching import settings, so it also works for formats whose
## importer has no retarget options (Collada `.dae`, obj rigs, odd exports).
class_name RBAnim
extends RefCounted

const BONE_TRACK_TYPES: Array = [
	Animation.TYPE_POSITION_3D,
	Animation.TYPE_ROTATION_3D,
	Animation.TYPE_SCALE_3D,
]


static func split_path(p: NodePath) -> Dictionary:
	var names := PackedStringArray()
	for i in range(p.get_name_count()):
		names.append(String(p.get_name(i)))
	var subs := PackedStringArray()
	for i in range(p.get_subname_count()):
		subs.append(String(p.get_subname(i)))
	return {"names": names, "subs": subs, "absolute": p.is_absolute()}


static func join_path(names: PackedStringArray, subs: PackedStringArray, absolute: bool) -> NodePath:
	var s := "/".join(names)
	for sub in subs:
		s += ":" + String(sub)
	if absolute:
		s = "/" + s
	return NodePath(s)


## The bone part of a track path (its subname), or empty for property/method tracks.
static func bone_of(anim: Animation, idx: int) -> String:
	var p := anim.track_get_path(idx)
	if p.get_subname_count() == 0:
		return ""
	return String(p.get_subname(p.get_subname_count() - 1))


static func is_bone_track(anim: Animation, idx: int) -> bool:
	if anim.track_get_type(idx) not in BONE_TRACK_TYPES:
		return false
	return anim.track_get_path(idx).get_subname_count() > 0


static func set_bone(anim: Animation, idx: int, bone: String, node_override: String = "") -> void:
	var parts := split_path(anim.track_get_path(idx))
	var subs := parts["subs"]
	var names: PackedStringArray = parts["names"]
	if subs.size() > 0:
		subs[subs.size() - 1] = bone
	if not node_override.is_empty():
		names = PackedStringArray([node_override])
	anim.track_set_path(idx, join_path(names, subs, parts["absolute"]))


## Rename bones inside an animation using `{old_bone: new_bone}`.
## Returns `{renamed: int, untouched: int, bones: PackedStringArray}`.
static func rename_bones(anim: Animation, renames: Dictionary) -> Dictionary:
	var renamed := 0
	var untouched := 0
	var seen := PackedStringArray()
	for i in range(anim.get_track_count()):
		if not is_bone_track(anim, i):
			untouched += 1
			continue
		var b := bone_of(anim, i)
		if not seen.has(b):
			seen.append(b)
		if renames.has(b):
			set_bone(anim, i, String(renames[b]))
			renamed += 1
		else:
			untouched += 1
	return {"renamed": renamed, "untouched": untouched, "bones": seen}


## Express an animation in the generalized profile space:
## every bone track becomes `@<skeleton_name>:<profile bone>`.
## `bone_to_profile` is `{source_bone_name: profile_bone_name}`.
static func to_profile_space(
	anim: Animation,
	bone_to_profile: Dictionary,
	skeleton_name: String = "GeneralSkeleton",
	drop_unmapped: bool = true
) -> Dictionary:
	# NodePath splits on ':' so a bone named `mixamorig:LeftArm` can arrive as just
	# `LeftArm`; index a loose map by trailing segment to cover both spellings.
	var loose := {}
	for k in bone_to_profile.keys():
		var ks := String(k)
		var tail := ks.substr(ks.rfind(":") + 1) if ks.contains(":") else ks
		if not loose.has(tail):
			loose[tail] = bone_to_profile[k]
	var dropped: Array = []
	var moved := 0
	var i := 0
	while i < anim.get_track_count():
		if not is_bone_track(anim, i):
			i += 1
			continue
		var b := bone_of(anim, i)
		var target := ""
		if bone_to_profile.has(b):
			target = String(bone_to_profile[b])
		elif loose.has(b):
			target = String(loose[b])
		if not target.is_empty():
			set_bone(anim, i, target, "@" + skeleton_name)
			moved += 1
			i += 1
			continue
		if drop_unmapped:
			dropped.append(b)
			anim.remove_track(i)
			continue
		i += 1
	return {"moved": moved, "dropped": dropped}


static func remove_position_tracks_except(anim: Animation, keep: PackedStringArray) -> int:
	var removed := 0
	var i := anim.get_track_count() - 1
	while i >= 0:
		if anim.track_get_type(i) == Animation.TYPE_POSITION_3D and anim.track_get_path(i).get_subname_count() > 0:
			var b := bone_of(anim, i)
			if not b.is_empty() and not (b in keep):
				anim.remove_track(i)
				removed += 1
		i -= 1
	return removed


static func remove_position_tracks(anim: Animation, bones: PackedStringArray) -> int:
	var removed := 0
	var i := anim.get_track_count() - 1
	while i >= 0:
		if anim.track_get_type(i) == Animation.TYPE_POSITION_3D and anim.track_get_path(i).get_subname_count() > 0:
			if bone_of(anim, i) in bones:
				anim.remove_track(i)
				removed += 1
		i -= 1
	return removed


## Zero out translation on the given bones (classic "in place" fix for the Hips).
static func zero_position(anim: Animation, bones: PackedStringArray) -> int:
	var touched := 0
	for i in range(anim.get_track_count()):
		if anim.track_get_type(i) != Animation.TYPE_POSITION_3D:
			continue
		if not (bone_of(anim, i) in bones):
			continue
		for k in range(anim.track_get_key_count(i)):
			var v = anim.track_get_key_value(i, k)
			if typeof(v) == TYPE_VECTOR3:
				anim.track_set_key_value(i, k, Vector3(0, 0, 0))
		touched += 1
	return touched


## Keep X/Z stride, drop vertical bob — the usual Mixamo "in place + no slide" tweak.
static func flatten_y(anim: Animation, bones: PackedStringArray, subtract_first: bool = true) -> int:
	var touched := 0
	for i in range(anim.get_track_count()):
		if anim.track_get_type(i) != Animation.TYPE_POSITION_3D:
			continue
		if not (bone_of(anim, i) in bones):
			continue
		var base_y := 0.0
		if subtract_first and anim.track_get_key_count(i) > 0:
			var first = anim.track_get_key_value(i, 0)
			if typeof(first) == TYPE_VECTOR3:
				base_y = (first as Vector3).y
		for k in range(anim.track_get_key_count(i)):
			var v = anim.track_get_key_value(i, k)
			if typeof(v) == TYPE_VECTOR3:
				var vv := v as Vector3
				anim.track_set_key_value(i, k, Vector3(vv.x, maxf(0.0, vv.y - base_y), vv.z))
		touched += 1
	return touched


static func set_loop(anim: Animation, on: bool) -> void:
	if on:
		anim.loop_mode = Animation.LOOP_LINEAR
	else:
		anim.loop_mode = Animation.LOOP_NONE


static func is_looping(anim: Animation) -> bool:
	return anim.loop_mode != Animation.LOOP_NONE


static func track_paths_snapshot(anim: Animation) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(anim.get_track_count()):
		out.append("%d %s" % [anim.track_get_type(i), String(anim.track_get_path(i))])
	return out


static func describe(anim: Animation) -> String:
	if anim == null:
		return "<null>"
	var bones := {}
	for i in range(anim.get_track_count()):
		if is_bone_track(anim, i):
			bones[bone_of(anim, i)] = true
	return "tracks=%d bones=%d len=%.3fs loop=%s step=%.4f" % [
		anim.get_track_count(),
		bones.size(),
		anim.length,
		"on" if is_looping(anim) else "off",
		anim.step,
	]


static func save_anim(anim: Animation, path: String) -> Error:
	if anim == null or path.is_empty():
		return ERR_INVALID_PARAMETER
	var dir := path.get_base_dir()
	var gp := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(gp):
		DirAccess.make_dir_recursive_absolute(gp)
	return ResourceSaver.save(anim, path, ResourceSaver.FLAG_CHANGE_PATH)


## T-pose vs A-pose hint, from rest transforms. `> ~15 deg` arm tilt => A-pose,
## which is when `Fix Silhouette` should be enabled.
static func pose_hint(skel: Skeleton3D) -> Dictionary:
	if skel == null:
		return {"pose": "unknown", "tilt": 0.0}
	var upper := ["LeftUpperArm", "left_arm_l", "leftUpperArm", "arm_l", "LeftArm"]
	var lower := ["LeftLowerArm", "left_forearm_l", "leftLowerArm", "forearm_l", "LeftForeArm"]
	var ui := _find_any(skel, upper)
	var li := _find_any(skel, lower)
	if ui < 0 or li < 0:
		return {"pose": "unknown", "tilt": 0.0}
	var a := skel.get_bone_global_rest(ui).origin
	var b := skel.get_bone_global_rest(li).origin
	var v := b - a
	var len := v.length()
	if len < 0.0001:
		return {"pose": "unknown", "tilt": 0.0}
	var tilt := rad_to_deg(asin(clampf(-v.y / len, -1.0, 1.0)))
	var pose := "t"
	if tilt > 15.0:
		pose = "a"
	if absf(tilt) < 2.0:
		pose = "t"
	return {"pose": pose, "tilt": tilt}


static func _find_any(skel: Skeleton3D, candidates: PackedStringArray) -> int:
	for c in candidates:
		var idx := skel.get_bone_index(StringName(String(c)))
		if idx >= 0:
			return idx
	# loose match on normalized names
	var norm := PackedStringArray()
	for c in candidates:
		norm.append(RBName.normalize(String(c)))
	for i in range(skel.get_bone_count()):
		var bn := RBName.normalize(RBName.strip_prefixes(String(skel.get_bone_name(i))))
		for n in norm:
			if bn == String(n):
				return i
	return -1
