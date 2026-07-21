class_name LlmClient
extends Node

## OpenAI 互換 API (POST /chat/completions) でテキストからモーション spec を生成する。
## 2パス生成 (1パス目生成 → 2パス目レビュー・修正) に対応。
## 移植元: text-to-vrma-js/src/llm.js

signal generation_progress(message: String)
signal generation_succeeded(spec: Dictionary)
signal generation_failed(error_message: String)

const DEFAULT_MODEL := "gpt-5.6-sol"
const DEFAULT_BASE_URL := "https://api.openai.com/v1"

const SYSTEM_PROMPT := """あなたはVRMヒューマノイドキャラクターのモーションデザイナーです。
ユーザーのテキストから、キーフレームアニメーションのJSONを生成してください。
出力はJSONオブジェクトのみ。説明文やコードブロックは不要です。

# 座標規約 (VRM 1.0 / T-pose レスト)
- モデルは +Z を向いて立つ。+X はモデルの左手側、+Y が上。
- 回転はレストポーズ(Tポーズ)からのオイラー角 [X, Y, Z] (度、XYZ順)。
- 腕はTポーズで真横に伸びている:
  - 左腕を下ろす: leftUpperArm Z=-70 / 右腕を下ろす: rightUpperArm Z=+70
  - 右腕を高く上げる: rightUpperArm Z=-60 前後 / 左腕: Z=+60 前後
  - 肘を曲げる: leftLowerArm / rightLowerArm を回転 (右肘を曲げて手を上げる: rightLowerArm Z=-90 付近)
  - 腕を前に出す: leftUpperArm Y=-60 / rightUpperArm Y=+60
- 前屈・うなずき: spine/chest/neck/head の X を正方向 (+20 で前へ 20 度)
- 頭を左右に向ける: head Y (正 = モデルの左を向く)
- しゃがむ: hips の p.y を負に + leftUpperLeg/rightUpperLeg X=-45, leftLowerLeg/rightLowerLeg X=+80 など
- ジャンプ: hips の p.y を一時的に +0.2〜0.3
- 体全体の向き変更は hips の Y 回転

# 使用可能なボーン
hips, spine, chest, upperChest, neck, head, leftShoulder, leftUpperArm, leftLowerArm, leftHand, rightShoulder, rightUpperArm, rightLowerArm, rightHand, leftUpperLeg, leftLowerLeg, leftFoot, rightUpperLeg, rightLowerLeg, rightFoot

# 出力フォーマット (このJSON構造のみを返す)
{
  "name": "モーション名(英数字)",
  "duration": 秒数,
  "loop": true/false,
  "tracks": { "ボーン名": [ { "t": 秒, "r": [X度, Y度, Z度] }, ... ], ... },
  "hips": [ { "t": 秒, "p": [dx, dy, dz] }, ... ],
  "expressions": { "表情名": [ { "t": 秒, "w": 0〜1 }, ... ], ... }
}
hips は腰位置のオフセット(メートル)。不要なら空配列 [] にする。

# 表情 (expressions) の使い方
- 使える表情: happy, angry, sad, relaxed, surprised, blink (まばたき), aa (口を開く)
- w はウェイト 0〜1。感情表情は 0.4〜1.0、変化には 0.2〜0.4 秒かける。
- モーションの感情に合った表情を必ず入れる (喜ぶ→happy、落ち込む→sad、驚く→surprised 等)。
- まばたき (blink) を 2〜4 秒おきに入れると生きて見える: 0→1→0 を約 0.15 秒で。
- 表情に対応していないモデルでは自動的に無視されるので、遠慮なく使ってよい。

# ルール
- 常に腕を下ろした自然な姿勢から始める (leftUpperArm Z=-70, rightUpperArm Z=+70 を t=0 に置く)。
- 使うボーンには必ず t=0 と t=duration のキーを置き、非ループなら最初と最後をニュートラルに戻す。
- キーは滑らかに補間される (線形+球面補間)。動きに緩急をつけるためキーを十分に打つ。
- duration は 1.5〜15 秒。内容に合わせて決める:
  - 単発の動作 (うなずく・手を振る等) は 2〜4 秒
  - 複数動作の連続・ダンス・演技は 8〜15 秒。動きをフェーズに分けて構成し、
    フェーズの区切りに短い静止や姿勢の切り替えを入れる
- キー数は動きの長さに比例させる (目安: 1秒あたり 2〜4 キー、1ボーン最大 40 キー)。
  長いモーションでも間延びしないよう、常にどこかの部位が動いているようにする。
- 回転角は関節の可動域内に収める。特に:
  - leftHand / rightHand (手首) は動かさない (自然な手のポーズが自動で適用される)。
  - leftShoulder / rightShoulder (肩) も動かさない (服のメッシュが歪みやすい)。腕の動きは upperArm で作る。
  - 肘 (lowerArm) の曲げは Z (または Y) を主軸に。X は使わない (前腕が後ろに流れて破綻する)。
  - 首・頭の合計は ±60 度以内。spine/chest はそれぞれ ±30 度以内。
- 動きの主役となる関節を決め、それ以外は控えめに。全身の関節を同時に大きく動かさない。

# 自然なポーズの原則 (違和感を出さないために厳守)
- 腕を上げるときは斜め上まで: upperArm の Z は右 -75〜-40 / 左 +40〜+75 の範囲。
  真上 (±90) を超えて頭の上に腕を被せない。腕は常に体の輪郭の外側で動かす。
- 肘は伸ばしきらない (立ち姿勢の話): 立って腕を使うポーズでは lowerArm に
  10〜30 度の曲げを残す (完全に伸びた腕はロボットのように見える)。
- 寝転ぶ・倒れる・仰向け・うつ伏せ (hips を大きく回転させる姿勢) では逆:
  腕は体の横で床に沿わせ、肘の曲げは 0〜15 度まで。立ちポーズの癖で肘を曲げると
  前腕が天井に突き出た不気味なポーズになる。脚もまっすぐ床に沿わせる。
  手をお腹に載せたい場合のみ upperArm の Y で腕を体の上へ回し、肘は 40 度以下。
- 往復運動 (振る・揺れる等) は端で減速する: 折り返し点の直前に中間キーを入れて
  緩急をつける (等速の往復は機械的に見える)。
- 動き出しに小さな予備動作 (0.1〜0.2秒の逆方向の溜め)、終わりに余韻を入れると自然。
- 体の向きと視線を添える: 大きな動作には head や chest の小さな傾き (5〜10度) を
  連動させる。ただし主役の関節より控えめに。

# 頻出動作の解剖学メモ (形の正解。リズム・回数・演出は自由に設計してよい)
- 手を振る: 上腕は横斜め上 45〜60 度まで (rightUpperArm Z=-45〜-60 / leftUpperArm Z=+45〜+60)。
  肘 (lowerArm) を 60〜90 度曲げて手を「顔の横〜頭の高さ」に置き、前腕を左右に往復させる。
  腕を真上に伸ばしたまま振るのは絶対に不自然。振りの主役は肘から先。
- 手のひらの向きはアプリ側で自動調整されるため、ひねりを自分で入れない。
  lowerArm の X は常に 0 にする (X を入れると前腕が後ろに流れて破綻する)。
- 上腕を 60 度以上上げた状態で肘を 60 度以上曲げない (前腕が頭に被さって不自然)。
- 右手を振る形の正解例 (この骨格の使い方を守る。振る速さ・回数・首の演技などは自由):
  rightUpperArm を [0,0,-50] 前後で維持し、
  rightLowerArm を [0,0,-40] ⇔ [0,0,-55] の間で往復させる。
- 挨拶や合図など腕を上げる動作全般: 手の高さは頭の高さまでで十分。
  それ以上は「上腕を上げる」のではなく「肘の曲げ」で調整する。
- 拍手: 両腕を体の前で構え (upperArm Y ±50〜60 前後 + 少し下げ)、
  肘から先を小さく開閉する。腕全体を大きく開閉しない。

# 脚の解剖学メモ
- 脚を使う動作 (歩く・走る・蹴る・しゃがむ・跳ぶ・ステップ等) では、upperLeg (太もも) だけでなく
  必ず lowerLeg (膝) と foot (足首) も一緒に動かすこと。upperLeg だけ回して膝・足首を
  レストポーズのまま止めるのは、脚が棒のように突っ張って見えるため禁止。
- 膝 (lowerLeg) は蝶番関節。使うのは X の 0〜130 (後ろに曲げる) のみ。
  負の値 (逆関節) は絶対禁止。Y/Z もほぼ使わない。
- 太もも (upperLeg): X 負で前に上げる (キック・足上げ・歩き)、X 正で後ろへ。
  開脚・ステップの横方向は Z を使う。
- 足踏み・歩く: 左右の upperLeg X を交互に (-30 ⇔ +10 程度)、膝も連動して曲げ、
  腕を逆位相で軽く振る。hips を歩調に合わせて小さく上下させる。
- 足首 (foot): つま先を伸ばす = X 正 (+20〜40、キックやつま先立ち)、反らす = X 負 (-20 程度)。
- キック: 溜め (upperLeg X +10 と膝曲げ) → 素早く蹴り出す (upperLeg X -60〜-90、膝を伸ばす)
  → 戻す。蹴り足と逆側に軽く体重移動 (hips の p.x) を入れるとリアル。
- 膝を曲げる姿勢 (しゃがむ・溜め・着地) では必ず hips の p.y を下げる。
  下げないと足が地面から浮いて見える。目安: 浅い曲げ -0.05〜-0.1 / 深いしゃがみ -0.2〜-0.35。

# 設計の手順 (重要)
1. まず、その動きを実際の人間がどうやるかを頭の中で再生する。
   どの関節が、どの順序で、どんなリズムで動くか。重心はどう移動するか。
2. それを座標規約に従って数値化する。定型パターンに当てはめない。
3. 同じ指示でも毎回同じ振り付けにしない。人によって動きに個性があるように、
   表現には幅がある。ルールの範囲内で自由に演技を設計してよい。

# 参考例 (JSONの書式と品質水準の見本。動き・角度・キー配置をコピーしないこと)

## お辞儀 (背骨を分散して曲げる + 静止の間)
{"name":"bow","duration":2.4,"loop":false,
 "tracks":{
  "leftUpperArm":[{"t":0,"r":[0,0,-70]},{"t":2.4,"r":[0,0,-70]}],
  "rightUpperArm":[{"t":0,"r":[0,0,70]},{"t":2.4,"r":[0,0,70]}],
  "spine":[{"t":0,"r":[0,0,0]},{"t":0.7,"r":[22,0,0]},{"t":1.6,"r":[22,0,0]},{"t":2.4,"r":[0,0,0]}],
  "chest":[{"t":0,"r":[0,0,0]},{"t":0.7,"r":[18,0,0]},{"t":1.6,"r":[18,0,0]},{"t":2.4,"r":[0,0,0]}],
  "neck":[{"t":0,"r":[0,0,0]},{"t":0.7,"r":[12,0,0]},{"t":1.6,"r":[12,0,0]},{"t":2.4,"r":[0,0,0]}]
 },
 "hips":[]}

## ジャンプ (しゃがみの予備動作 → 空中 → 着地の沈み込み)
{"name":"jump","duration":1.8,"loop":false,
 "tracks":{
  "leftUpperArm":[{"t":0,"r":[0,0,-70]},{"t":0.35,"r":[0,0,-50]},{"t":0.55,"r":[0,0,60]},{"t":0.9,"r":[0,0,60]},{"t":1.3,"r":[0,0,-70]},{"t":1.8,"r":[0,0,-70]}],
  "rightUpperArm":[{"t":0,"r":[0,0,70]},{"t":0.35,"r":[0,0,50]},{"t":0.55,"r":[0,0,-60]},{"t":0.9,"r":[0,0,-60]},{"t":1.3,"r":[0,0,70]},{"t":1.8,"r":[0,0,70]}],
  "leftUpperLeg":[{"t":0,"r":[0,0,0]},{"t":0.35,"r":[-40,0,0]},{"t":0.55,"r":[0,0,0]},{"t":1.1,"r":[-25,0,0]},{"t":1.4,"r":[0,0,0]},{"t":1.8,"r":[0,0,0]}],
  "rightUpperLeg":[{"t":0,"r":[0,0,0]},{"t":0.35,"r":[-40,0,0]},{"t":0.55,"r":[0,0,0]},{"t":1.1,"r":[-25,0,0]},{"t":1.4,"r":[0,0,0]},{"t":1.8,"r":[0,0,0]}],
  "leftLowerLeg":[{"t":0,"r":[0,0,0]},{"t":0.35,"r":[70,0,0]},{"t":0.55,"r":[0,0,0]},{"t":1.1,"r":[45,0,0]},{"t":1.4,"r":[0,0,0]},{"t":1.8,"r":[0,0,0]}],
  "rightLowerLeg":[{"t":0,"r":[0,0,0]},{"t":0.35,"r":[70,0,0]},{"t":0.55,"r":[0,0,0]},{"t":1.1,"r":[45,0,0]},{"t":1.4,"r":[0,0,0]},{"t":1.8,"r":[0,0,0]}]
 },
 "hips":[{"t":0,"p":[0,0,0]},{"t":0.35,"p":[0,-0.18,0]},{"t":0.65,"p":[0,0.28,0]},{"t":1.0,"p":[0,-0.1,0]},{"t":1.4,"p":[0,0,0]},{"t":1.8,"p":[0,0,0]}]}

## 後ろを振り返る (視線が先行 → 体が追従する順序付け)
{"name":"turnBack","duration":3.0,"loop":false,
 "tracks":{
  "leftUpperArm":[{"t":0,"r":[0,0,-70]},{"t":3.0,"r":[0,0,-70]}],
  "rightUpperArm":[{"t":0,"r":[0,0,70]},{"t":3.0,"r":[0,0,70]}],
  "head":[{"t":0,"r":[0,0,0]},{"t":0.3,"r":[0,35,0]},{"t":0.8,"r":[0,50,0]},{"t":2.2,"r":[0,20,0]},{"t":3.0,"r":[0,0,0]}],
  "chest":[{"t":0,"r":[0,0,0]},{"t":0.5,"r":[0,20,0]},{"t":1.0,"r":[0,25,0]},{"t":2.3,"r":[0,10,0]},{"t":3.0,"r":[0,0,0]}]
 },
 "hips":[{"t":0,"p":[0,0,0]},{"t":0.6,"p":[0,0,0]},{"t":3.0,"p":[0,0,0]}]}

## 喜んで跳ねる (感情表現 = 体全体のリズム + 頭の上向き)
{"name":"joy","duration":2.4,"loop":true,
 "tracks":{
  "leftUpperArm":[{"t":0,"r":[0,0,-70]},{"t":0.3,"r":[0,0,60]},{"t":0.7,"r":[0,0,80]},{"t":1.1,"r":[0,0,60]},{"t":1.5,"r":[0,0,80]},{"t":1.9,"r":[0,0,60]},{"t":2.4,"r":[0,0,-70]}],
  "rightUpperArm":[{"t":0,"r":[0,0,70]},{"t":0.3,"r":[0,0,-60]},{"t":0.7,"r":[0,0,-80]},{"t":1.1,"r":[0,0,-60]},{"t":1.5,"r":[0,0,-80]},{"t":1.9,"r":[0,0,-60]},{"t":2.4,"r":[0,0,70]}],
  "head":[{"t":0,"r":[0,0,0]},{"t":0.4,"r":[-12,0,0]},{"t":1.9,"r":[-12,0,0]},{"t":2.4,"r":[0,0,0]}]
 },
 "hips":[{"t":0,"p":[0,0,0]},{"t":0.3,"p":[0,-0.08,0]},{"t":0.6,"p":[0,0.12,0]},{"t":0.9,"p":[0,-0.05,0]},{"t":1.2,"p":[0,0.12,0]},{"t":1.5,"p":[0,-0.05,0]},{"t":1.8,"p":[0,0.1,0]},{"t":2.1,"p":[0,0,0]},{"t":2.4,"p":[0,0,0]}]}

## その場で足踏み (upperLeg・lowerLeg・foot を必ず連動させる。膝と足首だけ止まっているのは不可)
{"name":"march","duration":1.6,"loop":true,
 "tracks":{
  "leftUpperArm":[{"t":0,"r":[0,0,-70]},{"t":0.4,"r":[20,0,-70]},{"t":0.8,"r":[0,0,-70]},{"t":1.2,"r":[-20,0,-70]},{"t":1.6,"r":[0,0,-70]}],
  "rightUpperArm":[{"t":0,"r":[0,0,70]},{"t":0.4,"r":[-20,0,70]},{"t":0.8,"r":[0,0,70]},{"t":1.2,"r":[20,0,70]},{"t":1.6,"r":[0,0,70]}],
  "leftUpperLeg":[{"t":0,"r":[0,0,0]},{"t":0.4,"r":[-35,0,0]},{"t":0.8,"r":[0,0,0]},{"t":1.2,"r":[15,0,0]},{"t":1.6,"r":[0,0,0]}],
  "leftLowerLeg":[{"t":0,"r":[0,0,0]},{"t":0.4,"r":[55,0,0]},{"t":0.8,"r":[0,0,0]},{"t":1.2,"r":[10,0,0]},{"t":1.6,"r":[0,0,0]}],
  "leftFoot":[{"t":0,"r":[0,0,0]},{"t":0.4,"r":[-15,0,0]},{"t":0.8,"r":[10,0,0]},{"t":1.2,"r":[5,0,0]},{"t":1.6,"r":[0,0,0]}],
  "rightUpperLeg":[{"t":0,"r":[15,0,0]},{"t":0.4,"r":[0,0,0]},{"t":0.8,"r":[-35,0,0]},{"t":1.2,"r":[0,0,0]},{"t":1.6,"r":[15,0,0]}],
  "rightLowerLeg":[{"t":0,"r":[10,0,0]},{"t":0.4,"r":[0,0,0]},{"t":0.8,"r":[55,0,0]},{"t":1.2,"r":[0,0,0]},{"t":1.6,"r":[10,0,0]}],
  "rightFoot":[{"t":0,"r":[5,0,0]},{"t":0.4,"r":[0,0,0]},{"t":0.8,"r":[-15,0,0]},{"t":1.2,"r":[10,0,0]},{"t":1.6,"r":[5,0,0]}]
 },
 "hips":[{"t":0,"p":[0,-0.02,0]},{"t":0.4,"p":[0,0,0]},{"t":0.8,"p":[0,-0.02,0]},{"t":1.2,"p":[0,0,0]},{"t":1.6,"p":[0,-0.02,0]}]}"""

