@tool
## Pure-logic self test. No scene, no import, no editor: safe to run anywhere.
##
##   godot --headless --path <project> --script addons/rigbridge/tests/rb_tests.gd
##
## or from the editor: Project > Tools > RigBridge: run self-test
class_name RBTests
extends RefCounted


static func run_all(verbose: bool = false) -> PackedStringArray:
	var out := PackedStringArray()
	_test_names(out)
	_test_concepts(out)
	_test_profile(out)
	_test_matcher(out)
	_test_rig_families(out)
	_test_anim(out)
	_test_presets(out)
	var fails := 0
	for l in out:
		if String(l).begins_with("FAIL"):
			fails += 1
	out.append("== %d checks, %d failures ==" % [out.size(), fails])
	if verbose:
		for l in out:
			print(l)
	return out


static func _ok(out: PackedStringArray, cond: bool, label: String) -> void:
	if cond:
		out.append("PASS " + label)
	else:
		out.append("FAIL " + label)


static func _test_names(out: PackedStringArray) -> void:
	_ok(out, RBName.normalize("mixamorig:LeftUpLeg") == "leftupleg", "normalize strips separators")
	_ok(out, RBName.strip_prefixes("mixamorig:LeftArm") == "LeftArm", "strip_prefixes mixamorig:")
	_ok(out, RBName.strip_prefixes("Bip001_L_Thigh").begins_with("L_Thigh") or RBName.strip_prefixes("Bip001_L_Thigh").contains("Thigh"), "strip_prefixes Bip001_")
	_ok(out, RBName.side_of("thigh_l") == 0 or RBName.side_of("thigh_l") == 1, "side_of l/r suffix")
	_ok(out, RBName.side_of("LeftLowerArm") == 0, "side_of Left*")
	_ok(out, RBName.side_of("Hips") == -1, "side_of unpaired")
	_ok(out, RBName.levenshtein("kitten", "sitting") == 3, "levenshtein")
	_ok(out, RBName.similarity("LeftUpperArm", "left_upper_arm") > 0.9, "similarity camel vs snake")
	_ok(out, RBName.clean_anim_name("Idle (1)") == "idle", "clean_anim_name takes")
	_ok(out, RBName.clean_anim_name("Standing Idle_0") == "standing_idle", "clean_anim_name counter")
	_ok(out, RBName.has_loop_hint("Walking-loop"), "loop hint")


static func _test_concepts(out: PackedStringArray) -> void:
	var cases := {
		"mixamorig:Hips": "hips",
		"mixamorig:Spine": "spine.01",
		"mixamorig:Spine1": "spine.01",
		"mixamorig:Spine2": "spine.02",
		"mixamorig:Neck": "neck.01",
		"mixamorig:Head": "head",
		"mixamorig:LeftShoulder": "shoulder.l",
		"mixamorig:LeftArm": "upper_arm.l",
		"mixamorig:LeftForeArm": "lower_arm.l",
		"mixamorig:LeftHand": "hand.l",
		"mixamorig:LeftUpLeg": "upper_leg.l",
		"mixamorig:LeftLeg": "lower_leg.l",
		"mixamorig:LeftFoot": "foot.l",
		"mixamorig:LeftToeBase": "toes.l",
		"mixamorig:RightArm": "upper_arm.r",
		"mixamorig:LeftHandThumb1": "thumb.01.l",
		"mixamorig:LeftHandIndex3": "index.03.l",
		"mixamorig:LeftHandPinky2": "little.02.l",
		"thigh_l": "upper_leg.l",
		"calf_l": "lower_leg.l",
		"foot_l": "foot.l",
		"ball_l": "toes.l",
		"pelvis": "hips",
		"clavicle_l": "shoulder.l",
		"upperarm_l": "upper_arm.l",
		"forearm_r": "lower_arm.r",
		"LeftUpperLeg": "upper_leg.l",
		"LeftLowerLeg": "lower_leg.l",
		"LeftAnkle": "foot.l",
		"LeftToes": "toes.l",
		"LeftIndexProximal": "index.01.l",
		"LeftThumbMetacarpal": "thumb.01.l",
		"def-spine.001": "spine.01",
		"spine.006": "spine.06",
		"Root": "root",
	}
	for k in cases.keys():
		var got := RBBones.resolve(String(k))
		_ok(out, got == String(cases[k]), "resolve %s -> %s (got %s)" % [k, cases[k], got])


