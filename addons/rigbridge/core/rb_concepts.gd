@tool
## Canonical humanoid "concept" identifiers.
##
## The whole point of this file is that RigBridge never matches bone *names*
## directly. Both sides (any source rig, and Godot's SkeletonProfile) are first
## resolved to a concept id, and matching happens concept-to-concept. That makes
## the matcher independent of naming conventions on either side, including future
## renames inside SkeletonProfileHumanoid.
extends RefCounted

# Order matters only for reporting; matching uses the ids.
const CONCEPTS: PackedStringArray = [
	"root",
	"hips",
	"spine.01",
	"spine.02",
	"spine.03",
	"neck.01",
	"neck.02",
	"head",
	"eye.l",
	"eye.r",
	"ear.l",
	"ear.r",
	"jaw",
	"shoulder.l",
	"shoulder.r",
	"upper_arm.l",
	"upper_arm.r",
	"lower_arm.l",
	"lower_arm.r",
	"hand.l",
	"hand.r",
	"upper_leg.l",
	"upper_leg.r",
	"lower_leg.l",
	"lower_leg.r",
	"foot.l",
	"foot.r",
	"toes.l",
	"toes.r",
	"heel.l",
	"heel.r",
	"middle_tail",
	"tail.01",
	"tail.02",
	"tail.03",
]

const FINGERS: PackedStringArray = ["thumb", "index", "middle", "ring", "little"]
const FINGER_ALIASES: Dictionary = {
	"thumb": "thumb",
	"1": "thumb",
	"index": "index",
	"pointer": "index",
	"first": "index",
	"middle": "middle",
	"long": "middle",
	"center": "middle",
	"third": "middle",
	"ring": "ring",
	"fourth": "ring",
	"little": "little",
	"pinky": "little",
	"fifth": "little",
}

# Named ranks, lowest (closest to the palm) first.
const FINGER_RANKS: PackedStringArray = [
	"metacarpal",
	"proximal",
	"intermediate",
	"middle",
	"distal",
	"end",
	"tip",
]


## Returns the concept id list for finger bones, e.g. `index.01.l`.
static func finger_concept(finger: String, rank: int, side: int) -> String:
	if finger not in FINGERS:
		return ""
	var sfx: String = _side_suffix(side)
	if sfx.is_empty():
		return ""
	return "%s.%02d.%s" % [finger, rank, sfx]


## All finger concept ids for a finger+side, ordered from palm outwards.
static func finger_chain(finger: String, side: int, count: int) -> PackedStringArray:
	var out := PackedStringArray()
	var sfx: String = _side_suffix(side)
	if sfx.is_empty():
		return out
	for i in range(1, count + 1):
		out.append("%s.%02d.%s" % [finger, i, sfx])
	return out


static func all_concepts() -> PackedStringArray:
	var out := CONCEPTS.duplicate()
	for f in FINGERS:
		for side in [0, 1]:
			for i in range(1, 4):
				out.append("%s.%02d.%s" % [f, i, "l" if side == 0 else "r"])
	return out


static func _side_suffix(side: int) -> String:
	match side:
		0:
			return "l"
		1:
			return "r"
		_:
			return ""


## Concept ids that must be present for a usable humanoid retarget.
static func required_concepts() -> PackedStringArray:
	return PackedStringArray([
		"hips",
		"spine.01",
		"upper_leg.l",
		"upper_leg.r",
		"lower_leg.l",
		"lower_leg.r",
		"foot.l",
		"foot.r",
		"upper_arm.l",
		"upper_arm.r",
		"lower_arm.l",
		"lower_arm.r",
		"hand.l",
		"hand.r",
		"head",
	])
