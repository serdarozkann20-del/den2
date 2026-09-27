@tool
## Headless batch entry point: no dock, no EditorInterface, so it also runs in CI.
##
##   godot --headless --path <project> --import
##   godot --headless --path <project> --script addons/rigbridge/cli/rb_headless.gd -- \\
##        --target res://characters/player.glb \\
##        --anims  res://mixamo/animations \\
##        --out    res://animations \\
##        --lib    Mixamo \\
##        --mode   rewrite \\
##        --attach res://scenes/player.tscn::Player/AnimationPlayer
##
## `--target`/`--anims` accept a file or a folder (folder = every supported file in
## it). Exit code: 0 = ok, 1 = errors in the report, 2 = bad usage.
##
## Mode B (`--mode rewrite`, the default) needs no import options at all, so it is the
## safe choice for CI. `--mode import` (or `both`) writes per-node `retarget/*` keys
## into each `.import` file; add `--import` to trigger the reimport in the same run.
extends SceneTree

const RBPipeline := preload("../core/rb_pipeline.gd")
const RBPreset := preload("../core/rb_preset.gd")
const RBTests := preload("../tests/rb_tests.gd")

const KNOWN_FLAGS := [
	"target", "anims", "out", "lib", "mode", "skeleton", "root_motion",
	"attach", "loop", "individual", "clean", "dry", "selftest", "verbose",
	"no-presets", "import-as-library", "legacy", "keep-rest", "no-verify", "keep-positions",
	"retarget-method", "unmapped-bones", "import",
]


func _initialize() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	if bool(args.get("selftest", false)):
		var lines := RBTests.run_all(true)
		var fails := 0
		for l in lines:
			if String(l).begins_with("FAIL"):
				fails += 1
		quit(1 if fails > 0 else 0)
		return
	var pipeline := RBPipeline.new()
	pipeline.logged.connect(func(level: String, msg: String) -> void:
		print("[%s] %s" % [level, msg])
	)
	pipeline.progress.connect(func(stage: String, step: int, total: int, msg: String) -> void:
		if bool(args.get("verbose", false)):
			print("%s %d/%d %s" % [stage, step, total, msg])
	)
	var opts := _build_opts(args)
	if opts.is_empty():
		print("usage: --target <model> --anims <file|folder> [--out res://animations] [--lib Mixamo]")
		print("       [--mode both|import|rewrite] [--root_motion keep|in_place|flatten_y]")
		print("       [--loop] [--individual] [--clean] [--no-presets] [--legacy] [--verbose] [--selftest]")
		print("       [--retarget-method none|overwrite_axis|modifier] [--unmapped-bones none|remove|separate_library]")
		print("       [--import-as-library] [--import (also reimport)] [--keep-positions] [--no-verify] [--dry]")
		quit(2)
		return
	var report := pipeline.run(opts)
	print(RBPipeline.format_report(report))
	# import mode changes .import files, so a reimport must still happen.
	var touched := PackedStringArray()
	for f in report.get("files", []):
		if (f as Dictionary).has("import_mode"):
			touched.append(String((f as Dictionary)["file"]))
	if not touched.is_empty():
		print("\nRetarget settings were written. Refresh caches with:")
		print("  godot --headless --path <project> --import")
	print("\nwrote: " + String((report.get("library", {}) as Dictionary).get("path", "(no .tres saved)")))
	var bad: PackedStringArray = report.get("errors", PackedStringArray())
	quit(1 if not bad.is_empty() else 0)


func _parse(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var seen := {}
	var i := 0
	while i < argv.size():
		var a := String(argv[i])
		if a == "--selftest" or a == "--loop" or a == "--individual" or a == "--clean" \
				or a == "--no-presets" or a == "--verbose" or a == "--dry" or a == "--keep-rest" \
				or a == "--no-verify" or a == "--keep-positions" or a == "--import" \
				or a == "--import-as-library" or a == "--legacy":
			out[a.trim_prefix("--").replace("-", "_")] = true
			i += 1
			continue
		if a.begins_with("--"):
			var key := a.trim_prefix("--")
			key = key.replace("-", "_")
			if i + 1 < argv.size() and not String(argv[i + 1]).begins_with("--"):
				out[key] = String(argv[i + 1])
				i += 2
				continue
			out[key] = true
			i += 1
			continue
		i += 1
	for k in out.keys():
		seen[String(k)] = true
	for k in KNOWN_FLAGS:
		seen.erase(String(k).replace("-", "_"))
	for k in seen.keys():
		print("warning: ignoring unknown flag --" + String(k))
	return out


func _files_from(value: String) -> PackedStringArray:
	if value.is_empty():
		return PackedStringArray()
	if not value.ends_with("/") and DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(value)):
		return RBPreset.collect_files(value, true)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(value)):
		return RBPreset.collect_files(value, true)
	return PackedStringArray([value])


func _build_opts(args: Dictionary) -> Dictionary:
	var target := String(args.get("target", ""))
	var anims := _files_from(String(args.get("anims", "")))
	if target.is_empty() and anims.is_empty():
		return {}
	var extras := PackedStringArray(["unimportant_positions", "unmapped_bones"])
	if bool(args.get("legacy", false)):
		extras.append("fix_silhouette")
	if bool(args.get("keep_rest", false)) and not extras.has("keep_rest_leftovers"):
		extras.append("keep_rest_leftovers")
	return {
		"mode": String(args.get("mode", "rewrite")),
		"target_model": target,
		"anim_files": anims,
		"out_dir": String(args.get("out", "res://animations")),
		"library_name": String(args.get("lib", "Mixamo")),
		"skeleton_name": String(args.get("skeleton", "GeneralSkeleton")),
		"root_motion": String(args.get("root_motion", "keep")),
		"loop": bool(args.get("loop", false)),
		"loop_detect": true,
		"clean_names": bool(args.get("clean", true)),
		"save_individual": bool(args.get("individual", false)),
		"save_library": true,
		"use_presets": not bool(args.get("no_presets", false)),
		"save_presets": not bool(args.get("no_presets", false)),
		"attach": false,
		"do_reimport": bool(args.get("import", false)),
		"configure_target": not bool(args.get("dry", false)),
		"as_animation_library": bool(args.get("import_as_library", false)),
		"retarget_method": String(args.get("retarget_method", "overwrite_axis")),
		"unmapped_bones_mode": String(args.get("unmapped_bones", "remove")),
		"remove_unimportant_positions": not bool(args.get("keep_positions", false)),
		"verify_keys": not bool(args.get("no_verify", false)),
		"extras": extras,
	}