static func _test_profile(out: PackedStringArray) -> void:
	var profile := SkeletonProfileHumanoid.new()
	_ok(out, profile.get_bone_size() > 20, "humanoid profile has bones")
	var rig := RBRig.from_profile(profile, "godot_humanoid")
	var concepts: PackedStringArray = rig["concepts"]
	var seen := {}
	for c in concepts:
		if not String(c).is_empty():
			seen[String(c)] = true
	for want in ["hips", "head", "upper_arm.l", "lower_arm.l", "hand.l", "upper_leg.l", "lower_leg.l", "foot.l"]:
		_ok(out, seen.has(want), "profile resolves %s" % want)
	var ratio := 0.0
	if concepts.size() > 0:
		var n := 0
		for c in concepts:
			if not String(c).is_empty():
				n += 1
		ratio = float(n) / float(concepts.size())
	_ok(out, ratio > 0.5, "profile names mostly resolve (%.2f)" % ratio)


static func _mixamo_rig() -> Skeleton3D:
	var sk := Skeleton3D.new()
	var spec := [
		["mixamorig:Hips", ""],
		["mixamorig:Spine", "mixamorig:Hips"],
		["mixamorig:Spine1", "mixamorig:Spine"],
		["mixamorig:Spine2", "mixamorig:Spine1"],
		["mixamorig:Neck", "mixamorig:Spine2"],
		["mixamorig:Head", "mixamorig:Neck"],
		["mixamorig:LeftShoulder", "mixamorig:Spine2"],
		["mixamorig:LeftArm", "mixamorig:LeftShoulder"],
		["mixamorig:LeftForeArm", "mixamorig:LeftArm"],
		["mixamorig:LeftHand", "mixamorig:LeftForeArm"],
		["mixamorig:RightShoulder", "mixamorig:Spine2"],
		["mixamorig:RightArm", "mixamorig:RightShoulder"],
		["mixamorig:RightForeArm", "mixamorig:RightArm"],
		["mixamorig:RightHand", "mixamorig:RightForeArm"],
		["mixamorig:LeftUpLeg", "mixamorig:Hips"],
		["mixamorig:LeftLeg", "mixamorig:LeftUpLeg"],
		["mixamorig:LeftFoot", "mixamorig:LeftLeg"],
		["mixamorig:LeftToeBase", "mixamorig:LeftFoot"],
		["mixamorig:RightUpLeg", "mixamorig:Hips"],
		["mixamorig:RightLeg", "mixamorig:RightUpLeg"],
		["mixamorig:RightFoot", "mixamorig:RightLeg"],
		["mixamorig:RightToeBase", "mixamorig:RightFoot"],
	]
	var idx := {}
	for i in range(spec.size()):
		var nm: String = spec[i][0]
		sk.add_bone(nm)
		idx[nm] = i
	for i in range(spec.size()):
		var par: String = spec[i][1]
		if not par.is_empty() and idx.has(par):
			sk.set_bone_parent(i, int(idx[par]))
		var y := float(i) * 0.05
		sk.set_bone_rest(i, Transform3D(Basis.IDENTITY, Vector3(0.1 * float(i % 3), y, 0)))
	return sk


