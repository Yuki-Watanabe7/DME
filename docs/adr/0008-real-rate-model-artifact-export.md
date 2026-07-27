# ADR 0008: Real-rate model artifact 統合契約（DME 側実装方針）

- **ステータス**: 採用
- **日付**: 2026-07-27
- **関連Issue**: [Yuki-Watanabe7/DME#159](https://github.com/Yuki-Watanabe7/DME/issues/159)
- **前提ADR**: [economic-data-provider ADR 006](../contract/README.md)（DME model artifact と
  provider 観測系列の責務境界・比較 contract。cross-repository で確定済み、DME からは変更不可）
- **関連ドキュメント**: [New Keynesian モデル](../models/new_keynesian.md)・
  [real-rate model artifact 生成デモ](../examples/real_rate_model_artifact.md)・
  [モデル能力・概念定義 metadata](../model_capabilities.md)

## コンテキスト

DME の New Keynesian（NK）3方程式モデルは産出ギャップ `x`・インフレ率 `π`・名目政策金利 `i` を
出力するが、`π` は現在のインフレ（current inflation）または IRF deviation であり、期待インフレ率
`E_t[π_{t+1}]` やインフレ目標 `π_star` とは別概念として区別されていなかった。また
`i_t - E_t[π_{t+1}]`（model-implied ex-ante 実質政策金利）を明示的に出力する API も存在しなかった。

economic-data-provider ADR 006 は、DME モデル値と market/survey/proxy 系列を安全に比較するための
cross-repository contract（JSON Schema・identity/hash 規則・比較可能性判定・artifact lifecycle）を
確定した。本 ADR は、その契約を DME 側でどう満たすかという実装方針を記録する。契約そのもの
（schema の field・semantics）は economic-data-provider 側が所有し、DME からは変更しない。

## 決定

1. 新規モジュール `src/artifacts/` に3ファイルを追加する: `json_canonical.jl`（RFC 8785 の限定
   実装）・`real_rate_model_artifact.jl`（契約の型・バリデーション・hash 計算）・
   `real_rate_model_artifact_export.jl`（`NewKeynesianModel` からの adapter・atomic save/load）。
2. `artifact_id`・`parameter_hash`・`calibration_hash`・`snapshot_hash` は各型が自前で計算し、
   コンストラクタは引数として受け取らない（自己参照を構造的に排除する）。
3. RFC 8785 正準化は DME の値域に限定した独自実装とする（汎用 JCS 実装は導入しない）。
4. タイムゾーンは MVP で UTC 固定とする（`TimeZones.jl` は導入しない）。
5. `rate_basis` は全 observation で `"annualized"` に統一する。
6. P1Y の期待インフレ・model-implied 実質政策金利は4四半期の年率換算値の
   `arithmetic_mean` を採用する（`compounded_path` は採用しない）。
7. `E_t[π_{t+h}]` は MSV 解の閉形式から導出する（IRF 配列の未来値コピーではない）。
8. horizon は `P3M`・`P1Y` のみサポートする。5Y/10Y term structure は生成しない。
9. artifact ファイルは常に正準 JSON バイト列で保存し、atomic rename で確定する。

## 1. 正準化(JCS)の実装範囲

RFC 8785 は任意の JSON 文書を対象とするが、DME の artifact ドメイン値は
`Dict{<:AbstractString,<:Any}`（キーは ASCII のみ）・`AbstractVector`・`AbstractString`・
`Bool`・`Integer`・有限 `AbstractFloat`・`Nothing` の入れ子に限定される。そこで
`src/artifacts/json_canonical.jl` はこの値域だけを対象にした限定実装とし、汎用 JSON
canonicalizer は導入しない。

- オブジェクトキーのソートは Unicode コードポイント順で行う。DME 側が生成するキーは
  ASCII のみという前提を `_jcs_check_key_ascii` で強制するため、これは RFC 8785 が要求する
  UTF-16 コードユニット順ソートと一致する。
- 数値は ECMAScript `Number::toString`（`JSON.stringify` が使う表現）と同じ書式で出力する。
  Julia の `string(::Float64)` が返す最短往復表現（有効数字列と exponent）を解析し、
  ECMAScript の固定表記/科学的記法の閾値規則で独自に再フォーマットする。Julia 自身の
  `string()` がどちらの記法を選んだかには依存しない。実装時に、ランダムな浮動小数点数
  513件（指数 -12〜12 の範囲、境界値含む）で Node.js の `JSON.stringify` の出力と
  バイト単位で完全一致することを手動検証した（`test/test_json_canonical.jl` に境界値の
  固定回帰テストとして反映）。指数が概ね ±16 を超える極端な値は artifact のドメイン
  （percent 表示のレート・パラメータ）では実質的に発生しないため、そこまでの網羅的検証は
  行っていない。
- 文字列は RFC 8259 の最小エスケープ（`"` `\` 制御文字のみ）で UTF-8 のまま出力する。
- 配列の順序は正準化しない（JCS はオブジェクトキーのみソート対象）。`observations` 等の
  安定順序化（`observation_id` 昇順）は `RealRateModelArtifact` コンストラクタの責務とする
  （`sfc/types.jl` の「型側で安定 id 昇順に正準化する」規約を踏襲）。

保存・`to_json`・hash 計算はすべて `canonical_json_bytes` を単一の経路として使う
（`JSON3.write` は使わない）。`JSON3` は `real_rate_model_artifact_from_json` の読み込み
専用とし、JSON3.Object/Array を `Dict{String,Any}`/`Vector{Any}` へ変換してから
`real_rate_model_artifact_from_dict` に渡す。既存 `sfc/serialization.jl` の
`to_json(x) = JSON3.write(to_dict(x))` という慣行からの意図的な逸脱であり、理由は
cross-repository の hash identity 契約（同じ内容は同じ `artifact_id`）を満たすため。
`JSON3.write(::Dict)` のキー順序は保証されないため、この用途には使えない。

## 2. Identity・hash の自己参照排除

`artifact_id` は「`artifact_id` 自身と `timing.generated_at` を除く文書全体を正準化した
SHA-256」（ADR 006 §4.1）。この非対称な除外ロジックを手続き的に「後から特定キーを消す」
実装にすると、フィールド追加時に消し忘れるリスクが残る。そこで:

- `RealRateModelArtifact` のキーワードコンストラクタは `artifact_id` を引数に取らない。
  他フィールドから `to_dict` 相当の Dict を組み立て、`compute_artifact_id` に渡して
  `artifact_id` を内部確定してから構造体を作る。
- `ParameterSet`・`Calibration`・`InputSnapshot` も同様に、それぞれの hash フィールド
  （`parameter_hash`・`calibration_hash`・`snapshot_hash`）を引数に取らず、他フィールドから
  内部計算する。
- `generated_at` だけを除外する非対称ロジックは `compute_artifact_id` 内の1箇所に集約する。

`real_rate_model_artifact_from_dict`（JSON からの復元）は、読み込んだ hash 系フィールドを
信用せず、同じ構築ロジックで再計算した値と突き合わせる。不一致は `ArgumentError`
（改ざん・破損として拒否）とする。これにより round-trip テストが「読み込んだhashをそのまま
信じて通す」ではなく「再計算しても同じhashになる」という強い保証になる。

## 3. タイムゾーン: MVP は UTC 固定

`decision_time`・`data_cutoff_at`・`generated_at` はオフセット付き RFC 3339 を要求されるが、
Julia 標準の `Dates.DateTime` は naive（タイムゾーン情報を持たない）で、DME の依存にも
`TimeZones.jl`（IANA tzdata を同梱する重い依存）は含まれていない。

MVP では全 timing フィールドを UTC 固定とし、`"...Z"` 接尾辞で出力・読み込みする
（`_rra_format_datetime`/`_rra_parse_datetime`）。`run.calendar_timezone` は
`US → America/New_York`・`JP → Asia/Tokyo` の固定 allowlist から求める表示用メタデータ
であり、実際のタイムゾーン変換（DST 等）には使わない。`decision_time` 等は呼び出し側が
明示的に渡す必須引数であり、UTC への変換責務は呼び出し側にある。

## 4. `rate_basis` の統一と P1Y 集約方式

`NewKeynesianModel` の `π_star`・`r_n`（典型値 0.02）は、既存 docs・実装のどこにも
四半期→年率の変換式（×4 や複利換算）が記述されておらず、標準的な教科書慣行どおり
「年率」を表す値として扱われていると解釈できる。一方モデルの1期は四半期
（`model_capabilities.jl` の `time_unit="quarterly"`）である。

比較対象となる実世界の政策金利・インフレ目標は通常「年率」で提示されるため、
`nominal_policy_rate` を provider の観測系列と比較可能にするには `rate_basis="annualized"`
が事実上必須になる。そこで本実装は以下を採用する。

- 単一期間の metric（`current_inflation`・`inflation_target`・`nominal_policy_rate`・
  `natural_real_rate`）は、モデルの生の値（既に年率と解釈）を `100` 倍して percent に
  変換するだけで `rate_basis="annualized"` とする。
- `expected_inflation`/`model_implied_real_policy_rate` の P3M horizon
  （`aggregation="one_step_ahead"`）は、次の1四半期先の年率換算値をそのまま使う。
- P1Y horizon（`aggregation="arithmetic_mean"`）は、4四半期先までの年率換算値の**単純平均**
  を使う。ADR 006 の contract example
  (`docs/contract/examples/dme-real-rate-model-artifact.json`) は `aggregation="compounded_path"`
  で4四半期分を複利計算しているが、これは「年率で表現済みの値」をさらに複利計算することに
  なり二重計上になる（例: `π_star=2%` が4四半期複利で約8.24%相当まで膨れ上がる）。この
  example 自体が `warnings` に `illustrative_contract_example_not_empirical_calibration` と
  `expected_inflation_p1y_requires_dme_api_extension` を含む非計算のプレースホルダである
  ことを踏まえ、本実装では採用しない。

この解釈は DME 側の設計判断であり、schema が強制するものではない。artifact の
`warnings` に `pi_star_r_n_interpreted_as_annualized_rate_levels` と
`p1y_expected_inflation_uses_arithmetic_mean_not_compounded_path`（P1Y horizon 使用時のみ）
を機械可読タグとして必ず含める。

## 5. `E_t[π_{t+h}]` の閉形式導出

NK モデルの決定論的 AR(1) ショック `ε_t = shock_size * ρ^(t-1)` のもとでは、将来の確率的な
新規ショックが到来しないため、t 期時点で形成される期待は実現パスと数学的に厳密に一致する
（`test/test_new_keynesian.jl` の構造方程式 self-consistency テストで証明済みの事実）:

```
E_t[π̃_{t+h}] = Ψ_π * ε_{t+h} = Ψ_π * shock_size * ρ^(t+h-1)
```

`nk_expected_inflation_path`（`src/models/new_keynesian.jl`）はこの式を `h` について直接
評価する。`impulse_response` が返す配列の `t+h` 番目を読み出す実装にはしていない
（数学的には同値だが、ADR 006 §3.3 が明示的に禁じる「`π_t` や `π_star` の単純コピー」との
混同を避け、モデル方程式から独立に導出していることをコードでも明示するため）。
`impulse_response` 内の ρ/d 選択ロジックは `_nk_shock_spec` として切り出し、両関数で共有する。

`π`/`i` の level 復元も同じ理由で明示的なヘルパー関数（`nk_inflation_level`・
`nk_nominal_rate_level`）として実装し、呼び出し側で `π_star + deviation` を都度書かない
（level と deviation を取り違えないための型・API レベルの防止策）。

## 6. horizon: `P3M`・`P1Y` のみサポート

`Horizon` 型は `RRA_HORIZON_SPECS`（`"P3M" => model_periods=1, aggregation=:one_step_ahead`、
`"P1Y" => model_periods=4, aggregation=:arithmetic_mean`）という固定テーブルでのみ構築でき、
このテーブル外の `duration` は `ArgumentError` で拒否する。`model_periods`/`aggregation` を
明示的に渡した場合もテーブルと不一致なら拒否する。5Y/10Y term structure を要求する経路は
そもそも存在しない。ISO 8601 duration の汎用パーサは実装していない（MVP が2値しか扱わない
ため、固定テーブルの方が事故が少ないという判断）。

## 7. Artifact lifecycle

`save_real_rate_model_artifact` は ADR 006 §6 のファイル名規約
（`artifacts/real-rates/<schema_version>/<country>/<YYYY>/<MM>/<timestamp>__<country>__<model-id>__<run-id>__<64hex>.json`）
に従い、`.tmp` へ書いて `fsync`（`ccall(:fsync, ...)`。CI は ubuntu-latest のみのため
Unix 限定で問題ない）した後 `mv`（atomic rename）で確定する。同名ファイルへは上書きしない
（`isfile` チェックで `ArgumentError`）。書き込む内容は常に正準 JSON バイト列（§1）。
`code_commit_sha` は builder の必須引数とし、自動検出（`git rev-parse HEAD` の40桁フル hex）
は `_detect_git_commit_sha()` として分離する（`.git` が存在しない配布環境での暗黙失敗を
避けるため、builder 自身はこれを呼ばない）。

## 8. Schema vendoring

`docs/contract/` に economic-data-provider の schema・example artifact を vendor コピーする
（`docs/contract/README.md` に同期元コミットを明記）。DME はこの schema に対する汎用 JSON
Schema バリデータを導入しない。契約が要求する制約（必須 metric・enum・相関条件・hash 一致・
timestamp 順序等）は `real_rate_model_artifact.jl` の Julia 側バリデーションロジックとして
個別に再実装し、構造を schema と一致させる。

## 理由

- 自己参照を構造的に排除する設計（§2）は「計算し忘れる」「除外し忘れる」というヒューマン
  エラーのクラスをコンパイル時ではなく構築時に強制的に防ぐ。テストで「同一入力→同一
  `artifact_id`」を検証しやすくなる副次効果もある。
- P1Y の集約方式（§4）は、ADR 006 の contract example をそのまま数値的に再現するより、
  DME 自身のモデル慣行（年率表現）との整合性を優先した。数値の妥当性は
  `model_implied_real_policy_rate = nominal - expected` の算術検証（許容誤差 1e-9）で
  構築時に自己検証している。
- タイムゾーン・horizon をあえて狭く実装する（§3, §6）ことで、MVP の決定論的 golden
  artifact 生成という最優先要件を満たしつつ、複雑なロジック（DST・任意 horizon 変換）が
  バグの温床になることを避けた。

## 見送りとした選択肢

- **TimeZones.jl の導入**: IANA tzdata を同梱する重い依存であり、MVP の UTC 固定要件には
  過剰。将来、非 UTC の `decision_time` を扱う要求が出た時点で再検討する。
- **`compounded_path` による P1Y 集約**: contract example と数値が一致するが、DME の
  「年率表現済み」という前提と矛盾し二重計上になるため不採用（§4）。
- **汎用 JSON Schema バリデータの導入**: `docs/contract/` の schema を実行時に検証できる
  利点はあるが、新規依存とメンテナンスコストに見合わないと判断した。Julia 側の型・
  バリデーションロジックで同等の制約を再実装している。
- **`parameter_set_id`/`calibration_id` 等からの自動 UUID 生成**: 決定論性を損なうため、
  呼び出し側が明示的に ID を指定する設計とした。

## 影響

- 5Y/10Y term structure を要求する呼び出しは builder レベルで即座に拒否され、将来
  economic-data-provider 側が P3M reference を持つか、DME が明示的な P1Y 拡張を追加する
  までは `comparable=false` として扱われる（ADR 006 §9 と同じ制約を引き継ぐ）。
- `rate_basis` の解釈（§4）は DME 独自の設計判断であり、economic-data-provider 側の
  provider reference（`nominal_rate`/`expected_inflation` component）の年率解釈と実際に
  整合するかは #94/#95 側の semantic validation で最終確認される。
- タイムゾーンを UTC 固定にしたことで、非 UTC 圏の `decision_time` を厳密に表現する
  ユースケースは MVP の対象外になる。

## 参考

- [economic-data-provider ADR 006](../contract/README.md)
- [ADR 0006: クロスモデル推論契約](0006-cross-model-reasoning-contract.md)（同名変数の
  非同一視・比較不能の非統合という先行方針）
- [ADR 0007: SFC 統合契約](0007-sfc-integration-contract.md)（別結果型 + adapter という
  統合 idiom の先例）
