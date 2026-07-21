class_name MotionSpecParser
extends RefCounted

## LLM が生成したモーション spec (JSON 由来の Dictionary) の検証・角度クランプ。
## 移植元: text-to-vrma-js/src/llm.js の validateSpec() / applyWaveCorrection()

const BONE_NAMES := [
	"hips", "spine", "chest", "upperChest", "neck", "head",
	"leftShoulder", "leftUpperArm", "leftLowerArm", "leftHand",
	"rightShoulder", "rightUpperArm", "rightLowerArm", "rightHand",
	"leftUpperLeg", "leftLowerLeg", "leftFoot",
	"rightUpperLeg", "rightLowerLeg", "rightFoot",
]

const ANGLE_LIMITS := {
	"leftHand": 25.0, "rightHand": 25.0,
	"leftUpperArm": 75.0, "rightUpperArm": 75.0,
	"neck": 45.0, "head": 70.0,
	"spine": 45.0, "chest": 45.0, "upperChest": 45.0,
	"leftFoot": 60.0, "rightFoot": 60.0,
}
const DEFAULT_ANGLE_LIMIT := 175.0
const MAX_DURATION := 20.0

const WAVE_PATTERNS := ["手を振", "手をふ", "バイバイ", "ばいばい", "さようなら", "さよなら", "おいで"]

const EXPRESSION_PRESETS := [
	"happy", "angry", "sad", "relaxed", "surprised", "neutral",
	"aa", "ih", "ou", "ee", "oh",
	"blink", "blinkLeft", "blinkRight",
	"lookUp", "lookDown", "lookLeft", "lookRight",
]


