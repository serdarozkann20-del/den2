@tool
## Scores and greedily assigns source bones to target (profile) bones.
##
## Uniqueness is enforced in both directions: one source bone can serve one profile
## bone, and vice versa, so a bad `foot`/`toes` guess can never silently steal two
## bones. Ties are broken by name similarity and hierarchy depth agreement.
extends RefCounted

const RBBones := preload("./rb_bones.gd")
const RBConcepts := preload("./rb_concepts.gd")
const RBName := preload("./rb_name.gd")
const RBRig := preload("./rb_rig.gd")
const DEFAULTS := {
	"threshold": 0.56,
	"w_concept": 0.62,
	"w_depth": 0.16,
	"w_name": 0.14,
	"w_parent": 0.08,
	"min_name_sim": 0.78,
}


static func _w(opts: Dictionary) -> Dictionary:
	var out := {}
	for k in DEFAULTS.keys():
		out[k] = opts.get(k, DEFAULTS[k])
	return out


## Score a single candidate pair. Returns `{score: float, reasons: PackedStringArray}`.
static func score_pair(source: Dictionary, si: int, target: Dictionary, ti: int, opts: Dictionary = {}, partner: Dictionary = {}) -> Dictionary:
	var w := _w(opts)
	var s_concept := String(source["concepts"][si])
	var t_concept := String(target["concepts"][ti])
	var reasons := PackedStringArray()
	var reject := false

	if s_concept.is_empty() or t_concept.is_empty():
		reject = true

	var s_side := RBBones.side_of_concept(s_concept)
	var t_side := RBBones.side_of_concept(t_concept)
	if s_side >= 0 and t_side >= 0 and s_side != t_side:
		# Left/right confusion is the worst possible mistake: kill the pair.
		return {"score": 0.0, "reasons": PackedStringArray(["side mismatch"])}

	var concept_score := 0.0
	if not reject and s_concept == t_concept:
		concept_score = 1.0
		reasons.append("concept " + s_concept)
	elif not reject:
		var sf := RBBones.family_of(s_concept)
		var tf := RBBones.family_of(t_concept)
		if sf != tf or sf == "":
			reject = true
		else:
			# Same family and side, different rank: chain near miss.
			concept_score = 0.55
			reasons.append("family " + sf)

	var name_sim := RBName.similarity(
		RBName.normalize(RBName.strip_prefixes(String(source["names"][si]))),
		RBName.normalize(RBName.strip_prefixes(String(target["names"][ti])))
	)
	# Chain alignment (spine / neck / fingers) outranks naming: a rig with extra
	# vertebrae or twist bones still lands on the right bones.
	var aligned: bool = partner.has(si) and int(partner[si]) == ti
	if aligned and reject:
		reject = false
		concept_score = 0.92
		reasons.append("chain position")
	elif aligned and concept_score < 1.0:
		concept_score = maxf(concept_score, 0.92)
		reasons.append("chain position")
	if reject:
		# Without concepts the only evidence is the name, and it has to be strong.
		if name_sim < float(w["min_name_sim"]):
			return {"score": 0.0, "reasons": PackedStringArray(["unresolved"])}
		reasons.append("name only")
		var depth_sim_n := _depth_sim(source, si, target, ti)
		return {"score": 0.5 + 0.4 * name_sim + 0.1 * depth_sim_n, "reasons": reasons}

	var depth_sim := _depth_sim(source, si, target, ti)
	var parent_sim := _parent_sim(source, si, target, ti)
	var score: float = (
		float(w["w_concept"]) * concept_score
		+ float(w["w_depth"]) * depth_sim
		+ float(w["w_name"]) * name_sim
		+ float(w["w_parent"]) * parent_sim
	)
	if concept_score >= 1.0:
		score = clampf(score + 0.06, 0.0, 1.0)
	if depth_sim > 0.99:
		reasons.append("depth")
	if parent_sim > 0.99:
		reasons.append("parent")
	if name_sim > 0.9:
		reasons.append("name")
	return {"score": clampf(score, 0.0, 1.0), "reasons": reasons}


static func _depth_sim(source: Dictionary, si: int, target: Dictionary, ti: int) -> float:
	var sd: int = int(source["depths"][si])
	var td: int = int(target["depths"][ti])
	if sd < 0 or td < 0:
		return 0.5
	var diff := absi(sd - td)
	return clampf(1.0 - float(diff) / 6.0, 0.0, 1.0)


static func _parent_sim(source: Dictionary, si: int, target: Dictionary, ti: int) -> float:
	var sp := String(source["parents"][si])
	var tp := String(target["parents"][ti])
	if sp.is_empty() or tp.is_empty():
		return 0.5
	var sc := String(source["concepts"][_index_of(source["names"], sp)])
	var tc := String(target["concepts"][_index_of(target["names"], tp)])
	if sc.is_empty() or tc.is_empty():
		return 0.4
	if sc == tc:
		return 1.0
	if RBBones.family_of(sc) == RBBones.family_of(tc) and RBBones.family_of(sc) != "":
		return 0.7
	return 0.0


