class_name VrmLoader
extends RefCounted

## VRM 読み込み。生glTFとして読み込み (メッシュ・スキンは正しいまま) ボーン名だけを
## Godot Humanoid (SkeletonProfileHumanoid) にリネームする。
##
## なぜアドオンの perform_retarget を使わないか:
## アドオンのフル VRM インポート (vrmc_vrm.gd の _import_post → perform_retarget) は
## スケルトンの rest 姿勢を SkeletonProfileHumanoid の参照姿勢へ回転させ、その分だけ
## スキンのバインドポーズを apply_mesh_rotation で補正する。しかし Godot 4.7.1 の
## ランタイム GLTFDocument 経路ではこの補正が破綻し、腕・脚のメッシュがリボン状に
## 伸びてしまう (単一登録でも再現)。エディタの .import 経由でも同症状か生glTF素通しに
## なるため信頼できない。
##
## 代わりに:
##   1. VRM拡張を登録せず GLTFDocument で生glTFとして読む (メッシュ・スキンは元のまま正しい)。
##   2. VRM拡張JSON (VRM / VRMC_vrm) から humanBone → ノード対応を取り出し、
##      アドオンの vrm_bone_renamer_humanoid + vrm_bone_renamer で
##      スケルトンのボーン名だけを Humanoid 名 (Hips / LeftUpperArm ...) にリネームする。
##      rest 姿勢は変えないのでスキンは壊れない (スキンはボーン"インデックス"バインドのため
##      名前変更の影響を受けない)。
##   3. VRM1.0 は +Z 前方なので root を Y 180度回転して Godot 慣習 (-Z 前方) に合わせる。
##
## これによりメッシュ正常表示と Humanoid ボーン名を両立でき、後から Humanoid 前提の
## アニメーションを流し込める。

signal load_failed(message: String)

const _BoneRenamerHumanoid = preload("res://addons/vrm/importer/common/vrm_bone_renamer_humanoid.gd")
const _BoneRenamer = preload("res://addons/vrm/importer/common/vrm_bone_renamer.gd")

# VRM0 の presetName -> VRM1 の表情名 (VRMC_vrm_animation 準拠) への変換表。
# 参考: addons/vrm/importer/common/animation/vrm_animation_constants.gd の vrm0_to_vrm1_presets
const _VRM0_PRESET_TO_VRM1 := {
	"joy": "happy", "angry": "angry", "sorrow": "sad", "fun": "relaxed",
	"a": "aa", "i": "ih", "u": "ou", "e": "ee", "o": "oh",
	"blink": "blink", "blink_l": "blinkLeft", "blink_r": "blinkRight",
	"neutral": "neutral",
}

var _last_expression_map: Dictionary = {}


func load_into(parent: Node3D, path: String) -> Dictionary:
	## Returns { root, skeleton, anim_player, expression_map } or empty on failure.
	for child in parent.get_children():
		child.queue_free()

	_last_expression_map = {}
	var root: Node = _load_runtime(path)

	if root == null:
		load_failed.emit("Failed to load VRM: %s" % path)
		return {}

	parent.add_child(root)
	if root is Node3D:
		(root as Node3D).position = Vector3.ZERO

	var skeleton := _find_skeleton(root)
	var anim_player := _find_anim_player(root)
	if anim_player == null and root != null:
		anim_player = AnimationPlayer.new()
		anim_player.name = "AnimationPlayer"
		root.add_child(anim_player)
	return {
		"root": root,
		"skeleton": skeleton,
		"anim_player": anim_player,
		"expression_map": _last_expression_map,
	}


func _load_runtime(path: String) -> Node:
	var abs_path := path
	if path.begins_with("res://"):
		abs_path = ProjectSettings.globalize_path(path)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	# VRM拡張は登録しない。生glTFとして読み込む (スキンはインデックスバインドのまま、
	# メッシュは正しく表示される)。handle_binary_image はテクスチャを埋め込みで展開。
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var err := doc.append_from_file(abs_path, state, 0)
	if err != OK:
		push_error("GLTF append_from_file failed: %s (%s)" % [abs_path, error_string(err)])
		return null
	var root := doc.generate_scene(state)
	if root == null:
		return null
	_convert_to_humanoid(root, state)
	return root


func _convert_to_humanoid(root: Node, gstate: GLTFState) -> void:
	## 生glTFのスケルトンのボーン名を Godot Humanoid にリネームする (rest 姿勢は変えない)。
	var skeleton := _find_skeleton(root)
	if skeleton == null:
		return
	var json: Dictionary = gstate.json
	var extensions: Dictionary = json.get("extensions", {})

	var is_vrm0 := extensions.has("VRM")
	var human_bone_to_idx := _extract_human_bone_map(extensions, is_vrm0)
	if human_bone_to_idx.is_empty():
		push_warning("VRM humanoid mapping not found; skeleton left with original bone names")
		return

	# アドオンのヘルパで Humanoid プロファイル名 → 現在のボーン名 の BoneMap を作る。
	var bone_map: BoneMap = _BoneRenamerHumanoid.create_humanoid_bone_map(
		gstate, human_bone_to_idx, is_vrm0
	)
	# rest 姿勢の回転は行わず、名前だけリネーム (+ Root ボーン整備)。
	_BoneRenamer.rename_skeleton_bones(gstate, root, skeleton, bone_map, 1, "Skeleton3D")
	skeleton.set_meta("vrm_humanoid_bone_mapping", bone_map)

	# VRM1.0 は +Z 前方。Godot 慣習 (-Z 前方) に合わせて root を 180度回転する。
	if not is_vrm0 and root is Node3D:
		(root as Node3D).rotation.y = PI

	_last_expression_map = _extract_expression_map(root, gstate, extensions, is_vrm0)


