class_name OrbitCamera
extends Node3D

## マウスドラッグで周回・ホイールでズームする簡易プレビューカメラ。

@export var distance := 3.0
@export var min_distance := 0.8
@export var max_distance := 8.0
@export var rotate_speed := 0.008
@export var zoom_speed := 0.2
@export var pitch_limit := 1.3

var _dragging := false
# VRMアバターはGodotの-Z前方慣習で読み込まれる(addonがVRM1.0を180度回転、
# VRM0.0はそのまま-Z前方なので無回転)ため、カメラは-Z側から+Z方向を
#見ないと背中しか映らない。よって初期yawはPI(180度)。
var _yaw := PI
var _pitch := -0.12

@onready var _cam: Camera3D = $Camera3D


func _ready() -> void:
	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			distance = clampf(distance - zoom_speed, min_distance, max_distance)
			_update_transform()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			distance = clampf(distance + zoom_speed, min_distance, max_distance)
			_update_transform()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * rotate_speed
		_pitch = clampf(_pitch - mm.relative.y * rotate_speed, -pitch_limit, pitch_limit)
		_update_transform()


func _update_transform() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)
	if _cam:
		_cam.position = Vector3(0.0, 0.0, distance)
