@tool
## Bone name -> canonical concept id resolution.
##
## One resolver is used for *both* sides of the mapping (arbitrary source rigs and
## Godot's SkeletonProfile bone lists), because SkeletonProfileHumanoid names are
## plain English anatomy too. Rules are ordered from most specific to least, and
## `spine`/finger/neck chains only carry a family + rank hint: the matcher
## renumbers chains by hierarchy depth, so naming differences like
## `Spine` / `Spine1` / `spine_01` / `spine.001` all land on the same ids.
class_name RBBones
extends RefCounted

## Concept families whose rank must be renumbered by hierarchy depth.
const CHAIN_FAMILIES: PackedStringArray = ["spine", "neck", "tail", "thumb", "index", "middle", "ring", "little"]

## Tokens that mark a bone as a deformer / helper. Such bones sit at the same depth as
## the real bone they follow, so they must never resolve to a concept (otherwise
## `upper_arm_twist` and `upper_arm` tie and the wrong one can win the slot).
const HELPER_TOKENS: PackedStringArray = [
	"twist", "bend", "helper", "setup", "ignore", "deform", "pole", "target", "mthd",
]


## Ordered anatomy rules. `flat` is matched against the name with separators
## removed, `tokens` against the token list. First hit wins, so keep specific first.
const RULES: Array = [
	# `toe` (not only `toes`) so `toe.L`, `Bip001 L Toe0`, `toe_slot_l` resolve too.
	{"flat": ["toebase", "toes", "toe", "ball", "football"], "c": "toes", "paired": true},
	{"flat": ["heel", "heelroll"], "c": "heel", "paired": true},
	{"flat": ["ankle", "foot", "feet"], "c": "foot", "paired": true},
	{"flat": ["lowerleg", "calf", "shin", "gaskin", "leglower"], "c": "lower_leg", "paired": true},
	{"flat": ["upperleg", "thigh", "upleg", "hipleg", "legupper"], "c": "upper_leg", "paired": true},
	{"flat": ["knee"], "c": "knee", "paired": true},
	{"flat": ["forearm", "lowerarm", "arm lower", "armlower", "radioulna"], "c": "lower_arm", "paired": true},
	{"flat": ["upperarm", "humerus", "armlower", "brachium"], "c": "upper_arm", "paired": true},
	{"flat": ["wrist", "hand"], "c": "hand", "paired": true},
	{"flat": ["clavicle", "shoulder"], "c": "shoulder", "paired": true},
	{"flat": ["scapula"], "c": "shoulder", "paired": true},
	{"flat": ["upperchest"], "c": "spine", "paired": false, "rank": 3},
	{"flat": ["chest"], "c": "spine", "paired": false, "rank": 2},
	{"flat": ["abdomen"], "c": "spine", "paired": false, "rank": 1},
	{"flat": ["spine", "vertebra", "back"], "c": "spine", "paired": false},
	{"flat": ["pelvis", "hips", "hip", "hipping"], "c": "hips", "paired": false},
	{"flat": ["neck"], "c": "neck", "paired": false},
	{"flat": ["head"], "c": "head", "paired": false},
	{"flat": ["jaw", "mandible", "chin"], "c": "jaw", "paired": false},
	{"flat": ["eye"], "c": "eye", "paired": true},
	{"flat": ["ear"], "c": "ear", "paired": true},
	{"flat": ["eyebrow", "cheek", "nose", "lip", "mouth", "tongue", "teeth", "brow"], "c": "face", "paired": true},
	{"flat": ["breast", "boob"], "c": "breast", "paired": true},
	{"flat": ["tail", "tailbone", "coccyx"], "c": "tail", "paired": false},
	{"flat": ["root"], "c": "root", "paired": false},
]

