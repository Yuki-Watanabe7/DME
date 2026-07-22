# ADR 0006: クロスモデル推論は概念対応を明示し、比較不能を統合せず、根拠と限界を分離する

- **ステータス**: 採用
- **日付**: 2026-07-22
- **関連Issue**: #99（ロードマップ）・#132（本決定・実装）・#130 / #131（再利用する `AnalysisContext` 拡張・説明 API）
- **前提ADR**: [ADR 0005](0005-keen-ai-explanation-contract.md)（根拠階層・source registry・構造化出力/fallback。§10 で cross-model 説明の再利用方針を規定）
- **関連ドキュメント**: [クロスモデル推論層の設計](../architecture/cross_model_reasoning.md)・[モデル選択ガイド](../model_selection_guide.md)・[モデル変数と実データ系列のマッピング表](../data/variable_mapping.md)・[LLM 出力の安全性ルール](../llm_safety.md)

## コンテキスト

DME には解析的マクロモデル群（Ramsey / Solow / RBC / IS-LM / AD-AS / New Keynesian /
Mundell-Fleming / VAR）と Minsky 系 Keen モデル、および Keen 実証層（キャリブレーション・
検証・regime 診断・感応度）がある。#132 は「Keen 実証結果を既存モデルの結果と比較し、共通点・
相違点・適用範囲を根拠付きで説明するクロスモデル推論層」を求める。

各モデルは同じ名前の変数でも定義が異なる（利子率 `r` は RBC=実質資本限界生産物、IS-LM/AD-AS/
Mundell-Fleming=名目、NK=名目 `i` と自然実質 `r_n`、Keen=外生一定の実質貸出金利）。出力単位も
水準・対数偏差・水準偏差が混在する（`docs/simulation_outputs.md`）。信用・民間債務・所得分配動学・
危機 regime を内生化するのは Keen だけである（`docs/model_selection_guide.md` §3）。これらを平坦に
比較すると、LLM が別定義の変数を同一視したり、あるモデルの失敗を別モデルの正しさの証明へ昇格させたり、
学習済み一般知識で未登録モデルの性質を補完したりする危険がある。

ADR 0005 §10 は「将来の cross-model 説明は source registry と `EvidenceClaim` を再利用できるが、
Keen 固有 summary を無理に共通化しない。概念対応は後続 #132 の `ModelConceptMapping` で明示する」と
定めた。本 ADR はその契約を確定し、後続実装が追加の設計判断なしに型・registry・mapping 導出・prompt・
parser・fixture test を実装できるようにする。

## 決定

1. **概念対応を `ModelConceptMapping` で明示し、直接同一視を禁止する。** モデル対ごと・概念ごとに
   `equivalent` / `proxy` / `partial` / `incompatible` を割り当て、unit・frequency・aggregation の差と
   比較上の注意事項を保持する。同名変数でも定義が異なれば `equivalent` にしない。
2. **モデルの性質は repository metadata のみを根拠とする。** 各モデルが概念をどう扱うかは
   `ModelConceptCoverage` として docs 由来の固定 registry に符号化し、LLM の一般知識で未登録モデルの
   性質を補完しない。
3. **ADR 0005 の source registry と `EvidenceClaim` を再利用する。** 共通プリミティブ
   （`EvidenceSource` / `EvidenceClaim` / `ExplanationSection` / `ExplanationWarning`）の語彙を DME
   superset へ広げ、Keen 層は従来どおり狭い `KEEN_*` 語彙で内部検証を続ける。
4. **比較不能を無理に統合しない。** ある概念のすべての cross-model mapping が `incompatible` の場合、
   `INSUFFICIENT_COMPARABILITY` warning を出し、該当 section を `insufficient_comparability` として
   明示する。共通化・平均・単一ランキングへ潰さない。
5. **fit の単純比較を制限する。** モデル別 fit 指標は、対象系列・期間・自由度・推定方法が一致する
   場合に限り比較可能とし、既定では実証 fit を持つのは Keen 実証層だけであることを明記する。
6. **一つのモデルの失敗を別モデルの正しさの証明にしない。** 実証結果がどのモデルを相対的に
   支持・反証するかは、比較可能な範囲の条件付き記述に限定し、非当てはめモデルの反証・肯定に転用しない。