## 検証・クランプ済みの spec を返す。不正な場合は {"error": String} を返す
## (呼び出し側は has("error") で判定する)。
static func validate(spec: Dictionary) -> Dictionary:
	var duration_v = spec.get("duration")
	if not (typeof(duration_v) == TYPE_FLOAT or typeof(duration_v) == TYPE_INT):
		return {"error": "生成されたモーションの duration が不正です"}
	var duration := float(duration_v)
	if duration <= 0.0:
		return {"error": "生成されたモーションの duration が不正です"}
	spec["duration"] = duration

	if duration > MAX_DURATION:
		spec["duration"] = MAX_DURATION
		var tracks_raw = spec.get("tracks")
		if tracks_raw is Dictionary:
			for bone in (tracks_raw as Dictionary).keys():
				var keys = tracks_raw[bone]
				if keys is Array:
					var in_range := []
					for k in keys:
						if k is Dictionary and typeof(k.get("t")) != TYPE_NIL and float(k.get("t", 0.0)) <= MAX_DURATION:
							in_range.append(k)
					tracks_raw[bone] = in_range
		if spec.get("hips") is Array:
			var hips_in_range := []
			for k in (spec["hips"] as Array):
				if k is Dictionary and float(k.get("t", 0.0)) <= MAX_DURATION:
					hips_in_range.append(k)
			spec["hips"] = hips_in_range

	if not (spec.get("tracks") is Dictionary):
		return {"error": "生成されたモーションに tracks がありません"}

	var tracks: Dictionary = spec["tracks"]
	for bone in tracks.keys().duplicate():
		var keys = tracks[bone]
		if not BONE_NAMES.has(bone) or not (keys is Array):
			tracks.erase(bone)
			continue
		# 肩はビルダーの自動追従に任せる (LLM の肩回転は服を歪めやすい)
		if bone == "leftShoulder" or bone == "rightShoulder":
			tracks.erase(bone)
			continue
		var limit: float = ANGLE_LIMITS.get(bone, DEFAULT_ANGLE_LIMIT)
		var cleaned := []
		for k in keys:
			if not (k is Dictionary):
				continue
			var t = k.get("t")
			var r = k.get("r")
			if not (typeof(t) == TYPE_FLOAT or typeof(t) == TYPE_INT):
				continue
			if not (r is Array) or (r as Array).size() != 3:
				continue
			var rr := []
			for v in (r as Array):
				var fv := 0.0
				if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
					fv = float(v)
				rr.append(clampf(fv, -limit, limit))
			cleaned.append({"t": float(t), "r": rr})
		# 膝は蝶番関節: 逆関節 (X 負) と横曲げを防ぐ
		if bone == "leftLowerLeg" or bone == "rightLowerLeg":
			for k in cleaned:
				var r2: Array = k["r"]
				r2[0] = clampf(r2[0], -3.0, 140.0)
				r2[1] = clampf(r2[1], -15.0, 15.0)
				r2[2] = clampf(r2[2], -15.0, 15.0)
		# 肘のガード: X ひねり (コーン回転) と後方への折れ (過伸展) を防ぐ
		if bone == "leftLowerArm" or bone == "rightLowerArm":
			var fwd_sign := 1.0 if bone == "rightLowerArm" else -1.0
			for k in cleaned:
				var r2: Array = k["r"]
				r2[0] = clampf(r2[0], -10.0, 10.0)
				var y: float = fwd_sign * r2[1]
				r2[1] = fwd_sign * clampf(y, -15.0, 135.0)
		if cleaned.is_empty():
			tracks.erase(bone)
		else:
			tracks[bone] = cleaned

	var hips_nonempty: bool = spec.get("hips") is Array and not (spec["hips"] as Array).is_empty()
	if tracks.is_empty() and not hips_nonempty:
		return {"error": "生成されたモーションに有効なトラックがありません"}

	# 肘の過伸展ガード: 上腕を大きく回した向きと逆方向へ肘が大きく折れるのを防ぐ
	for side in ["left", "right"]:
		var ua_key := "%sUpperArm" % side
		var la_key := "%sLowerArm" % side
		if not tracks.has(ua_key) or not tracks.has(la_key):
			continue
		var ua: Array = tracks[ua_key]
		var la: Array = tracks[la_key]
		if ua.is_empty() or la.is_empty():
			continue
		var ua_sorted := _sorted_by_t(ua)
		for k in la:
			var ua_z: float = _sample_z(ua_sorted, float(k["t"]))
			if absf(ua_z) < 40.0:
				continue
			var sign_v := signf(ua_z)
			var r2: Array = k["r"]
			if signf(r2[2]) == -sign_v and absf(r2[2]) > 15.0:
				r2[2] = -sign_v * 15.0

	# 前腕が頭に被さる構図の防止: 肘を深く曲げる腕は、上腕の上げを 58 度までに自動補正
	for side in ["left", "right"]:
		var ua_key := "%sUpperArm" % side
		var la_key := "%sLowerArm" % side
		if not tracks.has(ua_key) or not tracks.has(la_key):
			continue
		var ua: Array = tracks[ua_key]
		var la: Array = tracks[la_key]
		if ua.is_empty() or la.is_empty():
			continue
		var raise_sign := 1.0 if side == "left" else -1.0
		var max_bend := 0.0
		for k in la:
			var r2: Array = k["r"]
			max_bend = maxf(max_bend, maxf(absf(r2[1]), absf(r2[2])))
		if max_bend > 55.0:
			for k in ua:
				var r2: Array = k["r"]
				if raise_sign * r2[2] > 58.0:
					r2[2] = raise_sign * 58.0

	if spec.get("hips") is Array:
		var cleaned_hips := []
		for k in (spec["hips"] as Array):
			if not (k is Dictionary):
				continue
			var t = k.get("t")
			var p = k.get("p")
			if not (typeof(t) == TYPE_FLOAT or typeof(t) == TYPE_INT):
				continue
			if not (p is Array) or (p as Array).size() != 3:
				continue
			var pp := []
			for v in (p as Array):
				pp.append(float(v) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) else 0.0)
			cleaned_hips.append({"t": float(t), "p": pp})
		spec["hips"] = cleaned_hips
	else:
		spec["hips"] = []

	# 表情の検証: 未知の表情名を除去し、ウェイトを 0〜1 にクランプ
	if spec.get("expressions") is Dictionary:
		var expressions: Dictionary = spec["expressions"]
		for name in expressions.keys().duplicate():
			var keys = expressions[name]
			if not EXPRESSION_PRESETS.has(name) or not (keys is Array):
				expressions.erase(name)
				continue
			var cleaned := []
			for k in keys:
				if not (k is Dictionary):
					continue
				var t = k.get("t")
				var w = k.get("w")
				if not (typeof(t) == TYPE_FLOAT or typeof(t) == TYPE_INT):
					continue
				if not (typeof(w) == TYPE_FLOAT or typeof(w) == TYPE_INT):
					continue
				if float(t) > MAX_DURATION:
					continue
				cleaned.append({"t": float(t), "w": clampf(float(w), 0.0, 1.0)})
			if cleaned.is_empty():
				expressions.erase(name)
			else:
				expressions[name] = cleaned
		if expressions.is_empty():
			spec.erase("expressions")
		else:
			spec["expressions"] = expressions
	else:
		spec.erase("expressions")

	spec["tracks"] = tracks
	return spec


## 非ループモーションの終端に「自然に直立へ戻る」キーを足す。
## LLM が「非ループなら最後をニュートラルに戻す」指示を完全には守らない場合の保険。
## (脚など、動きの主役でないボーンほど戻し忘れられやすい)
## 移植元: text-to-vrma-js/src/specMerge.js の appendNeutralEnding()
static func append_neutral_ending(spec: Dictionary) -> void:
	const SETTLE := 0.8
	const NEUTRAL := {"leftUpperArm": [0.0, 0.0, -70.0], "rightUpperArm": [0.0, 0.0, 70.0]}

	var duration: float = float(spec.get("duration", 0.0))
	var settle_t: float = duration + SETTLE

	if spec.get("tracks") is Dictionary:
		var tracks: Dictionary = spec["tracks"]
		for bone in tracks.keys():
			var keys: Array = tracks[bone]
			if keys.is_empty():
				continue
			if bone == "hips":
				var last: Dictionary = keys[keys.size() - 1]
				var yaw_deg := _euler_to_yaw_deg(last["r"])
				keys.append({"t": settle_t, "r": [0.0, snappedf(yaw_deg, 0.01), 0.0]})
			else:
				var neutral: Array = (NEUTRAL.get(bone, [0.0, 0.0, 0.0]) as Array).duplicate()
				keys.append({"t": settle_t, "r": neutral})

	if spec.get("hips") is Array and not (spec["hips"] as Array).is_empty():
		var hips_arr: Array = spec["hips"]
		var last_p: Array = (hips_arr[hips_arr.size() - 1] as Dictionary)["p"]
		hips_arr.append({"t": settle_t, "p": [last_p[0], 0.0, last_p[2]]})

	spec["duration"] = snappedf(settle_t, 0.01)


