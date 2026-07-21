# ADR 0005: Keen 実証説明は根拠階層・主張単位の参照・安全な構造化出力を必須とする

- **ステータス**: 採用
- **日付**: 2026-07-21
- **関連Issue**: #99（ロードマップ）・#129（本決定）・#130（`AnalysisContext` 拡張）・#131（説明 API / prompt）
- **前提ADR**: [ADR 0002](0002-minsky-integration-design.md)（LLM 層の分離）・[ADR 0003](0003-minsky-financing-regime-diagnostics.md)（診断 proxy の責務境界）・[ADR 0004](0004-keen-empirical-calibration-strategy.md)（測定・識別・検証）
- **関連ドキュメント**: [Keen モデル実証化戦略](../models/keen_empirical_strategy.md)・[LLM 出力の安全性ルール](../llm_safety.md)・[AnalysisContext 設計](../architecture/analysis_context.md)

## コンテキスト

Keen 実証層（観測系列変換・限定キャリブレーション・literature / calibrated モデルの
in-sample / out-of-sample 検証・observed proxy / model の regime 診断・感応度分析）を実装した。
統合レポート `keen_empirical_report` はこれらを機械可読に保持するが、値の認識論的な性質は同じではない。

- 公表系列の値は観測データだが、`ω`・`λ`・`d` への対応には測定・変換上の仮定がある。
- calibrated parameter は特定の標本・proxy・bounds・objective に依存する推定値である。
- literature / calibrated trajectory はモデル出力であり、観測された将来ではない。
- observed proxy regime は集計 proxy への診断であり、モデル内部の内生 regime や企業別の実測分類ではない。
- 感応度分析が示せるのは実際に変更した仮定の範囲内だけである。

これらを平坦な JSON や自然言語へ潰すと、LLM が異なる根拠を一つの「事実」として混ぜたり、fit を
因果妥当性・予測保証へ昇格させたりする危険がある。本 ADR は、後続 Issue が追加の設計判断なしに
型、adapter、prompt、parser、fixture test を実装できる説明契約を確定する。

## 決定

1. **Keen 実証コンテキストを 7 つの根拠カテゴリへ分離する。** `observed_data`、`measurement`、
   `calibration`、`model_output`、`diagnostic_proxy`、`sensitivity`、`limitations` を固定語彙とする。
2. **すべての主要主張を source ID へ結び付ける。** source registry と JSON Pointer により、数値・期間・
   系列・methodology・warning の出所を追跡可能にする。未登録 ID や context に存在しない根拠は許可しない。
3. **表示上の認識状態を固定する。** `observed`、`measured`、`estimated`、`simulated`、`diagnostic`、
   `sensitivity`、`limitation` を明示し、異なる状態を一文の中で無表示に混合しない。
4. **専用出力は必須セクションを省略しない。** 情報がない場合も `not_available` または
   `insufficient_evidence` を返し、一般知識や推測で穴埋めしない。
5. **warning severity が説明可否を決める。** warning を単なる末尾注記にせず、該当セクションの status、
   許可される主張、provider 呼び出し可否へ反映する。
6. **schema / parser failure は決定的 fallback へ落とす。** 不正な provider 応答を自由文として表示せず、
   検証済み context だけから必須セクションを持つ安全な出力を返す。
7. **DME 共通契約と provider adapter を分離する。** 根拠分類、prompt、schema、検証、fallback は DME の
   責務とし、provider は完成済み prompt の送信と raw response の受領だけを担う。

## 1. 根拠階層

### 1.1 固定カテゴリ