7. **schema / parser failure は決定的 fallback へ落とす。** provider 非接続でも決定的に生成し、
   provider 応答が検証を通らなければ検証済み context だけから安全な必須 section を返す（ADR 0005 §7 準拠）。

## 1. 概念軸と treatment

### 1.1 固定比較軸

Issue #132 の比較軸を固定語彙 `CROSS_MODEL_CONCEPTS` とする。

| concept | 内容 |
|---|---|
| `private_debt_credit` | 民間債務・信用拡張の役割 |
| `income_distribution` | 所得分配・賃金シェア・利潤率 |
| `demand_and_instability` | 需要不足と金融不安定性の伝播経路 |
| `steady_state_stability` | 定常状態・局所安定性・危機 regime の扱い |
| `shock_response` | 政策ショック・外生ショックへの反応 |

### 1.2 treatment

各 (model, concept) の扱いを `CROSS_MODEL_TREATMENTS` の 1 つで表す。

| treatment | 意味 | 例（docs 準拠） |
|---|---|---|
| `endogenous` | 概念を明示的に内生化 | Keen の `d`（民間債務比率）、RBC の技術ショック IRF |
| `approximate` | 近似・代理・部分的に扱う | RBC の限界生産力による要素分配、IS-LM の需要側 |
| `out_of_scope` | 対象外（docs の scope / 限界節で明示） | RBC の金融摩擦、Ramsey の需要不足 |

treatment は docs のモデル節・限界節・`docs/model_selection_guide.md` §3 の横断表を根拠に符号化する。

## 2. `ModelConceptCoverage`（repository metadata）

各 (model, concept) の repository metadata。

| field | type | 内容 |
|---|---|---|
| `model` | `Symbol` | モデル識別子（`:keen`, `:rbc`, …） |
| `concept` | `Symbol` | §1.1 の固定軸 |
| `treatment` | `Symbol` | §1.2 |
| `variables` | `Vector{String}` | その概念を表す変数記号（例 `["d"]`, `["ω","π"]`）。無ければ空 |
| `definition` | `String` | docs 由来の短い定義 |
| `definition_key` | `Symbol` | 等価判定用の正準キー。定義が真に一致する場合のみ同一値 |
| `unit` | `Union{String,Nothing}` | 単位（`"ratio"`, `"level (real)"`, `"log-deviation"` 等） |
| `frequency` | `Union{String,Nothing}` | 頻度（`"quarterly"`, `"annual"`, `"static"`, `"continuous"`） |
| `measure` | `Union{String,Nothing}` | 水準/偏差の別（`"level"`, `"deviation"`, `"ratio"`） |
| `doc_ref` | `String` | 根拠 docs パス・節 |
| `caveats` | `Vector{String}` | 定義差・限界の注意 |

registry は `MODEL_CONCEPT_REGISTRY::Vector{ModelConceptCoverage}` として固定し、`docs/models/*.md`・
`docs/model_selection_guide.md`・`docs/data/variable_mapping.md`・`docs/simulation_outputs.md` のみを
根拠とする。数値実証結果は含めない（それは §4 の empirical context が担う）。

## 3. `ModelConceptMapping` と導出規則

### 3.1 型

| field | type | 内容 |
|---|---|---|
| `source_model` / `target_model` | `Symbol` | 対象モデル対 |
| `concept` | `Symbol` | §1.1 |
| `mapping_type` | `Symbol` | `equivalent` / `proxy` / `partial` / `incompatible` |
| `source_variable` / `target_variable` | `Union{String,Nothing}` | 代表変数 |
| `unit_difference` | `Union{String,Nothing}` | 単位差（無ければ `nothing`） |
| `frequency_difference` | `Union{String,Nothing}` | 頻度差 |
| `aggregation_difference` | `Union{String,Nothing}` | 集計差 |
| `caveats` | `Vector{String}` | 比較上の注意事項 |
| `source_ids` | `Vector{String}` | 参照する coverage source ID |

### 3.2 導出規則（保守的）

2 つの coverage `a`（source）, `b`（target）から `mapping_type` を次で決める。

