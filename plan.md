# text-to-vrma Godot 移植計画

元コード: `/home/local-admin/text-to-vrma/src/`（Node.js + Three.js）
必要なら自分で読んで詳細を確認すること。

---

## 目的

JS 版 text-to-vrma を Godot Engine に移植する。
テキストからモーション生成 → VRM アバターに即座に再生。

## 方針

- **VRMA は使わない**。Godot ネイティブの `AnimationPlayer` + `Animation` リソースに直接キーフレームを書き込む。
- **ARDY 移植しない**。API Key モード（OpenAI 互換 API）のみ対応。
- **VRM 読み込み**: godot-vrm アドオン（AzPepoze fork）を使用。Bone Rename: `Humanoid`、`SkeletonProfileHumanoid` 準拠。
- **API 連携**: Godot 組み込み `HTTPRequest` で LLM API に直接リクエスト。Base URL / API Key / Model 名は自由に設定可能にする。
- **自己修正**: 2パス生成（1パス目生成 → 2パス目レビュー・修正）を再現。`refine` フラグで ON/OFF。

## ファイル構成（参考）

```
res://
├── project.godot
├── main.tscn
├── main.gd
├── scenes/
│   └── vrm_preview.tscn
├── scripts/
│   ├── llm_client.gd          # HTTPRequest で LLM API 通信
│   ├── motion_spec_parser.gd  # JSON → Animation 変換 + 検証・クランプ
│   ├── animation_builder.gd   # Animation リソース構築
│   ├── vrm_loader.gd          # VRM 読み込み・Skeleton 参照
│   ├── idle_motion.gd         # 待機モーション
│   └── expression_controller.gd # 表情制御
├── ui/
│   ├── settings_panel.tscn
│   └── history_panel.tscn
└── addons/vrm/                # godot-vrm (別途インストール)
```

構成は必要に応じて変えてよい。

---

## 元コードの読みどころ

| ファイル | 何を参考にするか |
|---------|----------------|
| `llm.js` | API 呼び出し、プロンプト内容（`SYSTEM_PROMPT`、`REFINE_INSTRUCTION`）、`validateSpec()` の検証・角度クランプロジック、`applyWaveCorrection()`、ランダム味付け (`FLAVOR_AXES`) |
| `vrmaBuilder.js` | ボーン一覧（`BONE_NAMES`、`SKELETON`）、表情プリセット（`EXPRESSION_PRESETS`）、 hips 移動処理 |
| `main.js` | UI 構成、履歴管理、ループ判定 (`isLoopFriendly`)、ファイル入出力、生成ボタン周りのフロー |
| `viewer.js` | Three.js シーン構成の参考（カメラ位置、ライト、GridHelper 相当） |

## 実装タスク

### Phase 1（まず動かす）
1. Godot プロジェクト作成。godot-vrm アドオン有効化
2. VRM モデルを読み込み、Bone Rename `Humanoid` + Skeleton Name `GeneralSkeleton` でインポート確認
3. `llm_client.gd` 実装。Base URL / API Key / Model を自由入力。`POST /chat/completions` で JSON 取得。streaming 対応（`stream: true` で SSE パース、`choices[0].delta.content` を結合）
4. `motion_spec_parser.gd` 実装。LLM の JSON レスポンスをパース。`validateSpec` 相当の検証（不明ボーン除去、角度クランプ、膝逆関節防止、肘過伸展ガード）を実装。参考: `llm.js` の `validateSpec()`
5. `animation_builder.gd` 実装。`Animation.new()` → `add_track(TYPE_ROTATION_3D)` → `track_insert_key(time, quaternion)`。ボーン名を VRM 規約 → Godot `SkeletonProfileHumanoid` に変換 (`leftUpperArm` → `LeftUpperArm`)。hips 移動は `TYPE_POSITION_3D`
6. `main.gd` で結線。テキスト入力 → 生成 → AnimationPlayer 再生までの流れを作る
7. 3D プレビュー。`SubViewport` + `Camera3D` + `DirectionalLight3D` + 床メッシュ

### Phase 2（品質向上）
8. 待機モーション。`idleMotion.js` 相当の呼吸アニメを作成し、デフォルトでループ再生
9. 自己修正（2パス目）。1パス目の JSON を `REFINE_INSTRUCTION` と共に再送信。失敗しても 1パス目で fallback
10. 表情制御。`expressions` を `expression_controller.gd` で処理。godot-vrm の expression 機構を使う
11. ループ / 非ループ制御。`Animation.loop_mode`。非ループ時は末尾にニュートラルポーズ自動挿入（`appendNeutralEnding` 相当）
12. 手振り矯正。`applyWaveCorrection()` 相当。上腕上げ角度 52度制限、肘曲げ補正、手首ひねり自動適用

### Phase 3（その他）
13. 履歴管理。生成した spec / Animation を保持し、再再生可能に
14. VRM 差し替え。`FileDialog` でモデル変更。Humanoid BoneMap 前提で同じ Animation が再生できることを確認
15. 多言語対応（Godot Localization）
16. Animation 保存・読み込み（`.tres` / `.res`）
17. デスクトップエクスポート

---

## ⚠️ 重要な注意点・落とし穴

### 座標系・回転変換
VRM 1.0 はオイラー角 XYZ 順（度）。Godot の `Quaternion.from_euler()` は **YXZ 順として解釈される**。正確な変換は:

```gdscript
var basis := Basis.from_euler(Vector3(deg_to_rad(x), deg_to_rad(y), deg_to_rad(z)), EULER_ORDER_XYZ)
var quat := basis.get_rotation_quaternion()
```

で行うこと。これを間違えると全モーションが崩れる。

### Godot Humanoid ボーン名
VRM 規約名はローワーキャメル（`leftUpperArm`）。Godot はパスカル + 左右前置き（`LeftUpperArm`）。マッピングは単純な名前変換で対応可能。ただし `Skeleton3D` の `find_bone()` で確認するのが確実。

### hips（腰）移動の扱い
VRM では `hips` ボーンの `translation` をアニメートする。Godot では `Hips` ボーンの position を `TYPE_POSITION_3D` トラックで動かせばよい。但し、キャラクター全体をワールド座標で動かしたい場合は、VRM モデルのルート `Node3D` の `position` を別途アニメートする必要がある。

### フリー入力の API Key セキュリティ
API Key は `localStorage` 相当（Godot では `ConfigFile` または `ProjectSettings`）に保存するが、値自体は平文。最低限 `LineEdit.secret` を使う。デスクトップ版なら Keychain 連携も検討できるが、初版では `secret` モードで十分。

### ストリーミング対応
`HTTPRequest` は chunked transfer で SSE を受信できる。`body_chunk_received` シグナルを使い、`data: {...}` 行をパースして `choices[0].delta.content` を結合する。参考: `llm.js` の `callOpenAI()` streaming ブロック。

### `response_format: { type: "json_object" }`
OpenAI 公式の機能。互換 API（Sakura API 等）で未対応の場合がある。その場合は system prompt に `"Respond ONLY with valid JSON, no markdown, no explanation."` を追加してフォールバックする。

### 膝・肘のガード（再掲）
- 膝（lowerLeg）: X は 0〜130 のみ。負値（逆関節）は絶対禁止
- 肘（lowerArm）: X ひねり（コーン回転）を防ぐ。Y 前方曲げのみ許可
- 上腕 60度以上 + 肘 60度以上の組み合わせを禁止（前腕が頭に被さる）

詳細な閾値・ロジックは `llm.js` の `validateSpec()` を直接読むこと。

---

## 参考リンク

- `/home/local-admin/text-to-vrma/src/` — 元コード。不明な点はここを読む
- [godot-vrm AzPepoze fork](https://github.com/AzPepoze/godot-vrm) — Godot VRM アドオン
- [Godot Animation クラスリファレンス](https://docs.godotengine.org/en/stable/classes/class_animation.html)

---

## Rust (GDExtension) 高速化方針

### 前提

ボトルネックになるのは **「モーション spec → キーフレーム配列の変換」**（回転変換 + 検証・クランプ + 手振り矯正）。ボーン数 × キー数のループで、GDScript だと数値計算が重い。UI・シーン操作・HTTP通信は GDScript のままでよい。

### Rust 化するもの

| モジュール | 担当 | 理由 |
|-----------|------|------|
| `motion_spec_parser` | **Rust** | `validateSpec` + 角度クランプ + 膝・肘ガード + 手振り矯正。条件分岐・数学演算が多い。JSON パース自体は GDScript でやり、検証対象の辞書を Rust に渡す |
| `animation_builder` | **Rust (コア部分)** | Quaternion 変換（XYZ Euler → Quaternion）の大量計算。Rust 側で「bone_name, time, quaternion_xyzw」の配列を作り、GDScript が `Animation` リソースに流し込む |
| `idle_motion` | Rust or GDScript | 呼吸モーションは固定アルゴリズムでキー数も少ない。Rust にしてもいいが必須ではない |

### GDScript のままにするもの

| モジュール | 理由 |
|-----------|------|
| `llm_client` | `HTTPRequest` は Godot 組み込み。Rust 化の意味が薄い |
| `vrm_loader` | Godot のシーン・ノード操作は GDScript の方が圧倒的に楽 |
| `expression_controller` | そこまで計算量がない |
| UI 全般 (`main.gd`, settings_panel, history_panel) | 当然 GDScript |

### FFI 境界（GDScript ↔ Rust）

Rust 側は純粋なデータ変換だけやり、Godot のリソース操作は触らない。

```gdscript
# GDScript 側
var spec = JSON.parse_string(json_text)  # パースは GDScript
var validated := MotionSpecParserRs.validate(spec)  # Rust で検証・クランプ
var keyframes := AnimationBuilderRs.build(validated)  # Rust で Quaternion 変換
# keyframes = [{ "bone": "LeftUpperArm", "time": 0.0, "quat": Quat }, ...]

for k in keyframes:
    var track = anim.find_track(NodePath("Skeleton3D:" + k.bone), Animation.TYPE_ROTATION_3D)
    anim.track_insert_key(track, k.time, k.quat)
```

Rust 側の Cargo プロジェクトは `res://addons/text_to_vrma_rs/` に置く。`godot-rust` (gdextension) を使用。

### 開発順序

1. まず **全て GDScript** で動かす（Phase 1 完了まで）
2. 複雑なモーション（15秒・全身動作）で生成＋再生の時間を計測し、ボトルネックを特定
3. ボトルネックが `motion_spec_parser` / `animation_builder` ならそこだけ Rust 化
4. Rust 化は **後から差し替え可能** な設計にする（インターフェースを共通化しておく）