extends GdUnitTestSuite

# A translated template is formatted with GDScript's %, which fills placeholders by position. A translation that
# drops one, adds one or reorders them makes the format call fail at runtime, but only in that language.

const TABLE_PATH: String = "res://locale/zh_CN.csv"
const PLACEHOLDER_PATTERN: String = "%[-+0]*\\d*(?:\\.\\d+)?[sdfxc]"


func _placeholders(text: String, placeholder: RegEx) -> Array[String]:
	var found: Array[String] = []
	# Lower-cased: the table's uppercase rows have keys reading %D for values reading %d.
	for match_result: RegExMatch in placeholder.search_all(text.to_lower().replace("%%", "")):
		found.append(match_result.get_string())
	return found


func test_every_translation_keeps_its_placeholders_in_order() -> void:
	var placeholder: RegEx = RegEx.create_from_string(PLACEHOLDER_PATTERN)
	var table: FileAccess = FileAccess.open(TABLE_PATH, FileAccess.READ)
	assert_object(table).is_not_null()
	table.get_csv_line()  # the header
	var broken: Array[String] = []
	while not table.eof_reached():
		var row: PackedStringArray = table.get_csv_line()
		if row.size() < 2:
			continue
		if _placeholders(row[0], placeholder) != _placeholders(row[1], placeholder):
			broken.append(row[0])
	assert_array(broken).is_empty()