1. いずれかが `out_of_scope` → `incompatible`。
2. `definition_key` が一致し、かつ `measure` と `unit` が一致 → `equivalent`。
3. いずれかが `approximate`（かつ両方が概念を扱う） → `partial`。
4. 両方 `endogenous` だが定義・単位・measure のいずれかが異なる → `proxy`。

`equivalent` は定義・単位・水準/偏差が真に一致する場合だけに限る（決定 §1、安全性）。unit /
frequency / aggregation の差はそれぞれ差分 field へ転記し、値が同一なら `nothing` とする。

## 4. `CrossModelComparisonContext`

| field | type | 内容 |
|---|---|---|
| `contract_version` | `String` | `cross-model-context/1.0.0` |
| `concepts` | `Vector{Symbol}` | 比較対象の軸 |
| `models` | `Vector{Symbol}` | 比較対象モデル |
| `coverage` | `Vector{ModelConceptCoverage}` | 対象 (model, concept) の metadata |
| `mappings` | `Vector{ModelConceptMapping}` | §3 の概念対応 |
| `empirical` | `Union{KeenEmpiricalContext,Nothing}` | Keen 実証結果（あれば） |
| `model_metadata` | `Dict{Symbol,ModelMetadata}` | 比較モデルの repository metadata（任意） |
| `sources` | `Dict{String,EvidenceSource}` | ADR 0005 §2 の registry |
| `warnings` | `Vector{ExplanationWarning}` | §5 |
| `prompt_version` | `String` | `cross-model-reasoning-prompt/1.0.0` |

primary builder は `build_cross_model_comparison_context(; models, concepts, empirical, model_metadata)`。
registry を (models × concepts) で絞り込み、coverage source（category `:model_concept`）と mapping
source（category `:concept_mapping`）を登録し、empirical があれば実証結果サマリー source
（category `:empirical_evidence`）を派生する。empirical の内部 source registry を直接展開せず、
検証・regime の要約だけを cross-model 用の安定 ID で再登録し、根拠の粒度を混同しない。

## 5. warning

`ExplanationWarning`（ADR 0005 §5）を再利用し、最低限次を標準化する。

| code | 既定 severity | 必須動作 |
|---|---|---|
| `INSUFFICIENT_COMPARABILITY` | `warning` | 該当概念の cross-model 結論を出さず section を `insufficient_comparability` |
| `FIT_COMPARISON_RESTRICTED` | `info` | fit の単純比較を抑止し、比較条件（系列・期間・自由度・方法の一致）を明示 |
| `EMPIRICAL_ONLY_FOR_KEEN` | `info` | 実証 fit を持つのは Keen 実証層だけである旨を明示 |
| `DEFINITION_MISMATCH` | `warning` | 同名変数の定義差を明示し、`equivalent` としない |
| `CONTEXT_SCHEMA_INVALID` / `OUTPUT_SCHEMA_INVALID` | `blocking` | strict fallback |

## 6. 構造化出力 `CrossModelReasoningOutput`

ADR 0005 の `EvidenceClaim` / `ExplanationSection` を再利用し、必須 section を表示順で常に持つ。

| order | field | 対応する必須出力（Issue #132「推論出力」） |
|---:|---|---|
| 0 | `executive_summary` | 根拠付き要約。新しい事実を追加しない |
| 1 | `comparison_scope` | 比較対象モデル・概念・mapping 種別の内訳 |
| 2 | `concept_mappings` | 概念対応（equivalent/proxy/partial/incompatible）の明示 |
| 3 | `mechanisms_by_model` | 各モデルが説明できるメカニズム |
| 4 | `consistent_observations` | 複数モデルで整合的な観察 |
| 5 | `divergent_conclusions` | 結論が異なる箇所と、その原因となる仮定 |
| 6 | `empirical_support` | 現在の実証結果がどのモデルを相対的に支持・反証するか |
| 7 | `incomparable_or_insufficient` | 比較不能・証拠不足（`insufficient_comparability`） |
| 8 | `next_evidence` | 次に必要なデータ・シミュレーション |
| 9 | `limitations` | 限界・安全性 |
| 10 | `source_references` + `reproducibility` | 根拠参照と再現情報 |