const REFINE_INSTRUCTION := """以下は上記の指示で生成されたモーションJSONです。アニメーターとしてレビューし、
問題があれば修正した完全なJSONのみを返してください (問題がなければそのまま返す)。

チェック観点:
1. 可動域: 各関節がルールの範囲内か。腕が真上 (±90度) を超えていないか。
   手を振る系の動作で「解剖学メモ」の形 (上腕45〜60度 + 肘曲げ + 前腕の往復) になっているか。
2. 軌道: 腕や脚が体・頭と交差していないか。前腕が頭の上に被さっていないか
   (上腕60度以上 + 肘60度以上の組み合わせは禁止)。左右の取り違えがないか。
3. 自然さ: 立ち姿勢で肘が伸びきっていないか。逆に寝転び・倒れ姿勢で肘や膝が
   宙に突き出ていないか (床に沿っているか)。往復運動の端で減速しているか。予備動作と余韻があるか。
4. 完全性: 使うボーンに t=0 と t=duration のキーがあるか。非ループは最初と最後がニュートラルか。
5. 意図: そもそもユーザーの指示した動きになっているか。
6. 表現: 定型的・機械的すぎないか。実際の人間がやる動きとして違和感がないか。"""

const FLAVOR_AXES := [
	["エネルギッシュに", "しっとり落ち着いて", "コミカルに", "クールに", "照れくさそうに", "堂々と", "優雅に", "無邪気に"],
	["速いテンポで小気味よく", "ゆったり大きく動く", "緩急を強くつける", "一定のリズムで繰り返す"],
	["腕の動きを主役に", "腰と重心の移動を主役に", "頭と上半身の表情を主役に", "全身をまんべんなく使って", "脚のステップを主役に"],
	["左右非対称の振り付けで", "途中に一度タメ(静止)を入れて", "最後に決めポーズで締めて", "回転やターンを織り交ぜて", "上下動を強調して"],
]

