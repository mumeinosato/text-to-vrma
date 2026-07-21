class_name ExpressionController
extends RefCounted

## LLM spec の expressions を MeshInstance3D の BlendShape トラックとして Animation に焼き込む。
## LLM が瞬き (blink) を入れなかった場合は自動でまばたきを補完する (idleMotion.js 相当)。

const BLINK_PRESET := "blink"
const BLINK_INTERVAL := 2.6 # 秒。JS の idleMotion.js の頻度目安 (2〜4秒おき) に合わせる
const BLINK_CLOSE_TIME := 0.07
const BLINK_OPEN_TIME := 0.08


## expression_map: vrm_loader.gd が返す { 表情名: [{mesh, index, weight}, ...] }
## spec: MotionSpecParser.validate() 済みの spec (expressions フィールドを含みうる)
static func apply(anim: Animation, anim_player: AnimationPlayer, expression_map: Dictionary, spec: Dictionary) -> void:
	if expression_map.is_empty():
		return

	var anim_root: Node = anim_player.get_node(anim_player.root_node)
	var expressions: Dictionary = spec.get("expressions", {})
	if not (expressions is Dictionary):
		expressions = {}

	var used_blink := false
	for expr_name in expressions.keys():
		if not expression_map.has(expr_name):
			continue
		var keys: Array = expressions[expr_name]
		if keys.is_empty():
			continue
		_add_expression_track(anim, anim_root, expression_map[expr_name], keys)
		if expr_name == BLINK_PRESET:
			used_blink = true

	if not used_blink and expression_map.has(BLINK_PRESET):
		_add_expression_track(anim, anim_root, expression_map[BLINK_PRESET], _auto_blink_keys(anim.length))


static func _add_expression_track(anim: Animation, anim_root: Node, entries: Array, keys: Array) -> void:
	var sorted_keys: Array = keys.duplicate(true)
	sorted_keys.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))
	for entry in entries:
		var mesh: MeshInstance3D = entry["mesh"]
		var shape_idx: int = entry["index"]
		if mesh == null or mesh.mesh == null:
			continue
		if shape_idx < 0 or shape_idx >= mesh.mesh.get_blend_shape_count():
			continue
		var shape_name: String = str(mesh.mesh.get_blend_shape_name(shape_idx))
		var bind_weight: float = entry.get("weight", 1.0)

		var track_idx := anim.add_track(Animation.TYPE_BLEND_SHAPE)
		anim.track_set_path(track_idx, NodePath(str(anim_root.get_path_to(mesh)) + ":" + shape_name))
		anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)
		for k in sorted_keys:
			var w: float = clampf(float(k.get("w", 0.0)), 0.0, 1.0) * bind_weight
			anim.track_insert_key(track_idx, float(k["t"]), w)


## 2〜4秒おきに 0→1→0 を約0.15秒でまばたきする自動キー列を生成する。
static func _auto_blink_keys(duration: float) -> Array:
	var keys: Array = [{"t": 0.0, "w": 0.0}]
	var t := BLINK_INTERVAL
	while t < duration - 0.2:
		keys.append({"t": t - BLINK_CLOSE_TIME, "w": 0.0})
		keys.append({"t": t, "w": 1.0})
		keys.append({"t": t + BLINK_OPEN_TIME, "w": 0.0})
		t += BLINK_INTERVAL
	keys.append({"t": duration, "w": 0.0})
	return keys
