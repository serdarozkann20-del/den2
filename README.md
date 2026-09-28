# RigBridge

Multi-source humanoid **retarget** + bone/animation **name repair** for **Godot 4.7** (editor plugin).

It does three jobs:

1. **Auto-maps bones** from Mixamo *and any other* rig source (Unity/Humanoid, Unreal, VRM, Ready Player Me,
   ActorCore, Rigify, 3ds Max Biped, hand-made rigs) onto `SkeletonProfileHumanoid`, with a scored fuzzy
   fallback, hierarchy/chain validation, a manual override table, and a cached `BoneMap` (`.tres`) per
   source skeleton.
2. **Retargets** animations from those sources onto your own rig — either through Godot's own import-time
   retargeter, or by rewriting the `Animation` track paths directly.
3. **Fixes names** inside Mixamo animations: rewrites track paths, strips `mixamorig:` (or any prefix),
   normalizes clip names, merges several files into one `AnimationLibrary`, sets loop flags, and cleans up
   `Hips`/`Root` motion (in-place / flatten-Y).

Nothing in the plugin renames bones on a `Skeleton3D`. Renaming a bone breaks every `Skin` bind pose and the
`Mesh.skeleton` path, which is unrecoverable from a script; instead RigBridge writes a `BoneMap` (mode A) or
rewrites the animation's track paths (mode B). That is the whole design philosophy: **map, don't rename**.

---

## Install

1. Copy `addons/rigbridge/` into your project — anywhere you like, e.g. `res://addons/rigbridge/`.
2. **Project ▸ Project Settings ▸ Plugins ▸ RigBridge ▸ Enable**.
3. A **RigBridge** bottom panel appears (also reachable from **Project ▸ Tools ▸ RigBridge: show panel**).

The plugin registers **no global class names**: every module reaches its neighbours through
relative `preload()` paths. That means the folder can be moved or renamed, two copies can coexist
without one shadowing the other, and nothing depends on the editor's
`.godot/global_script_class_cache.cfg` being up to date.

To call it from your own script:

```gdscript
const RB := preload("res://addons/rigbridge/rigbridge.gd")   # facade with every module

func _ready() -> void:
	var report: Dictionary = RB.RBPipeline.new().run({
		"target_model": "res://characters/player.glb",
		"anim_files": RB.RBPreset.collect_files("res://mixamo/animations", true),
		"library_name": "Mixamo",
		"attach": false,
	})
	print(RB.RBPipeline.format_report(report))
```

Or preload a single module: `const RBAnim = preload("res://addons/rigbridge/core/rb_anim.gd")`.