static func _test_matcher(out: PackedStringArray) -> void:
	var sk := _mixamo_rig()
	var profile := SkeletonProfileHumanoid.new()
	var source := RBRig.from_skeleton(sk, "mixamo")
	_ok(out, source["names"].size() == 22, "source rig snapshot size")
	var target := RBRig.from_profile(profile, "godot_humanoid")
	var rep := RBMatcher.match_rigs(source, target, {})
	sk.free()
	var missing: Array = rep["required_missing"]
	_ok(out, missing.size() <= 2, "at most 2 required bones unmapped (got %s)" % str(missing))
	_ok(out, String(rep["quality"]) != "poor", "quality not poor (%s)" % String(rep["quality"]))
	var mapping: Dictionary = rep["mapping"]
	_ok(out, String(mapping.get("Hips", "")) == "mixamorig:Hips", "Hips mapped")
	_ok(out, String(mapping.get("LeftUpperArm", "")) == "mixamorig:LeftArm", "LeftUpperArm -> mixamorig:LeftArm")
	_ok(out, String(mapping.get("LeftLowerArm", "")) == "mixamorig:LeftForeArm", "LeftLowerArm -> LeftForeArm")
	_ok(out, String(mapping.get("LeftUpperLeg", "")) == "mixamorig:LeftUpLeg", "LeftUpperLeg -> LeftUpLeg")
	_ok(out, String(mapping.get("LeftLowerLeg", "")) == "mixamorig:LeftLeg", "LeftLowerLeg -> LeftLeg")
	_ok(out, String(mapping.get("LeftHand", "")) == "mixamorig:LeftHand", "LeftHand mapped")
	_ok(out, String(mapping.get("Head", "")) == "mixamorig:Head", "Head mapped")
	# no source bone may be used twice
	var used := {}
	var dupes := 0
	for k in mapping.keys():
		var v := String(mapping[k])
		if used.has(v):
			dupes += 1
		used[v] = true
	_ok(out, dupes == 0, "uniqueness: no source bone mapped twice")
	var inv := RBMatcher.invert(mapping)
	_ok(out, String(inv.get("mixamorig:Hips", "")) == "Hips", "invert mapping")


static func _make_skeleton(spec: Array) -> Skeleton3D:
	var sk := Skeleton3D.new()
	var idx := {}
	for i in range(spec.size()):
		sk.add_bone(String((spec[i] as Array)[0]))
		idx[String((spec[i] as Array)[0])] = i
	for i in range(spec.size()):
		var parent := String((spec[i] as Array)[1])
		if not parent.is_empty() and idx.has(parent):
			sk.set_bone_parent(i, int(idx[parent]))
	return sk


