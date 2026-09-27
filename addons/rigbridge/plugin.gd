@tool
## RigBridge - multi-source humanoid retarget + Mixamo bone/animation repair.
extends EditorPlugin

const DOCK_NAME := "RigBridge"
const MENU_SHOW := "RigBridge: show panel"
const MENU_TEST := "RigBridge: run self-test"

var _dock: RBDock = null


func _enter_tree() -> void:
	_dock = RBDock.new()
	_dock.name = "RigBridgeDock"
	_dock.editor = get_editor_interface()
	add_control_to_bottom_panel(_dock, DOCK_NAME)
	add_tool_menu_item(MENU_SHOW, _show_dock)
	add_tool_menu_item(MENU_TEST, _run_tests)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_SHOW)
	remove_tool_menu_item(MENU_TEST)
	if _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null


func _show_dock() -> void:
	if _dock != null:
		make_bottom_panel_item_visible(_dock)


func _run_tests() -> void:
	var lines := RBTests.run_all(true)
	print("RigBridge self-test:")
	for l in lines:
		print("  " + String(l))
	var failed := false
	for l in lines:
		if String(l).begins_with("FAIL"):
			failed = true
	if failed:
		push_warning("RigBridge: self-test reported failures (see Output panel)")
	else:
		print("RigBridge: all checks passed")
