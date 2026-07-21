class_name AnimationBuilder
extends RefCounted

## 検証済みモーション spec (Dictionary) から Godot Animation リソースを構築する。
## VRMA (glTF) を経由せず、Skeleton3D の Humanoid ボーンへ直接キーフレームを書き込む。
## 移植元: text-to-vrma-js/src/vrmaBuilder.js の buildVRMA() (キーフレーム部分のみ)

const HIPS_BONE := "Hips"


## VRM 規約のローワーキャメル名 ("leftUpperArm") を
## Godot SkeletonProfileHumanoid のパスカル名 ("LeftUpperArm") に変換する。
static func bone_to_godot(vrm_bone_name: String) -> String:
	if vrm_bone_name.is_empty():
		return vrm_bone_name
	return vrm_bone_name.substr(0, 1).to_upper() + vrm_bone_name.substr(1)


## spec.tracks / spec.hips から Animation を構築する。
## anim_player.root_node を起点に track のパスを解決する (Godot の既定挙動と同じ)。
static func build(spec: Dictionary, anim_player: AnimationPlayer, skeleton: Skeleton3D) -> Animation:
	var anim := Animation.new()
	anim.resource_name = String(spec.get("name", "motion"))
	anim.length = maxf(0.001, float(spec.get("duration", 1.0)))
	anim.loop_mode = Animation.LOOP_LINEAR if bool(spec.get("loop", false)) else Animation.LOOP_NONE

	var anim_root: Node = anim_player.get_node(anim_player.root_node)
	var base_path: NodePath = anim_root.get_path_to(skeleton)

	var tracks: Dictionary = (spec.get("tracks", {}) as Dictionary).duplicate(true)
	_apply_shoulder_follow(tracks)
	_apply_default_finger_curl(tracks, anim.length)

	for bone_name in tracks.keys():
		var keys: Array = tracks[bone_name]
		if keys.is_empty():
			continue
		var godot_name := bone_to_godot(bone_name)
		if skeleton.find_bone(godot_name) == -1:
			continue # このモデルは当該ボーンを持たない
		var sorted_keys: Array = keys.duplicate(true)
		sorted_keys.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))

		var track_idx := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(track_idx, NodePath(str(base_path) + ":" + godot_name))
		for k in sorted_keys:
			var quat := _euler_deg_to_quat(k["r"])
			anim.rotation_track_insert_key(track_idx, float(k["t"]), quat)

	var hips_keys: Array = spec.get("hips", [])
	var hips_idx := skeleton.find_bone(HIPS_BONE)
	if not hips_keys.is_empty() and hips_idx != -1:
		var rest_pos := skeleton.get_bone_rest(hips_idx).origin
		var sorted_hips: Array = hips_keys.duplicate(true)
		sorted_hips.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))

		var track_idx := anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(track_idx, NodePath(str(base_path) + ":" + HIPS_BONE))
		for k in sorted_hips:
			var p: Array = k["p"]
			var pos := rest_pos + Vector3(float(p[0]), float(p[1]), float(p[2]))
			anim.position_track_insert_key(track_idx, float(k["t"]), pos)

	return anim


## VRM 1.0 はオイラー角 XYZ 順 (度)。Godot の Quaternion.from_euler は YXZ 順として
## 解釈されるため、Basis.from_euler(..., EULER_ORDER_XYZ) 経由で変換する。
static func _euler_deg_to_quat(deg: Array) -> Quaternion:
	var euler := Vector3(deg_to_rad(float(deg[0])), deg_to_rad(float(deg[1])), deg_to_rad(float(deg[2])))
	var basis := Basis.from_euler(euler, EULER_ORDER_XYZ)
	return basis.get_rotation_quaternion()


## 自然な手: 指を軽く曲げたデフォルトポーズを、LLM が指定していない指ボーンに焼き込む。
## (LLM には指ボーンを公開していないため、常に発動する)
## 移植元: text-to-vrma-js/src/vrmaBuilder.js の FINGER_CURL 適用ブロック
static func _apply_default_finger_curl(tracks: Dictionary, duration: float) -> void:
	const FINGER_CURL_DEG := {"Proximal": 14.0, "Intermediate": 17.0, "Distal": 10.0}
	const FINGERS := ["Index", "Middle", "Ring", "Little"]
	for side in ["left", "right"]:
		var sign_v := -1.0 if side == "left" else 1.0
		for finger in FINGERS:
			for seg in FINGER_CURL_DEG.keys():
				var bone := "%s%s%s" % [side, finger, seg]
				if tracks.has(bone):
					continue # LLM や他の処理が既にこのボーンを使っている場合は上書きしない
				var deg: float = FINGER_CURL_DEG[seg]
				var r := [0.0, 0.0, sign_v * deg]
				tracks[bone] = [{"t": 0.0, "r": r}, {"t": duration, "r": r}]


## 肩の自動追従: 腕を高く上げたとき鎖骨を少し持ち上げ、肩付け根のメッシュ潰れを軽減する
## (左の腕上げ = upperArm Z 正 / 右 = 負。下げた腕では発動しない)
static func _apply_shoulder_follow(tracks: Dictionary) -> void:
	for side in ["left", "right"]:
		var shoulder_bone := "%sShoulder" % side
		var ua_key := "%sUpperArm" % side
		if not tracks.has(ua_key) or tracks.has(shoulder_bone):
			continue
		var ua: Array = tracks[ua_key]
		if ua.is_empty():
			continue
		var raise_sign := 1.0 if side == "left" else -1.0
		var keys := []
		var any_nonzero := false
		for k in ua:
			var z: float = (k["r"] as Array)[2]
			var raise_amt: float = maxf(0.0, raise_sign * z - 55.0)
			var lift: float = minf(14.0, raise_amt * 0.4)
			if lift != 0.0:
				any_nonzero = true
			keys.append({"t": k["t"], "r": [0.0, 0.0, raise_sign * lift]})
		if any_nonzero:
			tracks[shoulder_bone] = keys