## XYZ順オイラー角(度)を回転させたときの、ローカル+Z(前方)ベクトルのワールドYaw角(度)を求める。
## hips の向き(ヨー)だけを保持して傾きを消すために使う。
static func _euler_to_yaw_deg(deg: Array) -> float:
	var euler := Vector3(deg_to_rad(float(deg[0])), deg_to_rad(float(deg[1])), deg_to_rad(float(deg[2])))
	var basis := Basis.from_euler(euler, EULER_ORDER_XYZ)
	var fwd := basis * Vector3(0.0, 0.0, 1.0)
	return rad_to_deg(atan2(fwd.x, fwd.z))


static func is_wave_text(text: String) -> bool:
	for p in WAVE_PATTERNS:
		if text.contains(p):
			return true
	var lower := text.to_lower()
	return lower.contains("bye") or lower.contains("wave")


## 手を振る動作の幾何学的な矯正: 上腕は52度まで + 腕を上げている間は手のひらを正面に
static func apply_wave_correction(spec: Dictionary) -> void:
	if not (spec.get("tracks") is Dictionary):
		return
	var tracks: Dictionary = spec["tracks"]
	for side in ["left", "right"]:
		var raise_sign := 1.0 if side == "left" else -1.0
		var ua_key := "%sUpperArm" % side
		var la_key := "%sLowerArm" % side
		if not tracks.has(ua_key):
			continue
		var ua: Array = tracks[ua_key]
		if ua.is_empty():
			continue
		var max_raise := -INF
		for k in ua:
			max_raise = maxf(max_raise, raise_sign * float((k["r"] as Array)[2]))
		if max_raise < 35.0:
			continue # 振っていない側の腕は触らない
		for k in ua:
			var r2: Array = k["r"]
			if raise_sign * r2[2] > 52.0:
				r2[2] = raise_sign * 52.0
		if not tracks.has(la_key):
			continue
		var la: Array = tracks[la_key]
		if la.is_empty():
			continue
		var ua_sorted := _sorted_by_t(ua)
		for k in la:
			var raise_amt: float = raise_sign * _sample_z(ua_sorted, float(k["t"]))
			if raise_amt <= 30.0:
				continue
			var r2: Array = k["r"]
			# lowerArm の X ひねりは前腕が後ろへ流れるコーン回転になるため除去
			r2[0] = 0.0
			# 前腕の世界角 (上腕の上げ + 肘の曲げ) を 88〜108 度 = ほぼ垂直に保つ
			var bend: float = raise_sign * r2[2]
			var lo: float = maxf(20.0, 88.0 - raise_amt)
			var hi: float = 108.0 - raise_amt
			r2[2] = raise_sign * minf(hi, maxf(lo, bend))
		# 真の回内 (手のひらを正面に向ける) は手首ボーンの X ひねりで行う
		var hand_keys := []
		for k in la:
			var val := 0.0
			if raise_sign * _sample_z(ua_sorted, float(k["t"])) > 30.0:
				val = -85.0
			hand_keys.append({"t": k["t"], "r": [val, 0.0, 0.0]})
		tracks["%sHand" % side] = hand_keys


## keys を時刻 t 昇順にソートしたコピーを返す。
static func _sorted_by_t(keys: Array) -> Array:
	var s: Array = keys.duplicate(true)
	s.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))
	return s


## トラックの Z 値を時刻 t で線形補間サンプリング。
## sorted_keys は _sorted_by_t() 済みであること (呼び出し側でループの外で1回だけソートし、
## O(n^2) の再ソートを避ける)。
static func _sample_z(sorted_keys: Array, t: float) -> float:
	if t <= float(sorted_keys[0]["t"]):
		return (sorted_keys[0]["r"] as Array)[2]
	for i in range(sorted_keys.size() - 1):
		var next_t: float = float(sorted_keys[i + 1]["t"])
		if t <= next_t:
			var cur_t: float = float(sorted_keys[i]["t"])
			var span: float = next_t - cur_t
			if span == 0.0:
				span = 1.0
			var f: float = (t - cur_t) / span
			var z0: float = (sorted_keys[i]["r"] as Array)[2]
			var z1: float = (sorted_keys[i + 1]["r"] as Array)[2]
			return z0 + (z1 - z0) * f
	return (sorted_keys[sorted_keys.size() - 1]["r"] as Array)[2]