static func _index_of(names: PackedStringArray, needle: String) -> int:
	for i in range(names.size()):
		if String(names[i]) == needle:
			return i
	return 0


## Full assignment. Returns:
## {
##   mapping:    {profile_bone: source_bone}   # exactly what BoneMap stores
##   scores:     {profile_bone: float}
##   reasons:    {profile_bone: PackedStringArray}
##   ambiguous:  [{target, chosen, runner_up, delta}]
##   missing:    [profile_bone]                # unresolved
##   required_missing: [profile_bone]          # unresolved *and* required
##   unused:     [source_bone]                 # source bones nobody claimed
##   matched:    int
##   quality:    "good" | "fair" | "poor"
##   avg_score:  float
## }
static func match_rigs(source: Dictionary, target: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var w := _w(opts)
	var src: Dictionary = source.duplicate()
	var tgt: Dictionary = target.duplicate()
	var partner := align_chains(src, tgt)
	var pairs: Array = []
	for ti in range((tgt["names"] as PackedStringArray).size()):
		for si in range((src["names"] as PackedStringArray).size()):
			var r := score_pair(src, si, tgt, ti, w, partner)
			var sc: float = float(r["score"])
			if sc < float(w["threshold"]):
				continue
			pairs.append({"ti": ti, "si": si, "score": sc, "reasons": r["reasons"]})
	pairs.sort_custom(_by_score_desc)

	var used_target := {}
	var used_source := {}
	var mapping := {}
	var scores := {}
	var reasons := {}
	var runner_up := {}
	for p in pairs:
		var ti := int(p["ti"])
		var si := int(p["si"])
		var tname := String(tgt["names"][ti])
		var sname := String(src["names"][si])
		if used_target.has(ti):
			if not runner_up.has(ti):
				runner_up[ti] = {"source": sname, "score": float(p["score"])}
			continue
		if used_source.has(si):
			continue
		used_target[ti] = true
		used_source[si] = true
		mapping[tname] = sname
		scores[tname] = float(p["score"])
		reasons[tname] = p["reasons"]

	var ambiguous: Array = []
	# NOTE: `tname` is already declared above in this function - GDScript rejects a second
	# declaration in the same scope, so the runner-up loop uses its own name.
	for ti in runner_up.keys():
		var contested := String(tgt["names"][int(ti)])
		if not mapping.has(contested):
			continue
		var top := float(scores[contested])
		var alt := runner_up[int(ti)]
		var delta: float = top - float(alt["score"])
		if delta < 0.1:
			ambiguous.append({
				"target": contested,
				"chosen": String(mapping[tname]),
				"runner_up": String(alt["source"]),
				"delta": delta,
			})

	var missing: Array = []
	var required_missing: Array = []
	for ti in range((tgt["names"] as PackedStringArray).size()):
		var tname2 := String(tgt["names"][ti])
		if mapping.has(tname2):
			continue
		missing.append(tname2)
		if int(tgt["required"][ti]) == 1:
			required_missing.append(tname2)

	var unused: Array = []
	for si in range((src["names"] as PackedStringArray).size()):
		if used_source.has(si):
			continue
		var cname := String(src["concepts"][si])
		if cname.is_empty():
			continue
		unused.append(String(source["names"][si]))

	var total := 0
	for ti in range((tgt["names"] as PackedStringArray).size()):
		if int(tgt["required"][ti]) == 1:
			total += 1
	var req_ok := 0
	for tname3 in mapping.keys():
		var c := String(tgt["concepts"][_index_of(tgt["names"], String(tname3))])
		if c in RBConcepts.required_concepts():
			req_ok += 1
	var ratio := 1.0
	if total > 0:
		ratio = float(req_ok) / float(total)
	var quality := "poor"
	if ratio >= 0.98 and required_missing.is_empty():
		quality = "good"
	elif ratio >= 0.8:
		quality = "fair"

	var sum := 0.0
	for v in scores.values():
		sum += float(v)
	var avg := 0.0
	if not scores.is_empty():
		avg = sum / float(scores.size())

	return {
		"mapping": mapping,
		"scores": scores,
		"reasons": reasons,
		"ambiguous": ambiguous,
		"missing": missing,
		"required_missing": required_missing,
		"unused": unused,
		"matched": mapping.size(),
		"quality": quality,
		"avg_score": avg,
		"required_ratio": ratio,
	}


static func _by_score_desc(a, b) -> bool:
	return float(a["score"]) > float(b["score"])


## Top candidates for one target bone, for the UI override menu.
static func suggest(source: Dictionary, target: Dictionary, target_bone: String, limit: int = 8, opts: Dictionary = {}) -> Array:
	var src: Dictionary = source.duplicate()
	var tgt: Dictionary = target.duplicate()
	var partner := align_chains(src, tgt)
	var ti := _index_of(tgt["names"], target_bone)
	var out: Array = []
	for si in range((src["names"] as PackedStringArray).size()):
		var r := score_pair(src, si, tgt, ti, opts, partner)
		var sc: float = float(r["score"])
		if sc <= 0.05:
			continue
		out.append({"source": String(src["names"][si]), "score": sc, "reasons": r["reasons"]})
	out.sort_custom(_by_score_desc)
	if out.size() > limit:
		out.resize(limit)
	return out


## Invert `{profile: source}` into `{source: profile}` (used for track rewrites).
static func invert(mapping: Dictionary) -> Dictionary:
	var out := {}
	for k in mapping.keys():
		out[String(mapping[k])] = String(k)
	return out


# --------------------------------------------------------- chain alignment
static func _is_axial(concept: String) -> bool:
	var fam := RBBones.family_of(concept)
	return fam == "spine" or fam == "neck" or concept == "head"


static func _rig_keys(rig: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var concepts: PackedStringArray = rig["concepts"]
	for c in concepts:
		var cs := String(c)
		if cs.is_empty():
			continue
		var key := ""
		if _is_axial(cs):
			key = "axial|-1"
		else:
			var fam := RBBones.family_of(cs)
			if RBBones.CHAIN_FAMILIES.has(fam):
				# Same key spelling as RBRig.renumber_chains().
				key = "%s|%d" % [fam, RBBones.side_of_concept(cs)]
		if not key.is_empty() and out.find(key) < 0:
			out.append(key)
	return out


## The contiguous chain for one `family|side` key, shallowest first. Members that are
## not on the chain (twist bones, side bends) have their concept cleared so they can
## never steal a slot from a real bone.
static func _chain_members(rig: Dictionary, key: String) -> Array:
	var concepts: PackedStringArray = rig["concepts"]
	var names: PackedStringArray = rig["names"]
	var parents: PackedStringArray = rig["parents"]
	var depths: PackedInt32Array = rig["depths"]
	var fam := key.get_slice("|", 0)
	var side := int(key.get_slice("|", 1))
	var members: Array = []
	for i in range(names.size()):
		var c := String(concepts[i])
		if c.is_empty():
			continue
		var ok := false
		if fam == "axial":
			ok = _is_axial(c)
		else:
			ok = RBBones.family_of(c) == fam and RBBones.side_of_concept(c) == side
		if ok:
			members.append(i)
	if members.is_empty():
		return []
	members = _sort_by_depth(members, depths)
	var chain: Array = [members[0]]
	for guard in range(64):
		var cur_name := String(names[int(chain[chain.size() - 1])])
		var nxt := -1
		for i in members:
			if i in chain:
				continue
			if String(parents[int(i)]) == cur_name:
				nxt = int(i)
				break
		if nxt < 0:
			break
		chain.append(nxt)
	for i in members:
		if not (i in chain):
			concepts[int(i)] = ""
	rig["concepts"] = concepts
	return chain


## `{source_index: target_index}` for chain families. A source chain longer than the
## target's is tail-anchored so extra vertebrae / finger bones compress at the base;
## a shorter one is base-anchored for the spine and tail-anchored for fingers.
static func align_chains(source: Dictionary, target: Dictionary) -> Dictionary:
	var partner := {}
	var tkeys := _rig_keys(target)
	var skeys := _rig_keys(source)
	for key in tkeys:
		var k := String(key)
		if skeys.find(k) < 0:
			continue
		var tc := _chain_members(target, k)
		var sc := _chain_members(source, k)
		if tc.is_empty() or sc.is_empty():
			continue
		var n: int = mini(tc.size(), sc.size())
		var fam := k.get_slice("|", 0)
		var tail_anchor: bool = fam != "axial" or sc.size() >= tc.size()
		for kk in range(n):
			var ti: int = int(tc[tc.size() - 1 - kk]) if tail_anchor else int(tc[kk])
			var si: int = int(sc[sc.size() - 1 - kk]) if tail_anchor else int(sc[kk])
			partner[si] = ti
	return partner


## Insertion sort by depth. Deliberately not a lambda: the matcher runs inside static
## functions, and a comparator that needs captured state is easier to read as a loop.
static func _sort_by_depth(idx: Array, depths: PackedInt32Array) -> Array:
	var out := idx.duplicate()
	for i in range(1, out.size()):
		var j := i
		while j > 0 and depths[int(out[j - 1])] > depths[int(out[j])]:
			var tmp = out[j - 1]
			out[j - 1] = out[j]
			out[j] = tmp
			j -= 1
	return out
