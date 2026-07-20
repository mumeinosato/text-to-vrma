extends Control

## text-to-vrma: VRM読み込み (addon経由でGodot Humanoidに変換) のみ。

const DEFAULT_MODEL_PATHS := [
	"res://models/AvatarSample_VRM1.0.vrm",
	"res://models/AvatarSample_VRM0.0.vrm",
]

@onready var _vrm_root: Node3D = $HSplit/ViewportContainer/SubViewport/World/VrmRoot
@onready var _status_label: Label = $HSplit/SidePanel/Content/StatusLabel
@onready var _vrm_button: Button = $HSplit/SidePanel/Content/VrmButton
@onready var _vrm_file_dialog: FileDialog = $VrmFileDialog

var _vrm_loader := VrmLoader.new()
var _skeleton: Skeleton3D
var _anim_player: AnimationPlayer


func _ready() -> void:
	_vrm_button.pressed.connect(func(): _vrm_file_dialog.popup_centered_ratio())
	_vrm_file_dialog.file_selected.connect(_on_vrm_file_selected)
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