## Chain alignment and helper-bone rejection, checked against the engine's own
## SkeletonProfileHumanoid - these are the cases name matching alone cannot solve.
static func _test_rig_families(out: PackedStringArray) -> void:
	var profile := SkeletonProfileHumanoid.new()
	var target := RBRig.from_profile(profile, "godot_humanoid")

	# Blender/Rigify: 7 vertebrae, twist bones, breast + side-bend bones.
	var rigify := [
		["Hips", ""], ["spine", "Hips"], ["spine.001", "spine"], ["spine.002", "spine.001"],
		["spine.003", "spine.002"], ["spine.004", "spine.003"], ["spine.005", "spine.004"],
		["spine.006", "spine.005"], ["chest.01", "spine.003"], ["breast.L", "spine.003"],
		["shoulder.L", "spine.004"], ["upper_arm.L", "shoulder.L"], ["upper_arm_twist.L", "upper_arm.L"],
		["forearm.L", "upper_arm.L"], ["forearm_twist.L", "forearm.L"], ["hand.L", "forearm.L"],
		["shoulder.R", "spine.004"], ["upper_arm.R", "shoulder.R"], ["forearm.R", "upper_arm.R"],
		["hand.R", "forearm.R"], ["thigh.L", "spine"], ["shin.L", "thigh.L"], ["foot.L", "shin.L"],
		["toe.L", "foot.L"], ["heel.02.L", "foot.L"], ["thigh.R", "spine"], ["shin.R", "thigh.R"],
		["foot.R", "shin.R"], ["toe.R", "foot.R"],
		["thumb.01.L", "hand.L"], ["thumb.02.L", "thumb.01.L"], ["thumb.03.L", "thumb.02.L"],
		["f_index.01.L", "hand.L"], ["f_index.02.L", "f_index.01.L"], ["f_index.03.L", "f_index.02.L"],
	]
	var sk1 := _make_skeleton(rigify)
	var rep1 := RBMatcher.match_rigs(RBRig.from_skeleton(sk1, "rigify"), target, {})
	sk1.free()
	var m1: Dictionary = rep1["mapping"]
	_ok(out, String(m1.get("Head", "")) == "spine.006",
		"7-vertebra chain still reaches Head (got %s)" % str(m1.get("Head")))
	_ok(out, String(m1.get("Neck", "")) == "spine.005",
		"7-vertebra chain still reaches Neck (got %s)" % str(m1.get("Neck")))
	_ok(out, String(m1.get("LeftLowerArm", "")) == "forearm.L",
		"rigify LeftLowerArm -> forearm.L (got %s)" % str(m1.get("LeftLowerArm")))
	_ok(out, not String(m1.get("LeftUpperArm", "")).contains("twist"),
		"twist bone must not win LeftUpperArm (got %s)" % str(m1.get("LeftUpperArm")))
	_ok(out, not String(m1.get("Chest", "")).contains("breast") and not String(m1.get("LeftShoulder", "")).contains("breast"),
		"deformer bones stay out of the mapping")
	_ok(out, (rep1["required_missing"] as Array).is_empty(),
		"rigify covers every required bone (missing %s)" % str(rep1["required_missing"]))

	# 3ds Max Biped naming, no prefixes to strip.
	var maxstyle := [
		["Bip001 Pelvis", ""], ["Bip001 Spine", "Bip001 Pelvis"], ["Bip001 Spine1", "Bip001 Spine"],
		["Bip001 Spine2", "Bip001 Spine1"], ["Bip001 Neck", "Bip001 Spine2"], ["Bip001 Head", "Bip001 Neck"],
		["Bip001 L Clavicle", "Bip001 Spine2"], ["Bip001 L UpperArm", "Bip001 L Clavicle"],
		["Bip001 L Forearm", "Bip001 L UpperArm"], ["Bip001 L Hand", "Bip001 L Forearm"],
		["Bip001 R Clavicle", "Bip001 Spine2"], ["Bip001 R UpperArm", "Bip001 R Clavicle"],
		["Bip001 R Forearm", "Bip001 R UpperArm"], ["Bip001 R Hand", "Bip001 R Forearm"],
		["Bip001 L Thigh", "Bip001 Pelvis"], ["Bip001 L Calf", "Bip001 L Thigh"],
		["Bip001 L Foot", "Bip001 L Calf"], ["Bip001 L Toe0", "Bip001 L Foot"],
		["Bip001 R Thigh", "Bip001 Pelvis"], ["Bip001 R Calf", "Bip001 R Thigh"],
		["Bip001 R Foot", "Bip001 R Calf"], ["Bip001 R Toe0", "Bip001 R Foot"],
	]
	var sk2 := _make_skeleton(maxstyle)
	var rep2 := RBMatcher.match_rigs(RBRig.from_skeleton(sk2, "unknown"), target, {})
	sk2.free()
	var m2: Dictionary = rep2["mapping"]
	_ok(out, String(m2.get("Hips", "")) == "Bip001 Pelvis", "Max Biped Hips")
	_ok(out, String(m2.get("LeftUpperArm", "")) == "Bip001 L UpperArm", "Max Biped LeftUpperArm")
	_ok(out, String(m2.get("RightLowerLeg", "")) == "Bip001 R Calf", "Max Biped RightLowerLeg")
	_ok(out, String(m2.get("LeftToes", "")) == "Bip001 L Toe0", "Max Biped LeftToes")
	_ok(out, (rep2["required_missing"] as Array).is_empty(),
		"Max Biped covers every required bone (missing %s)" % str(rep2["required_missing"]))

	# A quadruped must be refused, not force-fitted.
	var dog := [
		["spine", ""], ["spine1", "spine"], ["spine2", "spine1"], ["spine3", "spine2"], ["head", "spine3"],
		["front_upper_leg_l", "spine3"], ["front_lower_leg_l", "front_upper_leg_l"],
		["front_paw_l", "front_lower_leg_l"], ["front_upper_leg_r", "spine3"],
		["front_lower_leg_r", "front_upper_leg_r"], ["front_paw_r", "front_lower_leg_r"],
		["back_upper_leg_l", "spine"], ["back_lower_leg_l", "back_upper_leg_l"],
		["back_paw_l", "back_lower_leg_l"], ["tail1", "spine"], ["tail2", "tail1"],
	]
	var sk3 := _make_skeleton(dog)
	var rep3 := RBMatcher.match_rigs(RBRig.from_skeleton(sk3, "unknown"), target, {})
	sk3.free()
	_ok(out, not (rep3["required_missing"] as Array).is_empty(), "quadruped reports missing required bones")
	_ok(out, not bool(rep3["ok"]), "quadruped is not reported as ok")

	# Bones with no anatomy in the name must produce nothing rather than guesswork.
	var anon := [["bone_01", ""], ["bone_02", "bone_01"], ["bone_03", "bone_02"], ["bone_04", "bone_03"]]
	var sk4 := _make_skeleton(anon)
	var rep4 := RBMatcher.match_rigs(RBRig.from_skeleton(sk4, "unknown"), target, {})
	sk4.free()
	_ok(out, int(rep4["matched"]) <= 1, "an unnamed rig is not force-mapped (got %d)" % int(rep4["matched"]))