| category | 内容 | 実証層の主な入力 | 許可される主張 |
|---|---|---|---|
| `observed_data` | 実データ値、系列 ID、provider、取得 mode、対象期間 | `dataset.dates`、`ω/λ/d/r`、`provenance`、`quality_flags` | 「系列にこの値・変化が記録されている」 |
| `measurement` | 観測方程式、単位・頻度変換、proxy 定義、欠損処理 | `report.methodology.measurement`、`conversion_formula`、`aggregation` | 「この規則でモデル単位へ変換した」 |
| `calibration` | 推定対象・固定値・bounds・initial guess・objective・収束・識別診断 | `validation.calibration` | 「この設定でこの推定値・objective が得られた」 |
| `model_output` | literature / calibrated、期間区分、初期値方式、予測 trajectory と fit | `result.trajectories`、`evaluations` | 「このモデル設定の出力はこの metric / 経路を示した」 |
| `diagnostic_proxy` | financing regime、coverage、margin、transition、divergence | `validation.regime_comparison` | 「この操作的診断ではこの区分・指標となった」 |
| `sensitivity` | 変更した仮定、base との差、結論の安定性 | `validation.sensitivity` | 「検証済みシナリオ範囲では結論が安定／不安定だった」 |
| `limitations` | モデル、データ、測定、識別、診断上の制約と warning | `validation.warnings`、`caveats` | 他カテゴリの解釈範囲を制限する |

`measurement` は `observed_data` の修飾情報であり、変換後の `ω`・`λ`・`d` を未加工の公表値として
表示してはならない。`diagnostic_proxy` は観測値そのものでもモデル状態そのものでもないため、独立カテゴリとする。

### 1.2 優先順位と衝突規則

優先順位は「真実らしさの単一ランキング」ではなく、相反する記述があるときの**説明制約**である。

1. `limitations` の blocking/error warning は、他カテゴリの肯定的解釈を停止する。
2. 現実に何が観測されたかという主張では、`observed_data` を優先し、`measurement` を必ず併記する。
3. 推定値については `calibration` だけを根拠とし、観測事実や普遍的な構造値へ昇格させない。
4. trajectory や fit については `model_output` だけを根拠とし、観測事実・因果効果・予測保証へ昇格させない。
5. regime については `diagnostic_proxy` だけを根拠とし、observed proxy と model diagnosis を別 claim にする。
6. 頑健性については `sensitivity` を必要条件とし、実際に検証した scenario の包絡外へ外挿しない。

たとえば observed proxy と calibrated model の regime が一致しない場合、observed proxy を model output で
上書きしない。「両者は不一致」という比較事実を示し、原因は `insufficient_evidence` とする。

### 1.3 表示ラベル

各 claim は次の `epistemic_status` を 1 つ持つ。UI / Markdown では対応する日本語ラベルを省略しない。

| `epistemic_status` | 表示例 | 対応 category |
|---|---|---|
| `observed` | `[観測]` | `observed_data` |
| `measured` | `[測定・変換]` | `measurement` |
| `estimated` | `[推定]` | `calibration` |
| `simulated` | `[モデル出力]` | `model_output` |
| `diagnostic` | `[診断proxy]` | `diagnostic_proxy` |
| `sensitivity` | `[感応度]` | `sensitivity` |
| `limitation` | `[限界]` | `limitations` |

一つの claim が複数カテゴリに依存する場合も主たる status は 1 つとし、`source_ids` は複数指定できる。
異なる status の結論を接続する場合は claim を分ける。

## 2. source reference 契約

### 2.1 `EvidenceSource`

source registry の各要素は次の JSON 化可能なフィールドを持つ。

| field | type | 必須 | 内容 |
|---|---|---:|---|
| `id` | `String` | yes | context 内で一意な安定 ID。`^[a-z][a-z0-9_.-]*$` |
| `category` | `Symbol` | yes | §1.1 の固定カテゴリ |
| `context_path` | `String` | yes | context root からの RFC 6901 JSON Pointer |
| `label` | `String` | yes | 人間向けの短い名称 |
| `provider` | `Union{String,Nothing}` | conditional | 実データの場合の provider / source |
| `series_id` | `Union{String,Nothing}` | conditional | 系列を主張する場合の ID |
| `period_start` / `period_end` | `Union{String,Nothing}` | conditional | 期間を主張する場合 |
| `unit` | `Union{String,Nothing}` | conditional | 数値を主張する場合。無次元比率も明記 |
| `method_id` | `Union{String,Nothing}` | conditional | measurement / calibration / validation / diagnostic version |
| `artifact_path` | `Union{String,Nothing}` | no | 再現 artifact。秘密情報を含めない相対パス |

