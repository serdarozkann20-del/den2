@tool
## Pure string utilities for bone / animation names. Deliberately free of any
## editor or scene APIs so the matching logic stays unit-testable in isolation.
class_name RBName
extends RefCounted

## Leading groups that carry rig identity but no anatomical meaning.
## Only stripped when followed by a separator, so a real bone called `Root` is safe.
const NOISE_PREFIXES: PackedStringArray = [
	"mixamorig",
	"mixamo",
	"bip001",
	"bip01",
	"bip",
	"armature",
	"sk_",
	"bp_",
	"rig",
]

## Trailing tokens that carry no anatomical meaning.
const NOISE_SUFFIXES: PackedStringArray = [
	"001",
	"match",
	"bone",
	"joint",
	"ctrl",
	"control",
	"def",
	"geo",
	"jnt",
	"grp",
	"group",
	"orient",
	"null",
]

const SEPARATORS: PackedStringArray = ["-", ".", " ", ":"]

const NUMBER_WORDS: Dictionary = {
	"one": 1,
	"two": 2,
	"three": 3,
	"four": 4,
	"five": 5,
	"six": 6,
	"first": 1,
	"second": 2,
	"third": 3,
	"fourth": 4,
	"fifth": 5,
	"sixth": 6,
}


## Lowercase, unify separators to `_`, drop punctuation and index counters.
static func normalize(raw: String) -> String:
	var s := raw.strip_edges().to_lower()
	for sep in SEPARATORS:
		s = s.replace(sep, "_")
	s = s.replace("__", "_")
	var out := ""
	for c in s:
		var code := c.unicode_at(0)
		var is_lower: bool = code >= 97 and code <= 122
		var is_digit: bool = code >= 48 and code <= 57
		if is_lower or is_digit or c == "_":
			out += c
	while out.contains("__"):
		out = out.replace("__", "_")
	return out.trim_left("_").trim_right("_")


static func tokens(raw: String) -> PackedStringArray:
	var s := normalize(split_camel(raw))
	if s.is_empty():
		return PackedStringArray()
	return PackedStringArray(s.split("_", false))


## `LeftUpperArm` -> `Left_Upper_Arm`, `Thumb1` -> `Thumb_1`, so token based rules
## see through camelCase and digit suffixes.
static func split_camel(raw: String) -> String:
	var out := ""
	for i in range(raw.length()):
		var c := raw[i]
		var code := c.unicode_at(0)
		var is_upper: bool = code >= 65 and code <= 90
		var is_digit: bool = code >= 48 and code <= 57
		if out.length() > 0 and not out.ends_with("_"):
			var prev := out[out.length() - 1]
			var pc := prev.unicode_at(0)
			var prev_upper: bool = pc >= 65 and pc <= 90
			var prev_lower: bool = pc >= 97 and pc <= 122
			var prev_digit: bool = pc >= 48 and pc <= 57
			if is_upper and (prev_lower or prev_digit):
				out += "_"
			elif is_digit and (prev_lower or prev_upper):
				out += "_"
			elif is_upper and not prev_upper and not prev_digit:
				out += "_"
		out += c
	return out


## Removes leading rig prefixes such as `mixamorig:` or `Bip001_`.
static func strip_prefixes(raw: String) -> String:
	var s := raw.strip_edges()
	var guard := 0
	while guard < 8:
		guard += 1
		var changed := false
		var low := s.to_lower()
		for p in NOISE_PREFIXES:
			var pl := String(p).to_lower()
			if not low.begins_with(pl):
				continue
			var cut := pl.length()
			if cut >= s.length():
				continue
			var nxt := s[cut]
			var glued: bool = pl == "mixamorig" or pl == "mixamo" or pl == "bip001" or pl == "bip01"
			if nxt == ":" or nxt == "_" or nxt == "-" or nxt == "." or nxt == " ":
				s = s.substr(cut + 1)
				changed = true
			elif glued:
				s = s.substr(cut)
				changed = true
			if changed:
				break
		if not changed:
			break
	return s


static func strip_noise(raw: String) -> String:
	var s := strip_prefixes(raw)
	var guard := 0
	while guard < 6:
		guard += 1
		var toks := tokens(s)
		if toks.size() <= 1:
			break
		var last := String(toks[toks.size() - 1])
		if last in NOISE_SUFFIXES:
			toks.remove_at(toks.size() - 1)
			s = "_".join(toks)
		else:
			break
	return s


