extends SceneTree


# Headless probe: verify the generated zh_CN Translation loads, registers, and
# lookups work via TranslationServer — plain keys, multi-line key, placeholder
# order, uppercase button variants, scene keys.
func _init() -> void:
	var tr: Translation = load("res://locale/zh_CN.zh_CN.translation")
	print("PROBE translation load: ", "OK" if tr != null else "FAIL")
	if tr == null:
		quit(1)
		return
	TranslationServer.add_translation(tr)
	TranslationServer.set_locale("zh_CN")
	print(
		"PROBE locale=",
		TranslationServer.get_locale(),
		" registered=",
		TranslationServer.get_translations().size()
	)
	var probes := [
		"START",
		"Resume",
		"by ",
		"%d PTS",
		"Easy",
		"Fervor",
		"The Final Inch",
		"Auto (System)",
		"Straight",
		"> START",
		"STROKE",
		"NAME IT",
	]
	for p: String in probes:
		var t: String = TranslationServer.translate(p)
		print(
			"PROBE ",
			JSON.stringify(p),
			" => ",
			JSON.stringify(t),
			" ",
			"OK" if t != p else "(miss)"
		)
	var multi := 'You have a saved run for "%s". Starting a new run will permanently delete that save.\n\nUse the Resume button instead to continue where you left off.'
	var mt: String = TranslationServer.translate(multi)
	print("PROBE multiline: ", "OK" if mt != multi else "(miss)", " head=", mt.substr(0, 20))
	quit()