`id` の例は `obs.omega.fred.prs85006173`、`calibration.base`、
`validation.calibrated.oos.observed-start.omega`、`regime.observed-proxy` である。
`context_path` の例は `/dataset/series/ω`、`/validation/calibration`、
`/validation/evaluations/3/metrics/ω` である。配列 index が artifact ごとに変わり得るため、出力 claim は
JSON Pointer ではなく安定 `id` を参照する。

### 2.2 claim の引用規則

- `EvidenceClaim.source_ids` は 1 件以上必須とする。
- 数値、期間、系列、収束、fit、regime、感応度、再現設定を述べる claim は、該当値を直接指す ID を含める。
- source ID は input registry に存在し、category と `epistemic_status` の対応が §1.3 と整合しなければならない。
- 複合主張は必要な source ID をすべて列挙する。参照で支えられない部分は別 claim に分離して
  `insufficient_evidence` とする。
- 文献・データ・モデル特性を LLM の一般知識から追加しない。context に登録された repository metadata
  だけを使う。

## 3. `AnalysisContext` 拡張契約（Issue #130）

### 3.1 後方互換な追加点

既存 `AnalysisContext` に次の optional field を追加する方式を採る。

```julia
keen_empirical::Union{KeenEmpiricalContext, Nothing} = nothing
```

既存 constructor、`explain_result`、`explain_data_comparison`、既存 output 型の意味を変更しない。
`to_dict` / `to_json` / `to_compact_dict` は `keen_empirical !== nothing` の場合だけ同名 key を追加する。
Keen 専用 API は `keen_empirical === nothing` の場合、既存の実データ比較 API と同様に `ArgumentError`
を返す。`KeenEmpiricalContext` 自体は存在するが一部の分析が未実施・欠損の場合は、該当 section を
`not_available` / `insufficient_evidence` とし、simulation-only context も表現できるようにする。

### 3.2 `KeenEmpiricalContext`

最低限、次の field を持つ。

| field | type | 内容 |
|---|---|---|
| `contract_version` | `String` | `keen-ai-context/1.0.0` |
| `analysis_scope` | `AnalysisScope` | country、period、mode、model、literature/calibrated の対象 |
| `observed_data` | `Vector{ObservedSeriesSummary}` | date/value、source、series、period、unit、quality |
| `measurement` | `Union{MethodologySummary,Nothing}` | 観測方程式、変換、頻度、欠損処理、methodology version |
| `calibration` | `Union{CalibrationSummary,Nothing}` | 推定設定・値・診断 |
| `model_outputs` | `Vector{ModelOutputSummary}` | label、period、initial-state mode、trajectory / divergence |
| `validation` | `Union{ValidationSummary,Nothing}` | fit metric と split |
| `regime_diagnostics` | `Vector{RegimeDiagnosticSummary}` | observed / literature / calibrated を別要素で保持 |
| `sensitivity` | `Vector{SensitivitySummary}` | base と変更 scenario、差、安定性 |
| `limitations` | `Vector{LimitationSummary}` | code、本文、category、source IDs とともに caveats を保持 |
| `warnings` | `Vector{ExplanationWarning}` | §5 の severity / code / affected sources |
| `sources` | `Dict{String,EvidenceSource}` | §2 の registry |
| `prompt_version` | `String` | context 作成時に想定した prompt version |

後続実装で要求する summary の最小 field は次のとおり。

