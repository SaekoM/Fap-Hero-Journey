extends SceneTree
# Definitive i18n audit: instantiate a real screen, walk every control, and flag
# any displayed string whose runtime lookup misses the translation table.
#
# Usage:
#   Godot --headless --path . --script i18n_tools/audit_runtime.gd -- res://scenes/options/Options.tscn
#
# A control's stored text is what Godot looks up at display time, so
# translate(stored) == stored means the player sees it untranslated. Texts that
# already carry CJK (translated at call time by tr()/wrap_tip) are skipped, as
# are non-display strings.


func _init() -> void:
	_run.call_deferred()


func _cjk(s: String) -> bool:
	for i: int in s.length():
		var c: int = s.unicode_at(i)
		if (
			(c >= 0x4E00 and c <= 0x9FFF)
			or (c >= 0x3000 and c <= 0x303F)
			or (c >= 0xFF00 and c <= 0xFFEF)
		):
			return true
	return false


func _walk(node: Node, misses: Dictionary, prefix: String) -> void:
	if node is Control:
		var ctrl := node as Control
		for prop in ["text", "placeholder_text", "tooltip_text", "window_title"]:
			var v: Variant = ctrl.get(prop)
			if v is String:
				_check(v, "%s/%s.%s" % [prefix, ctrl.get_class(), prop], misses)
		if ctrl is OptionButton:
			var ob := ctrl as OptionButton
			for i: int in ob.item_count:
				_check(ob.get_item_text(i), "%s/OptionButton[%d]" % [prefix, i], misses)
		if ctrl is ItemList:
			var il := ctrl as ItemList
			for i: int in il.item_count:
				_check(il.get_item_text(i), "%s/ItemList[%d]" % [prefix, i], misses)
	for child: Node in node.get_children():
		_walk(child, misses, prefix)


func _check(s: String, where: String, misses: Dictionary) -> void:
	var t := s.strip_edges()
	if t == "" or _cjk(t):
		return
	var letters := false
	for i: int in t.length():
		var c := t.unicode_at(i)
		if (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
			letters = true
			break
	if not letters:
		return
	if TranslationServer.translate(t) != t:
		return
	if not misses.has(t):
		misses[t] = []
	misses[t].append(where)


func _run() -> void:
	await process_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("AUDIT: pass a scene path after --")
		quit(1)
		return
	var tr_res: Translation = load("res://locale/zh_CN.zh_CN.translation")
	TranslationServer.add_translation(tr_res)
	TranslationServer.set_locale("zh_CN")

	var scene_path := args[0]
	var packed: PackedScene = load(scene_path)
	if packed == null:
		printerr("AUDIT: cannot load ", scene_path)
		quit(1)
		return
	var inst := packed.instantiate()
	if inst == null:
		printerr("AUDIT: cannot instantiate ", scene_path)
		quit(1)
		return
	root.add_child(inst)
	await process_frame
	await process_frame

	var misses: Dictionary = {}
	_walk(inst, misses, inst.name)
	print(
		(
			"AUDIT %s: %d distinct untranslated display strings"
			% [scene_path.get_file(), misses.size()]
		)
	)
	var keys := misses.keys()
	keys.sort()
	for k: String in keys:
		print("MISS | %s" % k.replace("\n", " ⏎ "))
	inst.free()
	quit()
