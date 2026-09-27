@tool
## Optional convenience entry point: preload this once and reach every module.
##
##     const RB := preload("res://addons/rigbridge/rigbridge.gd")
##     var rep := RB.RBPipeline.new().run({...})
##
## The plugin itself never uses this file - each module preloads the ones it needs
## with relative paths, so the whole folder can live anywhere in the project and no
## global class names are registered (no collisions with your own code, no reliance
## on the editor's global class cache).
extends RefCounted

const RBName := preload("core/rb_name.gd")
const RBConcepts := preload("core/rb_concepts.gd")
const RBBones := preload("core/rb_bones.gd")
const RBRig := preload("core/rb_rig.gd")
const RBMatcher := preload("core/rb_matcher.gd")
const RBBoneMapBuilder := preload("core/rb_bonemap.gd")
const RBAnim := preload("core/rb_anim.gd")
const RBImport := preload("core/rb_import.gd")
const RBPreset := preload("core/rb_preset.gd")
const RBLibrary := preload("core/rb_library.gd")
const RBPipeline := preload("core/rb_pipeline.gd")
const RBTests := preload("tests/rb_tests.gd")
const RBDock := preload("ui/rb_dock.gd")
const RBHeadless := preload("cli/rb_headless.gd")