| type | 必須情報 |
|---|---|
| `ObservedSeriesSummary` | variable、date/value の観測点、provider/source、series ID、mode、period、変換後 unit、quality flags、source IDs。欠損値は `nothing` とし 0 化しない |
| `CalibrationSummary` | estimated/fixed parameters、bounds、initial guess、objective method/value、weight、converged、iterations、excluded observations、boundary hits、weak identification、nonunique solutions、standard-error support、methodology version |
| `ValidationSummary` | in/out-of-sample period、model label、initial-state mode、variable、n pairs、RMSE、MAE、correlation、direction accuracy、turning-point error、divergence、literature comparison |
| `RegimeDiagnosticSummary` | subject (`observed_proxy` / `literature_model` / `calibrated_model`)、methodology / amortization、regime share、transition times、coverage / margin、divergence、proxy limitation |
| `SensitivitySummary` | scenario name/kind、changed assumption、tested range/value、base reuse、parameter / objective / fit / regime difference、sign reversal、divergence、robustness status |
| `MethodologySummary` | series mapping、original / output unit、conversion formula、frequency aggregation、missing / invalid handling、vintage、measurement/calibration/validation/diagnostic versions、seed と再実行設定 |
| `LimitationSummary` | stable code、text、根拠 category、affected source IDs。自由文だけの caveat に潰さない |

primary adapter は `KeenEmpiricalContext(dataset::KeenEmpiricalDataset, result::KeenValidationResult)` とし、
dataset の dates / observed series と result の trajectory / summary を再計算せず写像する。保存済み
`keen_empirical_report` だけから作る adapter では、report が意図的に保存していない raw observed / trajectory を
補完せず、該当 field を `nothing`、section を `not_available` とする。非有限値を 0 に変換せず JSON `null` とし、
その理由を warning / missing field に残す。

### 3.3 実証層成果物からの標準写像

| 実証層 path | category / summary |
|---|---|
| `dataset.dates`, `dataset.ω/λ/d/r`, `dataset.provenance`, `quality_flags` | `observed_data` / `ObservedSeriesSummary` |
| `methodology.measurement`, series の `conversion_formula`, `aggregation` | `measurement` / `MethodologySummary` |
| `validation.calibration` | `calibration` / `CalibrationSummary` |
| `result.trajectories`, `validation.evaluations` | `model_output` + `ValidationSummary` |
| `validation.regime_comparison.observed` | `diagnostic_proxy` / subject=`observed_proxy` |
| `validation.regime_comparison.literature` / `.calibrated` | `diagnostic_proxy` / subject=`*_model` |
| `validation.sensitivity` | `sensitivity` / `SensitivitySummary` |
| `validation.warnings`, `validation.caveats` | `limitations` / `ExplanationWarning` |
| `methodology.*`, calibration config、split info、seed | reproducibility metadata |

## 4. 構造化出力契約（Issue #131）

### 4.1 公開 API

専用 API は次を基準形とする。

```julia
explain_keen_empirical_result(
    context::AnalysisContext;
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
)::KeenEmpiricalExplanationOutput
```

prompt の生成は `build_keen_empirical_prompt(context; audience, detail)` として provider 呼び出しから分離する。
provider 未接続でも context 生成、prompt 生成、決定的 fallback 出力を利用できることを必須とする。

### 4.2 claim と section

```julia
EvidenceClaim(
    claim_id::String,
    text::String,
    epistemic_status::Symbol,
    source_ids::Vector{String},
    qualifiers::Vector{String},
)

ExplanationSection(
    status::Symbol,                 # :available | :not_available | :insufficient_evidence
    claims::Vector{EvidenceClaim},
    missing_fields::Vector{String},
)
```

`status=:available` は全 claim が schema と source registry の検証を通った場合だけ許可する。
`not_available` は入力自体がなく計算・取得されていない状態、`insufficient_evidence` は入力はあるが
欠損・warning・不整合により結論を支えられない状態に使う。空文字やセクション省略で代用しない。