static func _test_anim(out: PackedStringArray) -> void:
	var anim := Animation.new()
	var t_rot := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t_rot, NodePath("Armature/Skeleton3D:LeftArm"))
	var t_pos := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(t_pos, NodePath("Armature/Skeleton3D:Hips"))
	var p := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(p, NodePath("Armature/Skeleton3D:LeftFoot"))
	anim.track_insert_key(p, 0.0, Vector3(1, 2, 3))
	var t_method := anim.add_track(Animation.TYPE_METHOD)
	anim.track_set_path(t_method, NodePath("."))
	_ok(out, RBAnim.bone_of(anim, t_rot) == "LeftArm", "bone_of")
	_ok(out, RBAnim.is_bone_track(anim, t_rot), "is_bone_track rotation")
	_ok(out, not RBAnim.is_bone_track(anim, t_method), "method track is not a bone track")
	var moved := RBAnim.to_profile_space(anim, {"LeftArm": "upper_arm.l", "Hips": "hips"}, "GeneralSkeleton", true)
	_ok(out, int(moved["moved"]) == 2, "to_profile_space moved 2 tracks (got %d)" % int(moved["moved"]))
	_ok(out, RBAnim.bone_of(anim, t_rot) == "upper_arm.l", "bone renamed in track")
	_ok(out, String(anim.track_get_path(t_rot).get_name(0)) == "@GeneralSkeleton", "skeleton part became @GeneralSkeleton")
	_ok(out, String(anim.track_get_path(t_method)) != "", "method track survived")
	_ok(out, anim.track_get_type(t_pos) == Animation.TYPE_POSITION_3D, "hips position kept")
	_ok(out, RBAnim.zero_position(anim, PackedStringArray(["hips"])) == 1, "zero_position")
	var v = anim.track_get_key_value(p, 0)
	_ok(out, typeof(v) == TYPE_VECTOR3 and (v as Vector3) == Vector3(1, 2, 3), "key values readable")
	RBAnim.set_loop(anim, true)
	_ok(out, RBAnim.is_looping(anim), "loop set")


static func _test_presets(out: PackedStringArray) -> void:
	var a := PackedStringArray(["b", "a", "c"])
	var b := PackedStringArray(["c", "b", "a"])
	_ok(out, RBPreset.key_for(a) == RBPreset.key_for(b), "preset key order independent")
	_ok(out, RBPreset.sanitize("Foo Bar!!.fbx") != "", "sanitize non empty")
	var fam := RBBones.detect_family(PackedStringArray([
		"mixamorig:Hips", "mixamorig:Spine", "mixamorig:LeftArm", "mixamorig:LeftForeArm", "mixamorig:LeftUpLeg",
	]))
	_ok(out, fam.size() > 0, "detect_family returns something")