section status は `:available` / `:not_available` / `:insufficient_comparability`。`epistemic_status`
は `:metadata`（coverage）・`:mapping`（概念対応）・`:empirical`（実証結果）・`:comparative`（合成観察）・
`:limitation`（限界）。`:metadata` / `:mapping` / `:empirical` の claim は対応 category の source のみ引用し、
`:comparative` / `:limitation` の合成 claim は複数 category の source を引用できる。

## 7. 禁止解釈（汎用 [LLM 安全性ルール](../llm_safety.md) と ADR 0005 §6 に加えて）

| 禁止 | 許可される方向 |
|---|---|
| 同名変数（`r`・`Y`・`K` 等）を定義差を無視して同一視 | mapping_type と unit/measure 差を明示した対応 |
| モデル別 fit を系列・期間・自由度・方法の不一致のまま単純比較 | 比較条件が一致する場合に限定し、既定は Keen のみ実証 fit を持つと明示 |
| あるモデルの失敗を別モデルの正しさの証明とする | 比較可能範囲の条件付き支持/反証に限定 |
| 実証結果を全モデルの優劣ランキングや ensemble へ集約 | 概念別・条件別の限定比較 |
| 未登録モデルの性質を一般知識で補完 | `not_available` / `insufficient_comparability` |
| 比較不能項目を近似や平均で埋める | `INSUFFICIENT_COMPARABILITY` として明示 |
| Keen 崩壊 regime を他モデルの単一定常状態と同一視 | 危機 regime の有無を相違点として分離 |

## 8. 非対象（Issue #132）

- 全モデル共通の統一パラメータ推定。
- ensemble 予測・モデル平均。
- モデル優劣の単一ランキング。
- モデルの数値計算・既存 model / calibration / validation / diagnostic の methodology 変更。

## 9. versioning

- `context_contract_version = "cross-model-context/1.0.0"`
- `prompt_version = "cross-model-reasoning-prompt/1.0.0"`
- `output_contract_version = "cross-model-output/1.0.0"`

registry の field 追加・文言修正は minor / patch、比較軸・treatment・mapping_type 語彙・section 意味論・
禁止解釈の変更は major を上げる。

## 理由

- 概念対応を型で先に固定すると、prompt 文言に依存せず parser / test で「別定義の同一視」を検出できる。
- repository metadata registry は、LLM の一般知識による未登録モデルの補完を構造的に防ぐ。
- ADR 0005 のプリミティブ再利用は、根拠境界・fallback・免責の安全性を cross-model でも同じ機構で維持する。
- 比較不能を明示的 status にすると、無理な統合・平均・単一ランキングを避けられる。

## 見送りとした選択肢

- **全モデルを共通変数空間へ写像して数値比較**: 定義差・単位差を隠し、同名変数の同一視を誘発する。
- **単一の適合度スコアでモデルを順位付け**: 対象系列・期間・自由度の違いを無視し、恣意的な重みを導入する。
- **LLM の一般知識でモデル性質を補完**: repository の scope を超え、検証不能な主張を生む。
- **Keen 固有 summary を全モデル共通型へ一般化**: ADR 0005 §10 の方針に反し、概念の非対称性を潰す。

## 影響

- #132 は §2〜§6 の型・registry・mapping 導出・context builder・prompt・parser・fallback・fixture test を
  実装する。ADR 0005 の `EvidenceSource` / `EvidenceClaim` 語彙を DME superset へ広げる（Keen 層の
  内部検証は不変）。
- 既存 `AnalysisContext` / `explain_result` / Keen 実証 API は変更しない。
- 将来モデルを追加する場合は `MODEL_CONCEPT_REGISTRY` に coverage を追記するだけで cross-model 比較へ
  参加できる。

## 参考

- [ADR 0005](0005-keen-ai-explanation-contract.md) — 根拠階層・source registry・構造化出力/fallback
- [モデル選択ガイド](../model_selection_guide.md) — モデル横断比較表（§3）
- [モデル変数と実データ系列のマッピング表](../data/variable_mapping.md) — 変数定義差・単位・変換
- [出力結果の読み方](../simulation_outputs.md) — 水準・対数偏差・水準偏差の別
- [LLM 出力の安全性ルール](../llm_safety.md) — 汎用の禁止表現・免責