### 4.3 必須 field と表示順

`KeenEmpiricalExplanationOutput` は、少なくとも次の field を常に持つ。

| order | field | 対応する必須出力 |
|---:|---|---|
| 0 | `executive_summary` | 根拠付き要約。新しい事実を追加しない |
| 1 | `analysis_scope` | 分析対象と期間 |
| 2 | `observed_evidence` | 観測された事実 |
| 3 | `measurement_and_transformations` | 測定・データ変換 |
| 4 | `calibration_interpretation` | キャリブレーション結果 |
| 5 | `validation_assessment` | in-sample / out-of-sample 検証 |
| 6 | `regime_assessment` | regime 診断 |
| 7 | `sensitivity_and_robustness` | 感応度・頑健性 |
| 8 | `interpretation_scope` | 解釈可能な範囲 |
| 9 | `limitations_and_alternatives` | 限界・代替説明 |
| 10 | `source_references` + `reproducibility` | 根拠参照と再現情報 |

さらに `contract_version="keen-ai-output/1.0.0"`、`prompt_version`、`generation_status`
（`parsed` / `deterministic` / `fallback`）、`warnings`、共通免責を持つ。
`source_references` は実際に claim から参照された registry entry だけを重複なく返す。

## 5. warning severity と説明への反映

`ExplanationWarning` は `code`、`severity`、`message`、`affected_source_ids`、`affected_sections` を持つ。

| severity | 説明への反映 |
|---|---|
| `info` | 該当 claim の qualifier または再現情報へ表示する。結論は妨げない |
| `warning` | 該当 section に注意を必須表示し、無条件・肯定的な結論を禁止する |
| `error` | 該当 section を `insufficient_evidence` とし、問題のある source に基づく解釈 claim を生成しない。値の存在自体は `[推定未収束]` 等として報告可 |
| `blocking` | provider を呼ばない、または応答を採用しない。全出力を §7 の fallback にする |

最低限、次の code を標準化する。

| code | 既定 severity | 必須動作 |
|---|---|---|
| `CALIBRATION_NOT_CONVERGED` | `error` | 推定値を真値として解釈せず calibration を `insufficient_evidence` |
| `WEAK_IDENTIFICATION` / `NONUNIQUE_SOLUTION` | `warning` | 推定値の一意性・精度を主張しない |
| `OOS_WORSE_THAN_LITERATURE` | `warning` | metric は報告するが妥当性・予測力を主張しない |
| `MODEL_DIVERGED` | `error` | 発散後を補間せず、影響 period の model / validation claim を抑止 |
| `REGIME_MISMATCH` | `warning` | observed proxy と model diagnosis を別表示し、一致を主張しない |
| `SENSITIVITY_UNSTABLE` | `warning` | robustness を `insufficient_evidence` または「不安定」とする |
| `MISSING_SOURCE_REFERENCE` | `error` | 対象 claim を破棄する |
| `CONTEXT_SCHEMA_INVALID` / `OUTPUT_SCHEMA_INVALID` | `blocking` | strict fallback |

## 6. 禁止解釈

Keen 実証説明では、汎用 [LLM 安全性ルール](../llm_safety.md) に加えて次を禁止する。

