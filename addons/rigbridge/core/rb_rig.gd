@tool
## Snapshot of a rig (real Skeleton3D or a SkeletonProfile) in a plain Dictionary so
## that matching, reporting and presets can all work on the same shape.
##
## shape: {
##   names:    PackedStringArray  # bone names, index == bone index
##   parents:  PackedStringArray  # parent bone name or ""
##   depths:   PackedInt32Array   # distance from the root, in bones
##   lengths:  PackedFloat64Array # rest length proxy (0.0 when unknown)
##   concepts: PackedStringArray  # canonical concept id or ""
##   required: PackedInt32Array   # 1 = needed for a usable humanoid retarget
##   kind:     String             # "skeleton" | "profile"
## }
class_name RBRig
extends RefCounted


static func from_skeleton(skel: Skeleton3D, family: String = "") -> Dictionary:
	var rig := {
		"names": PackedStringArray(),
		"parents": PackedStringArray(),
		"depths": PackedInt32Array(),
		"lengths": PackedFloat64Array(),
		"concepts": PackedStringArray(),
		"required": PackedInt32Array(),
		"kind": "skeleton",
	}
	if skel == null:
		return rig
	var count := skel.get_bone_count()
	var names := PackedStringArray()
	for i in range(count):
		names.append(String(skel.get_bone_name(i)))
	for i in range(count):
		var p := skel.get_bone_parent(i)
		var pname := ""
		if p >= 0 and p < count:
			pname = names[p]
		(rig["parents"] as PackedStringArray).append(pname)
		(rig["names"] as PackedStringArray).append(names[i])
		(rig["lengths"] as PackedFloat64Array).append(skel.get_bone_rest(i).origin.length())
	rig["depths"] = _depths(rig["parents"])
	rig["concepts"] = _concepts(names, family)
	rig["required"] = _required(rig["concepts"])
	renumber_chains(rig)
	return rig


static func from_profile(profile: SkeletonProfile, family: String = "") -> Dictionary:
	var rig := {
		"names": PackedStringArray(),
		"parents": PackedStringArray(),
		"depths": PackedInt32Array(),
		"lengths": PackedFloat64Array(),
		"concepts": PackedStringArray(),
		"required": PackedInt32Array(),
		"kind": "profile",
	}
	if profile == null:
		return rig
	var count: int = profile.get_bone_size()
	var names := PackedStringArray()
	for i in range(count):
		names.append(String(profile.get_bone_name(i)))
	var parents := PackedStringArray()
	for i in range(count):
		var pname := ""
		if profile.has_method("get_bone_parent"):
			pname = String(profile.get_bone_parent(i))
		parents.append(pname)
	rig["names"] = names
	rig["parents"] = parents
	rig["depths"] = _depths(parents)
	rig["lengths"] = PackedFloat64Array()
	for i in range(count):
		(rig["lengths"] as PackedFloat64Array).append(0.0)
	rig["concepts"] = _concepts(names, family)
	var req := PackedInt32Array()
	for i in range(count):
		var is_req := 1
		if profile.has_method("is_required"):
			is_req = 1 if bool(profile.is_required(i)) else 0
		else:
			is_req = _required_one(String(rig["concepts"][i]))
		req.append(is_req)
	rig["required"] = req
	renumber_chains(rig)
	return rig


static func _concepts(names: PackedStringArray, family: String) -> PackedStringArray:
	var out := PackedStringArray()
	for n in names:
		if RBBones.is_helper(String(n)):
			out.append("")
			continue
		out.append(RBBones.resolve(String(n), family))
	return out


static func _depths(parents: PackedStringArray) -> PackedInt32Array:
	# Depth by walking parents by name; memoised, cycle-safe.
	var index := {}
	for i in range(parents.size()):
		index[String(parents[i])] = i
	var out := PackedInt32Array()
	for i in range(parents.size()):
		out.append(-1)
	for i in range(parents.size()):
		var d := 0
		var cur := i
		var seen := {}
		while true:
			var p := String(parents[cur])
			if p.is_empty() or not index.has(p) or seen.has(p):
				break
			seen[p] = true
			cur = int(index[p])
			d += 1
			if d > 64:
				break
		out[i] = d
	return out


static func _required(concepts: PackedStringArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	for c in concepts:
		out.append(_required_one(String(c)))
	return out


static func _required_one(concept: String) -> int:
	if concept.is_empty():
		return 0
	return 1 if concept in RBConcepts.required_concepts() else 0


## Chain families (spine/neck/tail/fingers) get their rank renumbered by hierarchy
## depth so that `Spine`/`Spine1`/`spine_01`/`spine.001` become comparable ids.
static func renumber_chains(rig: Dictionary) -> void:
	var names: PackedStringArray = rig["names"]
	var concepts: PackedStringArray = rig["concepts"]
	var depths: PackedInt32Array = rig["depths"]
	var groups := {}
	for i in range(names.size()):
		var c := String(concepts[i])
		if c.is_empty():
			continue
		var fam := RBBones.family_of(c)
		if fam not in RBBones.CHAIN_FAMILIES:
			continue
		var side := RBBones.side_of_concept(c)
		var grp_key := "%s|%d" % [fam, side]
		if not groups.has(grp_key):
			groups[grp_key] = []
		(groups[grp_key] as Array).append(i)
	for key in groups.keys():
		var idx: Array = groups[key]
		if idx.size() < 2:
			continue
		var sorted := _sort_by_depth(idx, depths)
		for rank in range(sorted.size()):
			var pos := int(sorted[rank])
			var fam2 := RBBones.family_of(String(concepts[pos]))
			var side2 := RBBones.side_of_concept(String(concepts[pos]))
			var id := ""
			if side2 < 0:
				id = "%s.%02d" % [fam2, rank + 1]
			else:
				id = "%s.%02d.%s" % [fam2, rank + 1, "l" if side2 == 0 else "r"]
			concepts[pos] = id
	rig["concepts"] = concepts


## Small helper: insertion sort by depth (chains are tiny).
static func _sort_by_depth(idx: Array, depths: PackedInt32Array) -> Array:
	var out := idx.duplicate()
	for i in range(1, out.size()):
		var j := i
		while j > 0 and depths[int(out[j])] < depths[int(out[j - 1])]:
			var tmp = out[j]
			out[j] = out[j - 1]
			out[j - 1] = tmp
			j -= 1
	return out


static func bone_count(rig: Dictionary) -> int:
	return (rig["names"] as PackedStringArray).size()


static func summary(rig: Dictionary) -> String:
	var mapped := 0
	var concepts: PackedStringArray = rig["concepts"]
	for c in concepts:
		if not String(c).is_empty():
			mapped += 1
	return "%s bones=%d resolved=%d" % [String(rig.get("kind", "?")), rig["names"].size(), mapped]
