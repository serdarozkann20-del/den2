@tool
## Builds and persists `BoneMap` resources from a matching report.
extends RefCounted

const RBBones := preload("./rb_bones.gd")
const RBMatcher := preload("./rb_matcher.gd")
const RBPreset := preload("./rb_preset.gd")
const RBRig := preload("./rb_rig.gd")
const DEFAULT_SKELETON_NAME := "GeneralSkeleton"


static func humanoid_profile() -> SkeletonProfile:
	return SkeletonProfileHumanoid.new()


## Analyze any Skeleton3D against a profile.
## Returns `{rig, target_rig, report, family, profile}`.
static func analyze(skel: Skeleton3D, profile: SkeletonProfile = null, opts: Dictionary = {}) -> Dictionary:
	if profile == null:
		profile = humanoid_profile()
	var raw_names := PackedStringArray()
	if skel != null:
		for i in range(skel.get_bone_count()):
			raw_names.append(String(skel.get_bone_name(i)))
	var fam := RBBones.detect_family(raw_names)
	var source := RBRig.from_skeleton(skel, String(fam["family"]))
	var target := RBRig.from_profile(profile, "godot_humanoid")
	var report := RBMatcher.match_rigs(source, target, opts)
	return {
		"rig": source,
		"target_rig": target,
		"report": report,
		"family": fam,
		"profile": profile,
	}


## `{profile_bone: skeleton_bone}` -> BoneMap.
static func build(profile: SkeletonProfile, mapping: Dictionary) -> BoneMap:
	var map := BoneMap.new()
	map.profile = profile
	for k in mapping.keys():
		var profile_bone := String(k)
		var bone := String(mapping[k])
		if bone.is_empty():
			continue
		map.set_skeleton_bone_name(StringName(profile_bone), StringName(bone))
	return map


## Write the BoneMap next to the rig it belongs to.
static func save(map: BoneMap, path: String) -> Error:
	if map == null or path.is_empty():
		return ERR_INVALID_PARAMETER
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return ResourceSaver.save(map, path, ResourceSaver.FLAG_CHANGE_PATH)


## Path used for generated maps, keeps one file per rig shape so re-runs are cheap.
static func map_path_for(source_file: String, skeleton_name: String, out_dir: String) -> String:
	var stem := source_file.get_file().get_basename()
	var clean := RBPreset.sanitize(stem + "_" + skeleton_name)
	return out_dir.path_join(clean + "_bonemap.tres")


## Convenience: analyze + build + save for a scene file's first Skeleton3D.
static func generate_for_file(
	source_file: String,
	out_dir: String,
	profile: SkeletonProfile = null,
	opts: Dictionary = {}
) -> Dictionary:
	var skel := RBPreset.find_skeleton_in_file(source_file)
	if skel == null:
		return {"error": "no Skeleton3D found in " + source_file}
	var res := analyze(skel as Skeleton3D, profile, opts)
	var name := String(skel.get_name())
	var map := build(res["profile"] as SkeletonProfile, res["report"]["mapping"])
	var path := map_path_for(source_file, name, out_dir)
	var err := save(map, path)
	if err != OK:
		return {"error": "cannot save BoneMap to %s (%s)" % [path, error_string(err)]}
	return {
		"path": path,
		"map": map,
		"report": res["report"],
		"rig": res["rig"],
		"target_rig": res["target_rig"],
		"family": res["family"],
		"skeleton": name,
	}