| 禁止 | 許可される表現の方向 |
|---|---|
| calibrated parameter を経済構造の真値・因果 parameter・普遍定数と断定 | 特定の標本、proxy、bounds、objective のもとで得た限定推定値 |
| in-sample fit をモデル妥当性の十分条件とする | 標本内 metric をその期間・初期値方式とともに報告 |
| out-of-sample fit を因果的妥当性、将来予測保証、政策効果の証明へ昇格 | holdout 区間での条件付き trajectory fit として限定 |
| observed proxy regime を Keen 内部の endogenous regime や企業別実測分類と同一視 | 同じ診断式を集計 proxy へ適用した操作的区分 |
| 相関・転換点・timing 一致だけから危機の因果経路を確定 | 一致という記述と、代替説明・証拠不足を分離 |
| 未検証範囲まで感応度の頑健性を外挿 | 実際に変更した scenario と範囲内だけを記述 |
| 欠損、頻度変換、単位差、系列改定を無視して直接比較 | measurement と quality / vintage を併記 |
| 発散後の `null` / `NaN` を 0、Ponzi、観測なし以外の状態へ読み替え | 欠損または発散として明示 |
| context にないデータ、文献、モデル特性を一般知識から補完 | `not_available` / `insufficient_evidence` |
| 投資助言、政策勧告、危機確率へ変換 | 学術的な条件付き分析と免責を表示 |

## 7. schema validation と fallback

### 7.1 provider 応答の検証順

1. JSON として parse できること。Markdown code fence や前後の自由文を暗黙採用しない。
2. `contract_version` と全必須 section / field が存在すること。
3. section status と claim schema が固定語彙に一致すること。
4. すべての `source_ids` が input registry に存在すること。
5. category と `epistemic_status`、warning severity による section status が整合すること。
6. 禁止解釈を誘発する未参照・無限定 claim がないこと。

一つでも失敗した場合、部分的な自由文 salvage はせず `generation_status="fallback"` とする。raw response は
debug logging の対象にはできるが、ユーザー向け claim や source reference へ混入させない。

### 7.2 決定的 fallback

fallback は検証済み input context だけから組み立てる。

- すべての必須 section を返す。
- registry を辿って安全に転記できる識別情報・warning・limitations だけを claim にする。
- 欠けた section は `not_available`、問題のある section は `insufficient_evidence` とする。
- 新しい経済メカニズム、因果説明、予測、頑健性評価を生成しない。
- parser failure の warning と共通免責を必ず含める。

context schema 自体が不正な場合は数値を転記せず、analysis scope と schema error、全 section の
`insufficient_evidence`、免責だけを返す。

## 8. provider 境界と versioning

### 8.1 責務境界

| DME 共通層 | provider adapter |
|---|---|
| 実証層 adapter、根拠分類、source registry | 完成済み prompt / request の送信 |
| system instruction と prompt 構築 | provider 固有 parameter の変換 |
| output schema、parser、source / safety validation | raw response / transport error の返却 |
| warning severity、fallback、免責 | timeout / retry 等の通信処理 |
| context / prompt / output version の artifact 記録 | 根拠 category や claim の書き換えはしない |

provider の structured-output 機能を利用しても DME 側の validation を省略しない。provider 非対応時も
同じ JSON schema を prompt で要求し、同じ parser / fallback を使う。

### 8.2 versioning

次を別々に記録する。

- `context_contract_version = "keen-ai-context/1.0.0"`
- `prompt_version = "keen-ai-explanation-prompt/1.0.0"`
- `output_contract_version = "keen-ai-output/1.0.0"`
- 実証層の measurement / calibration / validation / diagnostic methodology versions

field の optional 追加や文言修正は minor / patch、category、必須 field、status 意味論、禁止解釈の変更は major
を上げる。保存 artifact には使用した全 version、`audience`、`detail`、provider 名（利用時）、生成時刻、
source artifact path を記録する。API key、環境変数値、raw secret は記録しない。

## 9. 必須 fixture 例