func _extract_human_bone_map(extensions: Dictionary, is_vrm0: bool) -> Dictionary:
	## humanBone名 (VRM規約: hips, leftUpperArm ...) → glTFノードindex の辞書を返す。
	var out := {}
	if is_vrm0:
		var vrm: Dictionary = extensions.get("VRM", {})
		var humanoid: Dictionary = vrm.get("humanoid", {})
		for hb in humanoid.get("humanBones", []):
			if hb is Dictionary and hb.has("bone") and hb.has("node"):
				out[hb["bone"]] = int(hb["node"])
	else:
		var vrmc: Dictionary = extensions.get("VRMC_vrm", {})
		var humanoid: Dictionary = vrmc.get("humanoid", {})
		var human_bones: Dictionary = humanoid.get("humanBones", {})
		for bone_name in human_bones:
			var entry = human_bones[bone_name]
			if entry is Dictionary and entry.has("node"):
				out[bone_name] = int(entry["node"])
	return out


func _extract_expression_map(root: Node, gstate: GLTFState, extensions: Dictionary, is_vrm0: bool) -> Dictionary:
	## 表情名 (VRM1規約: happy, blink ...) -> [{ mesh: MeshInstance3D, index: int, weight: float }, ...] の辞書を返す。
	## モーフターゲットの bind のみを対象にする (マテリアル切り替え等は非対応)。
	var map := {}
	if is_vrm0:
		var vrm: Dictionary = extensions.get("VRM", {})
		var blend_master: Dictionary = vrm.get("blendShapeMaster", {})
		var groups: Array = blend_master.get("blendShapeGroups", [])
		if groups.is_empty():
			return map
		var mesh_idx_to_node_idx := {}
		var nodes_json: Array = gstate.json.get("nodes", [])
		for i in range(nodes_json.size()):
			var n = nodes_json[i]
			if n is Dictionary and n.has("mesh"):
				var mesh_idx := int(n["mesh"])
				if not mesh_idx_to_node_idx.has(mesh_idx):
					mesh_idx_to_node_idx[mesh_idx] = i
		for group in groups:
			if not (group is Dictionary):
				continue
			var expr_name := _vrm0_expression_name(group)
			if expr_name.is_empty():
				continue
			var entries := _collect_binds(
				root, gstate, group.get("binds", []), "mesh", mesh_idx_to_node_idx, 100.0
			)
			if not entries.is_empty():
				map[expr_name] = entries
	else:
		var vrmc: Dictionary = extensions.get("VRMC_vrm", {})
		var expr_ext: Dictionary = vrmc.get("expressions", {})
		var all_groups := {}
		for expr_name in (expr_ext.get("preset", {}) as Dictionary).keys():
			all_groups[expr_name] = expr_ext["preset"][expr_name]
		for expr_name in (expr_ext.get("custom", {}) as Dictionary).keys():
			all_groups[expr_name] = expr_ext["custom"][expr_name]
		for expr_name in all_groups.keys():
			var group = all_groups[expr_name]
			if not (group is Dictionary):
				continue
			var entries := _collect_binds(
				root, gstate, group.get("morphTargetBinds", []), "node", {}, 1.0
			)
			if not entries.is_empty():
				map[expr_name] = entries
	return map


func _vrm0_expression_name(group: Dictionary) -> String:
	var preset_name := str(group.get("presetName", ""))
	if preset_name != "unknown":
		return _VRM0_PRESET_TO_VRM1.get(preset_name, "")
	# VRM0 には標準の "surprised" プリセットが無く、対応するモデルは custom (unknown) 名で
	# 積んでいることが多い (例: "Surprised")。大文字小文字を無視して既知の表情名に正規化する。
	var custom_name := str(group.get("name", ""))
	for canonical in MotionSpecParser.EXPRESSION_PRESETS:
		if canonical.to_lower() == custom_name.to_lower():
			return canonical
	return custom_name


## binds: VRM0 は {mesh: meshIndex, index, weight(0-100)}、VRM1 は {node: nodeIndex, index, weight(0-1)}。
## key_field でどちらの参照方式かを切り替え、node_lookup (VRM0 のみ) で mesh index -> node index を引く。
##
## ノードの解決は GLTFState.get_scene_node() を使わない。ボーンリネーム等でシーンツリーが
## 変更された後だと解決に失敗することがあるため、代わりに元の glTF ノード名 (rename の影響を
## 受けないメッシュノード名) でシーンツリーを名前検索する (アドオンの rename_bones と同じ考え方)。
func _collect_binds(
	root: Node, gstate: GLTFState, binds: Array, key_field: String, node_lookup: Dictionary, weight_scale: float
) -> Array:
	var entries := []
	var gltf_nodes: Array = gstate.nodes
	for b in binds:
		if not (b is Dictionary):
			continue
		var node_idx := -1
		if key_field == "mesh":
			var mesh_idx := int(b.get("mesh", -1))
			if not node_lookup.has(mesh_idx):
				continue
			node_idx = int(node_lookup[mesh_idx])
		else:
			node_idx = int(b.get("node", -1))
		if node_idx < 0 or node_idx >= gltf_nodes.size():
			continue
		var node_name: String = (gltf_nodes[node_idx] as GLTFNode).resource_name
		if node_name.is_empty():
			continue
		var scene_node: Node = root.find_child(node_name, true, false)
		if not (scene_node is MeshInstance3D):
			continue
		var shape_idx := int(b.get("index", -1))
		if shape_idx < 0:
			continue
		entries.append({
			"mesh": scene_node,
			"index": shape_idx,
			"weight": float(b.get("weight", weight_scale)) / weight_scale,
		})
	return entries


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var found := _find_skeleton(c)
		if found:
			return found
	return null


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var found := _find_anim_player(c)
		if found:
			return found
	return null