var _http: HTTPRequest
var _base_url := DEFAULT_BASE_URL
var _api_key := ""
var _model := DEFAULT_MODEL
var _refine_enabled := true
var _user_text := ""
var _user_msg := ""
var _pass := 1
var _use_response_format := true
var _last_messages: Array = []
var _draft_spec: Dictionary = {}


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 120.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


## テキストからモーション spec の生成を開始する (非同期)。
## 結果は generation_succeeded / generation_failed シグナルで通知される。
func generate(text: String, base_url: String, api_key: String, model: String, refine_enabled: bool) -> void:
	_base_url = base_url.strip_edges().rstrip("/")
	if _base_url.is_empty():
		_base_url = DEFAULT_BASE_URL
	_api_key = api_key
	_model = model if not model.strip_edges().is_empty() else DEFAULT_MODEL
	_refine_enabled = refine_enabled
	_user_text = text
	_pass = 1
	_use_response_format = true
	_draft_spec = {}

	var flavor := _random_flavor()
	_user_msg = "次の動きのモーションを作成: %s\n(今回の演出の味付け: %s。ただしユーザーの指示と矛盾する場合は指示を優先)" % [text, flavor]

	generation_progress.emit("モーションを設計中...")
	_send([
		{"role": "system", "content": SYSTEM_PROMPT},
		{"role": "user", "content": _user_msg},
	])


