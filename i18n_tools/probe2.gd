extends SceneTree
# Headless probe round 2: verify the runtime translation contract end to end —
# plain keys, concat full keys (the only string Godot looks up at display time),
# tr()-wrapped pieces, format templates, and the uppercase-variant path.


func _init() -> void:
	var tr_res: Translation = load("res://locale/zh_CN.zh_CN.translation")
	print("PROBE translation load: ", "OK" if tr_res != null else "FAIL")
	if tr_res == null:
		quit(1)
		return
	TranslationServer.add_translation(tr_res)
	TranslationServer.set_locale("zh_CN")

	var fails := 0
	# lookup: [raw string to look up, expected substring, "" = just needs a hit]
	var checks := [
		["LANGUAGE", "语言"],
		["ROUND", "回合"],
		["by ", "作者："],
		# concat full keys (stored string is the runtime concatenation)
		[
			(
				"Plays under storyboards, shops, checkpoints and forks — anything that is not a round. "
				+ "A setting's music or a storyboard's own overrides it. Several tracks shuffle; it pauses "
				+ "for a round and picks up where it left off."
			),
			"在过场剧情、商店、检查点和分支下播放",
		],
		[
			"This shop draws its stock at random — the spot sits empty on visits where this item isn't drawn.",
			"本商店随机抽取库存",
		],
		# tr()-wrapped pieces the code concatenates at call time
		[
			"Baseline model: completes every round, endures curses, buys only what locked paths ahead require.",
			"基准模型",
		],
		[" Traffic from %d simulated runs.", "模拟流程"],
		[
			"Reusable places: a background and the music that belongs to it, defined once and ",
			"可复用的地点"
		],
		# format templates (lookup the template, not the substituted result)
		["CLIP LIBRARY  (%d)", "片段库"],
		["%dS %dM %dL", "小"],
		# uppercase path (CatalogPicker headings / to_upper before display)
		["MULTI-AXIS", "多轴"],
		["STANCE", "立场"],
		["EASY", "简单"],
		["VERY HARD", "很难"],
	]
	for c: Array in checks:
		var got: String = TranslationServer.translate(c[0])
		var ok: bool = got != c[0] and got.contains(c[1])
		if not ok:
			fails += 1
		print(
			"PROBE ",
			"OK  " if ok else "FAIL",
			" ",
			JSON.stringify(c[0].left(48)),
			" => ",
			JSON.stringify(got.left(48))
		)
	print("PROBE RESULT: ", "ALL PASS" if fails == 0 else "%d FAILURES" % fails)
	quit(1 if fails > 0 else 0)