## -1 unknown, 0 left, 1 right.
static func side_of(raw: String) -> int:
	var toks := tokens(raw)
	if toks.is_empty():
		return -1
	for t in toks:
		if t == "left" or t == "lf" or t == "lt":
			return 0
		if t == "right" or t == "rf" or t == "rt":
			return 1
	var first := String(toks[0])
	var last := String(toks[toks.size() - 1])
	if first == "l" or last == "l":
		return 0
	if first == "r" or last == "r":
		return 1
	var low := raw.to_lower()
	if low.ends_with(".l") or low.ends_with("_l") or low.ends_with("-l"):
		return 0
	if low.ends_with(".r") or low.ends_with("_r") or low.ends_with("-r"):
		return 1
	return -1


## First integer-looking token (1..99), or 0.
static func ordinal_of(raw: String) -> int:
	for t in tokens(raw):
		if t.is_valid_int():
			return int(t)
		if NUMBER_WORDS.has(t):
			return int(NUMBER_WORDS[t])
	return 0


static func levenshtein(a: String, b: String) -> int:
	if a == b:
		return 0
	if a.is_empty():
		return b.length()
	if b.is_empty():
		return a.length()
	var prev := PackedInt32Array()
	var cur := PackedInt32Array()
	prev.resize(b.length() + 1)
	cur.resize(b.length() + 1)
	for j in range(b.length() + 1):
		prev[j] = j
	for i in range(1, a.length() + 1):
		cur[0] = i
		var ac := a[i - 1]
		for j in range(1, b.length() + 1):
			var cost := 0 if ac == b[j - 1] else 1
			cur[j] = mini(mini(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
		for j in range(b.length() + 1):
			prev[j] = cur[j]
	return prev[b.length()]


## 0.0 .. 1.0 normalized similarity.
static func similarity(a: String, b: String) -> float:
	var na := normalize(a)
	var nb := normalize(b)
	if na.is_empty() or nb.is_empty():
		return 0.0
	if na == nb:
		return 1.0
	var d := levenshtein(na, nb)
	var m := float(maxi(na.length(), nb.length()))
	if m <= 0.0:
		return 0.0
	return clampf(1.0 - (d / m), 0.0, 1.0)


## Jaccard-ish overlap of token sets; tolerant to token order.
static func token_overlap(a: String, b: String) -> float:
	var ta := tokens(a)
	var tb := tokens(b)
	if ta.is_empty() or tb.is_empty():
		return 0.0
	var hit := 0
	for t in ta:
		if t in tb:
			hit += 1
	return float(hit) / float(maxi(ta.size(), tb.size()))


## `Idle (1)`, `standing_idle--loop`, `Mixamo.com - Idle_0` -> `idle`.
static func clean_anim_name(raw: String) -> String:
	var s := raw.strip_edges()
	# Drop trailing "(2)" take counters.
	while s.ends_with(")"):
		var op := s.rfind("(")
		if op < 0:
			break
		var inner := s.substr(op + 1, s.length() - op - 2)
		if not inner.is_valid_int():
			break
		s = s.substr(0, op)
	# Drop trailing `_1`, `-01`, `.02` counters.
	var i := s.length() - 1
	while i >= 0 and s[i].is_valid_int():
		i -= 1
	if i < s.length() - 1 and i >= 0:
		var sepc := s[i]
		if sepc == "_" or sepc == "-" or sepc == "." or sepc == " ":
			s = s.substr(0, i)
	for sep in SEPARATORS:
		s = s.replace(sep, "_")
	s = s.replace("+", "_")
	var toks := PackedStringArray()
	for t in s.to_lower().split("_", false):
		if String(t) == "loop" or String(t) == "looping":
			continue
		if t == "mixamo" or t == "com" or t == "take" or t == "001":
			continue
		if not String(t).is_empty():
			toks.append(t)
	return "_".join(toks)


static func has_loop_hint(raw: String) -> bool:
	var low := raw.to_lower()
	if low.ends_with("-loop") or low.ends_with("_loop") or low.ends_with(".loop"):
		return true
	if low.ends_with("-loop0") or low.ends_with("_loop0"):
		return true
	return low.contains("loop")
