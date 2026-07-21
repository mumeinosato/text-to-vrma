extends Control

## text-to-vrma: VRM読み込み (addon経由でGodot Humanoidに変換) + LLM連携によるモーション生成。

const DEFAULT_MODEL_PATHS := [
	"res://models/AvatarSample_VRM1.0.vrm",
	"res://models/AvatarSample_VRM0.0.vrm",
]

const SETTINGS_PATH := "user://settings.cfg"

# LoopOption の項目インデックス (main.tscn の LoopOption に対応)
const LOOP_AUTO := 0
const LOOP_ON := 1
const LOOP_OFF := 2

@onready var _vrm_root: Node3D = $HSplit/ViewportContainer/SubViewport/World/VrmRoot
@onready var _status_label: Label = $HSplit/SidePanel/Content/StatusLabel
@onready var _vrm_button: Button = $HSplit/SidePanel/Content/VrmButton
@onready var _vrm_file_dialog: FileDialog = $VrmFileDialog

@onready var _base_url_input: LineEdit = $HSplit/SidePanel/Content/Settings/BaseUrlInput
@onready var _api_key_input: LineEdit = $HSplit/SidePanel/Content/Settings/ApiKeyInput
@onready var _model_input: LineEdit = $HSplit/SidePanel/Content/Settings/ModelInput
@onready var _text_input: TextEdit = $HSplit/SidePanel/Content/TextInput
@onready var _refine_check: CheckBox = $HSplit/SidePanel/Content/OptionsRow/RefineCheck
@onready var _loop_option: OptionButton = $HSplit/SidePanel/Content/LoopOption
@onready var _generate_btn: Button = $HSplit/SidePanel/Content/GenerateBtn

var _vrm_loader := VrmLoader.new()
var _llm_client: LlmClient
var _skeleton: Skeleton3D
var _anim_player: AnimationPlayer
var _expression_map: Dictionary = {}


func _ready() -> void:
	_vrm_button.pressed.connect(func(): _vrm_file_dialog.popup_centered_ratio())
	_vrm_file_dialog.file_selected.connect(_on_vrm_file_selected)

	_llm_client = LlmClient.new()
	add_child(_llm_client)
	_llm_client.generation_progress.connect(_on_llm_progress)
	_llm_client.generation_succeeded.connect(_on_llm_succeeded)
	_llm_client.generation_failed.connect(_on_llm_failed)
	_generate_btn.pressed.connect(_on_generate_pressed)

	_setup_loop_option()
	_load_settings()
	_load_default_vrm()


func _load_default_vrm() -> void:
	for path in DEFAULT_MODEL_PATHS:
		if _load_vrm(path):
			_set_status("準備完了", Color.WHITE)
			return
	_set_status("VRMモデルが見つかりません。「VRMを変更」から読み込んでください。", Color.ORANGE)


func _load_vrm(path: String) -> bool:
	var result := _vrm_loader.load_into(_vrm_root, path)
	if result.is_empty():
		return false
	_skeleton = result.get("skeleton")
	_anim_player = result.get("anim_player")
	_expression_map = result.get("expression_map", {})
	return _skeleton != null and _anim_player != null


func _on_vrm_file_selected(path: String) -> void:
	_set_status("VRM読み込み中...", Color.WHITE)
	if _load_vrm(path):
		_set_status("VRMを読み込みました: %s" % path.get_file(), Color.GREEN)
	else:
		_set_status("VRMの読み込みに失敗しました: %s" % path.get_file(), Color.RED)


func _set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)


func _setup_loop_option() -> void:
	_loop_option.clear()
	_loop_option.add_item("ループ再生: 自動", LOOP_AUTO)
	_loop_option.add_item("ループ再生: 常にループ", LOOP_ON)
	_loop_option.add_item("ループ再生: 1回だけ再生", LOOP_OFF)
	_loop_option.select(LOOP_AUTO)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_base_url_input.text = cfg.get_value("api", "base_url", "")
	_api_key_input.text = cfg.get_value("api", "api_key", "")
	_model_input.text = cfg.get_value("api", "model", "")
	_refine_check.button_pressed = cfg.get_value("api", "refine", true)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("api", "base_url", _base_url_input.text)
	cfg.set_value("api", "api_key", _api_key_input.text)
	cfg.set_value("api", "model", _model_input.text)
	cfg.set_value("api", "refine", _refine_check.button_pressed)
	cfg.save(SETTINGS_PATH)


func _on_generate_pressed() -> void:
	var text := _text_input.text.strip_edges()
	if text.is_empty():
		_set_status("動きの説明を入力してください", Color.ORANGE)
		return
	if _skeleton == null or _anim_player == null:
		_set_status("VRMモデルが読み込まれていません", Color.RED)
		return
	var api_key := _api_key_input.text.strip_edges()
	if api_key.is_empty():
		_set_status("API Key を入力してください", Color.ORANGE)
		return
	var model := _model_input.text.strip_edges()
	if model.is_empty():
		_set_status("モデル名を入力してください", Color.ORANGE)
		return

	_save_settings()
	_generate_btn.disabled = true
	_set_status("生成中...", Color.WHITE)
	_llm_client.generate(text, _base_url_input.text, api_key, model, _refine_check.button_pressed)


func _on_llm_progress(message: String) -> void:
	_set_status(message, Color.WHITE)


func _on_llm_succeeded(spec: Dictionary) -> void:
	_generate_btn.disabled = false
	match _loop_option.selected:
		LOOP_ON:
			spec["loop"] = true
		LOOP_OFF:
			spec["loop"] = false
	_play_generated(spec)
	_set_status(
		"再生中: %s (%.1fs / %s)" % [
			spec.get("name", "motion"),
			float(spec.get("duration", 0.0)),
			"ループ" if spec.get("loop", false) else "1回",
		],
		Color.GREEN
	)


func _on_llm_failed(error_message: String) -> void:
	_generate_btn.disabled = false
	_set_status("エラー: %s" % error_message, Color.RED)


func _play_generated(spec: Dictionary) -> void:
	var anim := AnimationBuilder.build(spec, _anim_player, _skeleton)
	ExpressionController.apply(anim, _anim_player, _expression_map, spec)
	var lib := _ensure_anim_library()
	var anim_name := str(spec.get("name", "motion"))
	if lib.has_animation(anim_name):
		lib.remove_animation(anim_name)
	lib.add_animation(anim_name, anim)
	_anim_player.stop()
	_reset_pose()
	_anim_player.play(anim_name)


func _reset_pose() -> void:
	## AnimationPlayer は新しいアニメーションに含まれないボーン/BlendShapeを
	## 前回再生分の姿勢のまま放置する (stop() では rest pose に戻らない)。
	## 生成のたびに毎回全身をレストポーズへ戻してから再生することで、
	## 前回の動きが一部残って見える不具合を防ぐ。
	if _skeleton:
		_skeleton.reset_bone_poses()
	for entries in _expression_map.values():
		for entry in (entries as Array):
			var mesh: MeshInstance3D = entry.get("mesh")
			var idx: int = entry.get("index", -1)
			if mesh and mesh.mesh and idx >= 0 and idx < mesh.mesh.get_blend_shape_count():
				mesh.set_blend_shape_value(idx, 0.0)


func _ensure_anim_library() -> AnimationLibrary:
	if _anim_player.has_animation_library(""):
		return _anim_player.get_animation_library("")
	var lib := AnimationLibrary.new()
	_anim_player.add_animation_library("", lib)
	return lib