Requires Godot **4.7** or newer (the retarget import options this plugin writes were reworked in 4.5; the
option table is read from 4.7's `ResourceImporterScene`). Older 4.x versions will run mode B fine but the
mode-A import options will not be recognised.

## The two modes

| | Mode A — `import` | Mode B — `rewrite` |
|---|---|---|
| What it touches | the `.import` sidecar of each animation file + one reimport | the `Animation` resources themselves |
| Writes | per-node `retarget/*` keys + a `BoneMap` `.tres` | rewritten track paths, saved as `.tres` clips + an `AnimationLibrary` |
| Needs a reimport | yes | **no** |
| Needs the *target* model's BoneMap | yes | yes (only for the name space, not for import) |
| Bone rest / axis mismatch | fixed by `Overwrite Axis`, `fix_silhouette` | **not** fixed — tracks are moved verbatim |
| Extra `.import` churn in the repo | yes | no |
| Good for | production, meshes with skin in different spaces, A-pose rigs | CI, one-off clips, rigs whose import settings you must not touch |

`mode = "both"` (the default) does A and then uses B as the extraction path, which is what the dock's
**Run all** button does. If a Godot build ever stops honouring the injected keys, mode B still produces a
usable library — that is the fallback this design exists for.

```
--mode both      engine retarget + animation surgery fallback
--mode import    only .import retarget settings
--mode rewrite   only Animation resource surgery (zero import-option edits)
```

## Using the dock

1. **Target** — pick the model that carries *your* rig (or an `AnimationPlayer` in the edited scene, to attach
   the result to).
2. **Animation files** — add files or a whole folder (`*.fbx *.glb *.gltf *.dae`).
3. **Analyze mapping** — reads each skeleton from its already-imported scene, resolves every bone name to an
   anatomy *concept*, scores them against the profile and fills the table. Colours: green ≥ 0.85, amber
   ≥ 0.66, red below. **Double-click a row to override it** — a popup lists the best alternative candidates
   with their scores; the override is kept in memory and written into the saved preset.
4. Choose **Retarget method** (`overwrite_axis` is the default and the usual fix for twisted limbs) and
   **Unmapped bones** (`remove`), tick any option under *extras*, then:
   * **Apply import + reimport** — write `BoneMap`s + `.import` keys, reimport, and verify the keys stuck.
   * **Build library** — extract clips, repair names/tracks, save `.tres` + `AnimationLibrary`.
   * **Run all** — both, in the right order.
   * **Calibrate keys…** — see *Calibration* below.
   * **Save preset** — pin the reviewed mapping to the skeleton-shape hash.

Presets live in `res://.rigbridge/presets/<hash>.json` and are keyed by the skeleton's bone-name set, so a
re-analysis of the same model (or any model with the same bone names) reuses your decisions automatically.

## Headless / CI

```bash
# 1. make sure everything is imported at least once
godot --headless --path . --import

# 2. mode B only: no .import changes, writes res://animations/Mixamo.tres
godot --headless --path . --script addons/rigbridge/cli/rb_headless.gd -- \
     --target res://characters/player.glb \
     --anims  res://mixamo/animations \
     --out    res://animations \
     --lib    Mixamo \
     --mode   rewrite \
     --root_motion in_place --loop --clean

# 3. mode A: also write retarget/* into each .import and reimport
godot --headless --path . --script addons/rigbridge/cli/rb_headless.gd -- \
     --target res://characters/player.glb --anims res://mixamo/animations \
     --mode both --import --retarget-method overwrite_axis --unmapped-bones remove

# matcher self-test (no files needed)
godot --headless --path . --script addons/rigbridge/cli/rb_headless.gd -- --selftest
```

Exit codes: `0` ok · `1` the report contains errors · `2` bad usage.

Flags: `--target --anims --out --lib --mode --skeleton --root_motion --loop --individual --clean
--no-presets --import-as-library --import --keep-positions --no-verify --legacy --keep-rest --dry
--retarget-method --unmapped-bones --verbose --selftest`

## `RBPipeline.run(opts)`

```gdscript
# const RBPipeline := preload("res://addons/rigbridge/core/rb_pipeline.gd")
var report := RBPipeline.new().run({
    "mode": "both",
    "target_model": "res://characters/player.glb",
    "anim_files": RBPreset.collect_files("res://mixamo/animations", true),
    "out_dir": "res://animations",
    "library_name": "Mixamo",
    "attach": true, "player": $Player,          # AnimationPlayer node, or null
})
```

| key | default | meaning |
|---|---|---|
| `mode` | `both` | `both` / `import` / `rewrite` |
| `target_model` | `""` | model holding your rig; empty = animations only (mode B) |
| `anim_files` | `[]` | PackedStringArray of animation files |
| `out_dir` | `res://animations` | where `.tres` clips / `BoneMap`s / the library go |
| `library_name` | `Mixamo` | animation-library name |
| `skeleton_name` | `GeneralSkeleton` | the unique skeleton node name; track paths become `@GeneralSkeleton:<ProfileBone>` |
| `profile` | `SkeletonProfileHumanoid` | any `SkeletonProfile` |
| `retarget_method` | `overwrite_axis` | `none` / `overwrite_axis` / `modifier` → `retarget/rest_fixer/retarget_method` |
| `unmapped_bones_mode` | `remove` | `none` / `remove` / `separate_library` → `retarget/remove_tracks/unmapped_bones` |
| `extras` | `["unimportant_positions"]` | list of `RBImport.EXTRA_GROUPS` names (see below) |
| `as_animation_library` | `false` | import animation files with `importer="animation_library"` (opt-in; the pipeline flips the file back to `scene` whenever it has to read a rig) |
| `configure_target` | `true` | also write the BoneMap into the *target* model's `.import` |
| `do_reimport` | `true` | call `EditorFileSystem.reimport_files()` once for all touched files |
| `verify_keys` | `true` | after the reimport, check the keys we wrote are still there |
| `use_presets` / `save_presets` | `true` | read / write `res://.rigbridge/presets/<hash>.json` |
| `overrides_by_rig` | – | `{preset_key: {profile_bone: source_bone}}` manual overrides |
| `clean_names` | `true` | normalise clip names (`idle_01` → `Idle`) |
| `drop_unmapped` | `true` | remove bone tracks with no profile counterpart |
| `remove_unimportant_positions` | mode A only | drop position tracks the engine would strip anyway |
| `strip_names` | mode B only | strip `mixamorig:`-style prefixes from track paths |
| `loop` / `loop_detect` | `false` / `true` | force looping / trust `walk|run|idle`-style name hints |
| `root_motion` | `keep` | `in_place` zeroes `Hips` translation, `flatten_y` keeps stride and removes bob |
| `save_library` / `save_individual` | `true` / `false` | write the library `.tres` / each clip as its own `.tres` |
| `attach` / `player` | `true` / – | merge the library into an `AnimationPlayer` |
| `mark_dirty` / `save_scene` | `true` / `false` | mark the edited scene unsaved / save it |

The returned report carries `mode`, `skeleton_name`, `target`, one entry per `files[]` (matched count,
quality, pose guess, node key, mapping, moved/dropped track counts), `library`, `attach`, `reimported`,
`bone_maps`, `warnings`, `errors`.

### extras (`.import` keys you may ask for)

```
overwrite_axis        retarget/rest_fixer/retarget_method = 1
fix_silhouette        retarget/rest_fixer/fix_silhouette/enable = true, threshold = 15
unimportant_positions retarget/remove_tracks/unimportant_positions = true
unmapped_bones        retarget/remove_tracks/unmapped_bones = 1
keep_rest_leftovers   retarget/rest_fixer/keep_global_rest_on_leftovers = true
modifier_mode         retarget/rest_fixer/retarget_method = 2
skip_unmapped         retarget/remove_tracks/unmapped_bones = 0
except_bone_transform retarget/remove_tracks/except_bone_transform = true
```

`except_bone_transform` is **known to erase bone tracks in Godot 4.7.2** ([#123782](https://github.com/godotengine/godot/issues/123782));
the plugin warns when you enable it and prefers mode B for the same effect. `fix_silhouette` is enabled
automatically when the source rig's rest pose smells like an A-pose.

## Calibration (why the button exists)

The `retarget/*` keys are per-node entries under `[remap] _subresources = { "nodes": { "PATH:Skeleton3D": {…} } }`
and the node key is `"PATH:" + root.get_path_to(skeleton)`. Nothing outside the editor can enumerate the exact
set of keys a given Godot build accepts — a typo is silently ignored, not an error. So:

1. Configure **one** animation file by hand in the Import dock (BoneMap + method + flags), reimport it.
2. Press **Calibrate keys…** in RigBridge and pick that file.
3. The plugin snapshots its `_subresources` node section verbatim, clones it onto every file in your list
   (swapping in each file's own `BoneMap`), and reimports.

That guarantees byte-exact parity with whatever your engine build really expects, on any patch version. The
plugin also merges into the existing `_subresources` instead of replacing it, so unrelated import settings
(meshes, materials, animations) survive.

## How the matcher works

`RBBones.resolve()` maps a bone name to an anatomy **concept** (`hips`, `spine.01`, `upper_arm.l`,
`thumb.02.r`, `toes.l`, …) via token + flattened-name rules and exact per-family tables (mixamo, unreal,
vrm, rpm, rigify, godot_humanoid). Both sides of the comparison — your rig *and* the profile — go through the
same resolver, because profile names are plain anatomy.

Then:

* **Chain families** (`spine`, `neck`, `tail`, `thumb`, `index`, `middle`, `ring`, `little`) are renumbered by
  hierarchy depth, so `Spine`/`Spine1`/`spine_01`/`spine.001` and a 3-bone thumb vs a 4-bone thumb become
  comparable.
* **Cross-rig chain alignment**: the source chain is matched to the target chain position by position. A
  longer source chain (Rigify's 7 vertebrae, extra finger bones) is tail-anchored — the extra bones compress
  at the base, so `Head`/`Neck` stay reachable; a shorter one is base-anchored for the spine and
  tail-anchored for fingers. Off-chain branch members (`spineSideBend`, twist bones) are dropped from the
  chain so they cannot steal a slot.
* **Helper/deformer names** (`twist`, `bend`, `pole`, `target`, `mthd`, …) never resolve to a concept, so a
  twist bone can't outrank the real bone it follows.
* **Scoring**: concept 0.62 · relative depth 0.16 · name similarity 0.14 · parent agreement 0.08, threshold
  0.56, exact-concept bonus, family near-miss 0.55, and a name-only rescue at similarity ≥ 0.78. A
  left/right mismatch is a hard reject — side confusion is the worst possible failure mode.
* **Uniqueness** is greedy and two-way: no source bone is used twice, no profile bone gets two sources.
* `detect_family()` (which rig *type* this looks like) is **informational only**; it never gates correctness.
* Anything unresolvable stays **unmapped** on purpose. `face`, `breast`, `knee`, `eyebrow` deliberately
  resolve to nothing: an unmapped bone is a visible gap you can fix, a wrong bone is a silent deformation bug.

The mapping dictionary is `{profile_bone: source_bone}`, i.e. exactly `BoneMap` key/value semantics; `invert()`
yields the `source → profile` direction used for track rewrites.

## Files written

```
res://.rigbridge/presets/<skeleton-hash>.json    reviewed mappings, keyed by bone-name set
res://animations/<tag>_<hash>_bonemap.tres       BoneMap per source rig
res://animations/clips/<name>.tres               optional per-clip saves
res://animations/<Library>.tres                  the AnimationLibrary
```

`.import` sidecars are edited in place (mode A) — they are generated files, safe to regenerate, but they are
part of your repo, so review the diff.

## Status / verification

* **Engine API**: every method, constant, property and constructor overload the plugin uses was checked
  against Godot 4.7's class reference (810 classes) by `dev/rb_api_audit.py` - the bug class that makes an
  addon undebuggable (one rejected line kills the file, and every caller then reports
  `Nonexistent function ... in base 'GDScript'`). Re-run it after an engine update:
  `python3 dev/rb_api_audit.py --fetch 4.7 --docs /tmp/godot-4.7` downloads the reference for you, or point
  `--docs` at `doc/classes` in a godot checkout.
* **Module wiring**: `dev/rb_preload_audit.py` verifies that each `preload()` const really exposes the members
  its callers use and that no preload path is absolute (the folder stays relocatable, no global class names).
* **Analyzer-shaped mistakes**: `dev/rb_static_checks.py` reports a `var` declared twice in one block, a call
  whose argument count no signature of ours accepts, a typed function with no `return`, and removed engine
  constructor overloads. All 16 files are clean with it.
* **Compile check** (needs a Godot binary - this is the one that finds analyzer errors `gdparse` cannot):
  `./dev/check_scripts.sh`, optionally `GODOT=/path/to/godot ./dev/check_scripts.sh`.
* **Syntax**: all 16 scripts pass `gdparse` (gdtoolkit 4.5).
* **Matching logic**: validated offline against the real 4.7 `SkeletonProfileHumanoid` (56 bones, 17 required)
  with a one-to-one Python port of `RBName`+`RBBones`+`RBRig`+`RBMatcher`. Mixamo, Unreal, VRM, Ready Player
  Me, Rigify, 3ds Max Biped, prefix-less Mixamo and twist-heavy rigs all map with **zero required-bone
  misses**; a quadruped is correctly *refused* and an unnamed rig produces **no** mapping instead of guessing.
  Those same cases run in-engine as `RBTests` (dock button, `Project ▸ Tools ▸ RigBridge: run self-test`, or
  `--selftest`).
* **Import options**: the 18 `retarget/*` keys, their types and enum values come from 4.7's
  `resource_importer_scene.cpp` and the three skeleton `post_import_plugin`s. The `BoneMap` rules (keys must
  be profile bones, `profile` must be assigned first, `Resource("res://...")` is how a `.import` ConfigFile
  references it) come from `scene/resources/bone_map.cpp` + `core/variant/variant_parser.cpp`.
* **Not yet executed against a real Godot editor binary** - the above is static analysis. If a key is
  rejected on your build, use **Calibrate keys…** — that path cannot go stale.

## Troubleshooting

**`Invalid call. Nonexistent function 'x' in base 'GDScript'`**, repeated all over the Output panel and
pointing at the *callers*. The message is misleading: one preloaded module **failed to compile**, so the
`GDScript` object reached through a `preload` const has no methods, and every call site complains about its
own line. Scroll up to the first `SCRIPT ERROR: Parse Error:` line - that names the real file and line; the
`ERROR:` flood below it is fallout. Three mistakes produce this, all rejected while parsing rather than by
`gdparse`: a call that does not exist on a built-in type (`String.trim_left()` is the C# name, GDScript uses
`lstrip()`), a `var` declared twice in the same block (`Identifier 'x' already declared in this scope`), and a
Godot 3 constructor overload that 4.x removed (`NodePath(names, subnames, absolute)`). `dev/rb_static_checks.py`
and `dev/rb_api_audit.py` check for all three offline; `dev/check_scripts.sh` asks the engine itself. The
self-test also refuses to run with a broken module and says which file to look at. Separately: if a stale
duplicate of the folder exists (`addons/rigbridge*`), delete it and remove `res://.godot/` so the editor
rebuilds its caches.

**`Bone name cannot be empty or contain ':' or '/'` + `Index p_bone = N is out of bounds`.** Godot 4.7's
`Skeleton3D.add_bone()` rejects `:` in bone names while `set_bone_name()` allows it, so a test/build helper
that adds `mixamorig:Hips` directly ends up with an *empty* skeleton and every later index fails. RigBridge
now adds the bone with a temporary name and renames it afterwards. The same rule shapes Mode B: a track path is
assembled as a string and any `:` inside a bone name is dropped, because `NodePath(String)` re-splits on `:` and
`AnimationMixer` reads the bone with `path.get_subname(0)` - a path like `@GeneralSkeleton:mixamorig:LeftArm`
would animate a bone named `mixamorig`, i.e. nothing. There is no way to express such a name as a subname in
Godot 4 (the multi-part `NodePath` constructor is gone) and there is no need: `Skeleton3D` cannot hold a bone
with a colon in the first place.

**`Formatting error in string "Bone name cannot be empty or contain ':' or '/'.': not all arguments
converted`.** Upstream: that engine message is passed an argument it has no placeholder for
(`skeleton_3d.cpp`). Harmless, and unrelated to this plugin.

**Retarget keys vanish after reimport.** Your build spells them differently than 4.7 does. Run
**Calibrate keys…** against one hand-configured file — the plugin then clones that file's exact key set.

## Legal / etiquette

Mixamo's licence (Adobe ToS §6.2E) forbids redistributing downloaded animation libraries — this plugin
therefore ships **no** Mixamo content and only ever writes files inside *your* project. Keep it that way when
you publish: commit your own `.glb`/`.fbx` sources or your generated `.tres` clips only if your licence for
the source assets allows it.

MIT for the plugin code (see `LICENSE`).