## Exact per-family overrides, consulted before the generic rules. Keys must be in
## `RBName.normalize()` form (lowercase, separators unified, camel preserved).
const FAMILY_TABLES: Dictionary = {
	"mixamo": {
		"upleg": "upper_leg",
		"leg": "lower_leg",
		"foot": "foot",
		"toebase": "toes",
		"forearm": "lower_arm",
		"arm": "upper_arm",
		"hand": "hand",
		"shoulder": "shoulder",
		"hips": "hips",
		"head": "head",
		"neck": "neck",
		"jaw": "jaw",
		"eye": "eye",
	},
	"unity": {
		"upperleg": "upper_leg",
		"lowerleg": "lower_leg",
		"leg": "lower_leg",
		"foot": "foot",
		"toes": "toes",
		"upperarm": "upper_arm",
		"lowerarm": "lower_arm",
		"arm": "upper_arm",
		"hand": "hand",
		"shoulder": "shoulder",
		"hips": "hips",
		"chest": "spine",
		"upperchest": "spine",
		"head": "head",
		"neck": "neck",
		"jaw": "jaw",
		"lefteye": "eye",
		"righteye": "eye",
	},
	"unreal": {
		"pelvis": "hips",
		"thigh": "upper_leg",
		"calf": "lower_leg",
		"foot": "foot",
		"ball": "toes",
		"upperarm": "upper_arm",
		"lowerarm": "lower_arm",
		"hand": "hand",
		"clavicle": "shoulder",
		"head": "head",
		"neck": "neck",
		"hand_r": "hand",
	},
	"vrm": {
		"hips": "hips",
		"spine": "spine",
		"chest": "spine",
		"upperchest": "spine",
		"neck": "neck",
		"head": "head",
		"leftshoulder": "shoulder",
		"rightshoulder": "shoulder",
		"leftupperarm": "upper_arm",
		"rightupperarm": "upper_arm",
		"leftlowerarm": "lower_arm",
		"rightlowerarm": "lower_arm",
		"lefthand": "hand",
		"righthand": "hand",
		"leftupperleg": "upper_leg",
		"rightupperleg": "upper_leg",
		"leftlowerleg": "lower_leg",
		"rightlowerleg": "lower_leg",
		"leftfoot": "foot",
		"rightfoot": "foot",
		"leettoes": "toes",
		"righttoes": "toes",
	},
	"actorcore": {
		"pelvis": "hips",
		"waist": "spine",
		"chest": "spine",
		"neck": "neck",
		"head": "head",
		"collar": "shoulder",
		"shoulder": "shoulder",
		"elbow": "lower_arm",
		"wrist": "hand",
		"knee": "lower_leg",
		"ankle": "foot",
		"toebase": "toes",
	},
	"rigify": {
		"torso": "spine",
		"pelvis": "hips",
		"chest": "spine",
		"waist": "spine",
		"shoulder": "shoulder",
		"upper_arm": "upper_arm",
		"forearm": "lower_arm",
		"hand": "hand",
		"thigh": "upper_leg",
		"shin": "lower_leg",
		"foot": "foot",
		"toes": "toes",
		"heel": "heel",
		"breast": "breast",
	},
	"godot_humanoid": {
		"hips": "hips",
		"spine": "spine",
		"spine1": "spine",
		"spine2": "spine",
		"chest": "spine",
		"upperchest": "spine",
		"neck": "neck",
		"neck1": "neck",
		"neck2": "neck",
		"head": "head",
		"jaw": "jaw",
		"leftankle": "foot",
		"rightankle": "foot",
		"lefttoes": "toes",
		"righttoes": "toes",
		"lefthand": "hand",
		"righthand": "hand",
	},
}

## Finger name -> canonical finger.
const FINGER_WORDS: Dictionary = {
	"thumb": "thumb",
	"pollex": "thumb",
	"index": "index",
	"pointer": "index",
	"forefinger": "index",
	"middle": "middle",
	"long": "middle",
	"center": "middle",
	"ring": "ring",
	"annular": "ring",
	"little": "little",
	"pinky": "little",
	"quinky": "little",
}

## Named ranks, palm outwards. Values only need to be monotonic.
const RANK_WORDS: Dictionary = {
	"metacarpal": 1,
	"proximal": 2,
	"intermediate": 3,
	"medial": 3,
	"middle": 3,
	"distal": 4,
	"terminal": 4,
	"end": 4,
	"tip": 4,
}

## Tokens that never carry anatomical meaning once stripped.
const IGNORED_TOKENS: PackedStringArray = [
	"l", "r", "left", "right", "lf", "rf", "lt", "rt", "side",
	"b", "f", "p", "ik", "fk", "limb", "bone", "joint", "def", "dup", "grp",
	"palm", "001", "002", "003", "01", "02", "03",
]


## True when the name looks like a helper / deformer bone.
static func is_helper(raw: String) -> bool:
	for t in RBName.tokens(raw):
		if HELPER_TOKENS.has(String(t)):
			return true
	return false


