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


func load_into(parent: Node3D, path: String) -> Dictionary:
	## Returns { root, skeleton, anim_player } or empty on failure.
	for child in parent.get_children():
		child.queue_free()

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
	return {"root": root, "skeleton": skeleton, "anim_player": anim_player}


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