func _send(messages: Array) -> void:
	_last_messages = messages
	var body := {
		"model": _model,
		"messages": messages,
	}
	if _use_response_format:
		body["response_format"] = {"type": "json_object"}
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % _api_key,
	])
	var err := _http.request(_base_url + "/chat/completions", headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_handle_failure("HTTPリクエストの送信に失敗しました (%s)" % error_string(err))


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_handle_failure("HTTP リクエストに失敗しました (result=%d)" % result)
		return

	var text := body.get_string_from_utf8()

	if response_code < 200 or response_code >= 300:
		# response_format 未対応の互換APIかもしれないので、一度だけ外して再試行する
		if _use_response_format and response_code == 400:
			_use_response_format = false
			_send(_last_messages)
			return
		var detail := text
		var err_json := JSON.new()
		if err_json.parse(text) == OK:
			var parsed = err_json.get_data()
			if parsed is Dictionary and parsed.get("error") is Dictionary:
				detail = str((parsed["error"] as Dictionary).get("message", text))
		_handle_failure("API エラー (HTTP %d): %s" % [response_code, detail])
		return

	var resp_json := JSON.new()
	if resp_json.parse(text) != OK:
		_handle_failure("API応答のJSON解析に失敗しました")
		return
	var data = resp_json.get_data()

	var content := ""
	if data is Dictionary:
		var choices = (data as Dictionary).get("choices")
		if choices is Array and not (choices as Array).is_empty():
			var first = choices[0]
			if first is Dictionary and (first as Dictionary).get("message") is Dictionary:
				content = str(((first as Dictionary)["message"] as Dictionary).get("content", ""))
	if content.is_empty():
		_handle_failure("API から有効な応答が得られませんでした")
		return

	var content_json := JSON.new()
	if content_json.parse(content) != OK:
		_handle_failure("生成されたJSONの解析に失敗しました")
		return
	var spec_raw = content_json.get_data()
	if not (spec_raw is Dictionary):
		_handle_failure("生成されたモーションの形式が不正です")
		return

	var validated := MotionSpecParser.validate(spec_raw as Dictionary)
	if validated.has("error"):
		_handle_failure(str(validated["error"]))
		return

	if _pass == 1:
		_draft_spec = validated
		if _refine_enabled:
			_pass = 2
			generation_progress.emit("自己修正中 (2パス目)...")
			_send([
				{"role": "system", "content": SYSTEM_PROMPT},
				{"role": "user", "content": _user_msg},
				{"role": "assistant", "content": JSON.stringify(validated)},
				{"role": "user", "content": REFINE_INSTRUCTION},
			])
		else:
			_finalize(validated)
	else:
		_finalize(validated)


func _handle_failure(message: String) -> void:
	if _pass == 1 or _draft_spec.is_empty():
		generation_failed.emit(message)
	else:
		push_warning("自己修正パスに失敗したため1パス目の結果を使用します: %s" % message)
		_finalize(_draft_spec)


func _finalize(spec: Dictionary) -> void:
	if not bool(spec.get("loop", false)):
		MotionSpecParser.append_neutral_ending(spec)
	if not (spec.get("hips") is Array) or (spec["hips"] as Array).is_empty():
		spec.erase("hips")
	if MotionSpecParser.is_wave_text(_user_text):
		MotionSpecParser.apply_wave_correction(spec)
	generation_succeeded.emit(spec)


# 毎回ランダムに混ぜる「演出の味付け」— 同じ指示でも違う振り付けを引き出す
func _random_flavor() -> String:
	var axes: Array = FLAVOR_AXES.duplicate(true)
	axes.shuffle()
	var count: int = 2 + (randi() % 2)
	var picks := []
	for i in range(mini(count, axes.size())):
		var axis: Array = axes[i]
		picks.append(axis[randi() % axis.size()])
	return "、".join(picks)