## Resolve a single bone name to a concept id (`"upper_arm.l"`, `"spine.02"`, ...),
## or `""` when nothing can be said about it.
static func resolve(raw: String, family: String = "") -> String:
	if raw == null or String(raw).is_empty():
		return ""
	var s := RBName.strip_prefixes(String(raw))
	var flat := RBName.normalize(s).replace("_", "")
	var toks := RBName.tokens(s)
	var side := RBName.side_of(s)
	var core := _core_tokens(toks)
	var core_flat := "_".join(core).replace("_", "")

	# 1) finger chains
	var fi := finger_info(s)
	if not fi.is_empty():
		return "%s.%02d.%s" % [fi["finger"], maxi(1, int(fi["rank"])), "l" if int(fi["side"]) == 0 else "r"]

	# 2) exact family table
	if family != "" and FAMILY_TABLES.has(family):
		var t: Dictionary = FAMILY_TABLES[family]
		for probe in [core_flat, flat, "_".join(core)]:
			if t.has(probe):
				var base := String(t[probe])
				return _finalize(base, side, RBName.ordinal_of(s), 0)
	for key in FAMILY_TABLES.keys():
		if String(key) == family:
			continue
		var tt: Dictionary = FAMILY_TABLES[key]
		if tt.has(core_flat):
			return _finalize(String(tt[core_flat]), side, RBName.ordinal_of(s), 0)

	# 3) generic ordered rules
	for rule in RULES:
		var needles: Array = rule["flat"]
		var found := false
		for nd in needles:
			var n := String(nd).replace("_", "").replace(" ", "")
			if core_flat == n or core_flat.begins_with(n) or core_flat.ends_with(n) or core_flat.contains(n):
				found = true
				break
		if not found:
			continue
		var base2 := String(rule["c"])
		var rank := int(rule.get("rank", 0))
		if rank == 0 and (base2 == "spine" or base2 == "neck" or base2 == "tail"):
			rank = maxi(1, RBName.ordinal_of(s))
		return _finalize(base2, side, rank, 0)

	# 4) `arm`/`leg` bare fallbacks after nothing else matched
	if core_flat.contains("arm"):
		return _finalize("upper_arm", side, 0, 0)
	if core_flat.contains("leg"):
		return _finalize("lower_leg", side, 0, 0)
	if core_flat.contains("finger"):
		return ""
	return ""


## Finger detection: `{finger, rank, side}` or `{}`.
static func finger_info(raw: String) -> Dictionary:
	var s := RBName.strip_prefixes(String(raw))
	var toks := RBName.tokens(s)
	var finger := ""
	for t in toks:
		var low := String(t).to_lower()
		if FINGER_WORDS.has(low):
			finger = String(FINGER_WORDS[low])
			break
	if finger.is_empty():
		return {}
	var side := RBName.side_of(s)
	if side < 0:
		return {}
	var rank := RBName.ordinal_of(s)
	var from_digit := rank > 0
	if rank == 0:
		for t in toks:
			var low2 := String(t).to_lower()
			if RANK_WORDS.has(low2):
				rank = int(RANK_WORDS[low2])
				break
	if rank == 0:
		rank = 1
	# Non-thumb fingers start at the metacarpal only for thumbs, so shift the named
	# ranks down one; the matcher renumbers chains by depth anyway.
	if not from_digit and finger != "thumb" and rank > 1:
		rank -= 1
	return {"finger": finger, "rank": rank, "side": side}


## Strips side / noise tokens so `left_upper_arm_001` and `upper_arm` compare equal.
static func _core_tokens(toks: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for t in toks:
		var low := String(t).to_lower()
		if low in IGNORED_TOKENS:
			continue
		if low.is_valid_int():
			continue
		out.append(low)
	return out


static func _finalize(base: String, side: int, rank: int, _unused: int = 0) -> String:
	match base:
		"hips", "head", "jaw", "root":
			return base
		"spine", "neck", "tail":
			return "%s.%02d" % [base, maxi(1, rank)]
		"face", "breast", "knee":
			# Not part of the retarget vocabulary: better unmapped than wrong.
			return ""
		_:
			if side < 0:
				return ""
			return "%s.%s" % [base, "l" if side == 0 else "r"]


## Which family a bone-name set smells like; purely informational, plus it lets the
## exact tables take priority. Returns `{"family": String, "score": float}`.
static func detect_family(bone_names: PackedStringArray) -> Dictionary:
	var best := {"family": "unknown", "score": 0.0, "hits": 0, "total": bone_names.size()}
	var probes: PackedStringArray = []
	for b in bone_names:
		probes.append(RBName.normalize(RBName.strip_prefixes(String(b))).replace("_", ""))
	for key in FAMILY_TABLES.keys():
		var t: Dictionary = FAMILY_TABLES[key]
		var hits := 0
		for p in probes:
			if t.has(p):
				hits += 1
		var sc := 0.0
		if not probes.is_empty():
			sc = float(hits) / float(probes.size())
		if sc > float(best["score"]):
			best = {"family": String(key), "score": sc, "hits": hits, "total": probes.size()}
	return best


## Concept id without rank, e.g. `spine.02` -> `spine`.
static func family_of(concept: String) -> String:
	if concept.is_empty():
		return ""
	return concept.get_slice(".", 0)


## Concept id side suffix, e.g. `upper_arm.l` -> `l`.
static func side_of_concept(concept: String) -> int:
	if concept.ends_with(".l"):
		return 0
	if concept.ends_with(".r"):
		return 1
	return -1