| case | input condition | 必須 output |
|---|---|---|
| 正常 | 収束、source 完備、in/OOS metric・regime・感応度あり | 全 section `available`。推定・モデル・diagnostic のラベルと source ID を分離。fit から因果・予測を主張しない |
| 推定未収束 | `calibration.converged=false` | `CALIBRATION_NOT_CONVERGED`。calibration は `insufficient_evidence`。試行値は「未収束の推定試行」としてのみ表示し、calibrated model の肯定評価を抑止 |
| OOS 悪化 | calibrated OOS が literature より悪い | `OOS_WORSE_THAN_LITERATURE`。in/OOS を別 claim で表示し、「標本外で改善しない」と報告。因果妥当性や将来予測力へ変換しない |
| regime 不一致 | observed proxy と calibrated model の区分・遷移が不一致 | `REGIME_MISMATCH`。両 subject と source を別表示し、不一致原因は `insufficient_evidence`。observed proxy を endogenous regime と呼ばない |
| 感応度不安定 | scenario 間で符号反転、発散、主要結論の変化 | `SENSITIVITY_UNSTABLE`。頑健性を主張せず、検証済み範囲と変えた仮定を列挙。範囲外へ外挿しない |

加えて #130 では「実データあり」「一部欠損」「simulation only」、#131 では不正 JSON、必須 section 欠落、
未登録 source ID、既存 `explain_result` / `explain_data_comparison` 回帰をテストする。

## 10. 互換性・移行方針

- 汎用 `AnalysisContext` と `ExplainResultOutput` / `ExplainDataComparisonOutput` は維持する。
- Keen の通常 simulation 説明は従来 `explain_result` を利用できる。
- 実証層の成果物を説明する場合だけ `keen_empirical` と専用 API を用いる。
- 汎用 `DataComparisonSummary` へ Keen の calibration / diagnostic / sensitivity を押し込まない。
- 将来の cross-model 説明は source registry と `EvidenceClaim` を再利用できるが、Keen 固有 summary を
  無理に共通化しない。概念対応は後続 #132 の `ModelConceptMapping` で明示する。

## 理由

- 型と source registry で根拠境界を先に固定すると、prompt 文言だけに安全性を依存せず parser / test でも検証できる。
- 必須 section と明示的 status は、情報不足時のもっともらしい補完を防ぐ。
- warning を制御フローに反映すると、未収束・発散・OOS 悪化を末尾の注意書きだけで打ち消す矛盾を防げる。
- provider 非依存 schema と fallback は、LLM 未接続・応答不正・provider 変更時にも同じ安全性を維持する。
- 既存 API を optional 拡張に留めることで、通常の simulation 説明と実証説明を共存できる。

## 見送りとした選択肢

- **実証層 report をそのまま prompt へ渡す**: category と claim-level source がなく、根拠混同を検証できない。
- **一つの confidence score へ集約する**: 観測、推定、診断、感応度の性質を隠し、恣意的な重みを導入する。
- **provider 固有 structured output だけに依存する**: provider 変更時に契約が変わり、DME 側の安全検証ができない。
- **parser failure 時に raw text を表示する**: 必須 section、source、禁止解釈を検証できない。
- **既存 `DataComparisonSummary` を破壊的に拡張する**: 汎用 API の意味を変え、既存利用者へ不要な Keen 固有 field を課す。

## 影響

- #130 は §2〜§3 の型、実証層 adapter、JSON serialization、warning 生成を実装する。
- #131 は §4〜§9 の専用 prompt、output 型、parser、fallback、fixture test を実装する。
- #132 以降は source registry と claim 契約を再利用できるが、比較不能な概念を同一 source / claim に統合しない。
- 実証層の数値計算、`KeenModel`、calibration / validation / diagnostic の methodology は変更しない。

## 参考

- [Keen モデル実証化戦略](../models/keen_empirical_strategy.md) — 観測方程式、限定推定、検証、感応度の実装契約
- [ADR 0004](0004-keen-empirical-calibration-strategy.md) — 実証層の識別・検証方針
- [Minsky 資金調達区分診断](../models/minsky_regime_diagnostics.md) — observed / model ともに用いる診断 proxy の操作的定義
- [LLM 出力の安全性ルール](../llm_safety.md) — 汎用の禁止表現、免責、レビュー基準
- [AnalysisContext 設計](../architecture/analysis_context.md) — 既存 API と後方互換性の基準
