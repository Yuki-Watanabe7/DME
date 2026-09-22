# Japan Fiscal Scenario Lab — model adapter / scenario runner / result artifact 契約

Japan Fiscal Scenario Lab（[Issue #273](https://github.com/Yuki-Watanabe7/DME/issues/273)）のうち、
#274（[capability / mapping 契約](japan_fiscal_scenario_capability.md)）が採用（`adoption=
:primary`/`:supporting`）した14セルを実際に実行し、#285（[claim-level / coverage 契約](japan_fiscal_claim_level_contract.md)）
の規則を満たすversioned result artifactを生成する層。[Issue #276](https://github.com/Yuki-Watanabe7/DME/issues/276) の成果物であり、
E2E / consumer fixture（#277）はこの artifact を前提に進める。

> 関連: [ADR 0023](../adr/0023-japan-fiscal-scenario-result-artifact-contract.md)（決定記録）・
> [capability / mapping 契約](japan_fiscal_scenario_capability.md)（#274）・
> [claim-level / coverage 契約](japan_fiscal_claim_level_contract.md)（#285）・
> [scenario schema 契約](japan_fiscal_scenario_schema_contract.md)（#275）

実装ファイル: [`src/scenarios/adapters/japan_fiscal_model_adapters.jl`](../../src/scenarios/adapters/japan_fiscal_model_adapters.jl)・
[`src/scenarios/japan_fiscal_result.jl`](../../src/scenarios/japan_fiscal_result.jl)。
契約 version: `JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION = "japan-fiscal-scenario-adapter/1.0.0"`・
`JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION = "japan-fiscal-scenario-result/1.0.0"`。

---

## 1. この文書が決めること・決めないこと

決めること。

- 採用14セルの `JapanFiscalScenario` → モデル入力への変換規則（unit変換・適用の時間形状）。
- baseline/scenarioの実行方式（モデルごとの既存public API呼び出し）。
- 診断（direction/peak/onset/duration/relative_delta）を `claim_level` に従って生成する規則。
- result artifactのフィールド構成・identity hash・atomic write。

決めないこと。

- モデル方程式の改造（#273 non-goal）。本契約は既存モデルを一切変更しない。
- `run_scenario`/`map_event`（一般macro-eventレイヤー、ADR 0010・0015）の変更。
- E2E fixture・Market Analyzer handoffの実装（#277）。
- モデルの自動選択・ランキング。

---

## 2. 境界と層

```text
JapanFiscalScenario（#275）
  └─ JapanFiscalModelMapping（#274）の inputs を読み、恒久step + unit変換で
     モデル変数/パラメータへ適用（本契約）
Model adapter（9モデル、src/scenarios/adapters/japan_fiscal_model_adapters.jl）
  └─ 各モデルの既存public APIを直接呼ぶ（run_scenario/map_eventは経由しない）
JapanFiscalAdapterOutput
  └─ baseline/scenario系列 + traceability（JapanFiscalAppliedInput）
JapanFiscalComparisonDiagnostics
  └─ claim_level（#285）が許す診断だけを計算する
JapanFiscalScenarioResult（result artifact）
```

### 2.1 一般macro-eventレイヤーを経由しない（ADR 0023決定2）

CCCを含む9モデルいずれも `Scenario`/`ScenarioAssumption`/`EventTiming`/`PersistenceSpec`/
`run_scenario`/`map_event`（ADR 0010・0015）を経由しない。各adapterはモデルの既存public API
（`capex_run`・`_sim_run`・`impulse_response`・`transition_path`・`*_shock`/`*_comparison`
比較ヘルパ）を直接呼ぶ。理由はADR 0023 §理由を参照。

### 2.2 恒久step適用規則（ADR 0023決定1）

`JapanFiscalScenarioAssumption` はtiming/persistenceフィールドを持たない（#275）。本契約は
唯一の適用規則として「評価区間の先頭期から恒久的に適用する」を固定する
（`_japan_fiscal_permanent_step_path`、`shock_shape_path(PersistenceSpec(shape=:step,
duration=nothing), magnitude, t0, periods, nothing)` をそのまま使う）。`:shock_process` 種別
（NKのpolicy_rate・RBCのproductivity_growth）はモデル自身の `impulse_response` が使う
モデル固有の減衰パラメータ（`ρ_m`・`ρ`）に従う。

---

## 3. 14セルの adapter 実装

`adoption != :not_adopted` の14セル。`japan_fiscal_model_mapping(family, model).inputs` から
concept単位で読み取り、`input_kind` に応じて汎用的に分岐する（1モデル=1adapter関数。familyに
よる分岐はしない。例: Keenは`r`（F1・F5）と`α`（F4）のどちらのconceptが実際に
scenario.assumptionsに存在するかで自動的に切り替わる）。

| Family | Model | result_shape | claim_level | concept → variable（scale） |
|---|---|---|---|---|
| low_growth_high_rates | capex_credit_cycle | time_path | direction_and_relative_timing | policy_rate→`policy_rate`（×1、%pt annualized） / long_rate_funding_condition→`spread_shock_ex`（×1、bp） |
| low_growth_high_rates | new_keynesian | time_path | direction_and_relative_timing | policy_rate→`i`（÷100、shock=:monetary） / inflation→`π_star`（÷100） |
| low_growth_high_rates | keen | static_point | direction_only | long_rate_funding_condition→`r`（÷10000、bp→decimal real rate） |
| fiscal_consolidation | sim | time_path | direction_and_relative_timing | government_spending→`G`（×1） / tax→`θ`（×1） |
| fiscal_consolidation | islm | static_point | direction_only | government_spending→`G`（×1） / tax→`T`（×1） |
| fiscal_consolidation | adas | static_point | direction_only | government_spending→`G`（×1） / tax→`T`（×1） |
| fiscal_consolidation | mundell_fleming | static_point | direction_only | government_spending→`G`（×1） / tax→`T`（×1） |
| financial_repression | new_keynesian | time_path | direction_and_relative_timing | policy_rate→`i`（÷100、shock=:monetary） / inflation→`π_star`（÷100） |
| high_growth_productivity | solow | time_path | direction_and_relative_timing | productivity_growth→`g`（÷100） |
| high_growth_productivity | rbc | time_path | direction_and_relative_timing | productivity_growth→`A`（1年相当のlog水準シフト、非一意） |
| high_growth_productivity | adas | static_point | direction_only | productivity_growth→`Y_n`（1年相当の水準シフト、非一意） |
| high_growth_productivity | keen | static_point | direction_only | productivity_growth→`α`（÷100） |
| jgb_funding_cost | capex_credit_cycle | time_path | direction_and_relative_timing | long_rate_funding_condition→`spread_shock_ex`（×1、bp） / policy_rate→`policy_rate`（×1） |
| jgb_funding_cost | keen | static_point | direction_only | long_rate_funding_condition→`r`（÷10000） |

期間長に依存し一意でない換算（RBCのTFP水準シフト・AD-ASの潜在産出シフト）は1年相当として
計算し、その旨を `warnings` へ記録する（#274 §4.4 の記述通り、この非一意性は#274が既に
明示している）。

### 3.1 baselineパラメータ

全モデルとも `examples/`・`docs/models/` が使う既存のillustrativeパラメータをそのまま使う
（新しい日本較正は行わない、`G-02`）。例: IS-LM `ISLMModel(100.0, 0.8, 200.0, 50.0, 100.0,
100.0, 0.2, 100.0, 1000.0, 1.0)`（`examples/policy_analysis.jl`）・CCC
`capex_credit_cycle_model(capex_credit_cycle_default_targets())`。

### 3.2 モデル別の固有要件（#274 §5.2 準拠）

| モデル | 実装 |
|---|---|
| SIM | `government_spending`/`tax` を同時に期別系列（`Gseq`/`θseq`）として `_sim_run` へ渡す薄いadapter |
| New Keynesian | `π_star` の変更と `:monetary` ショックの組み合わせをF3で許容。`ρ_m` が0.95以上のとき警告を記録 |
| Solow | `g` の変更を baseline と scenario の両方の `transition_path` へ反映し比較する |
| RBC | `impulse_response` が `maxT+1` 要素を返すことを踏まえ `periods` を系列長に合わせる |
| Keen | `keen_scenario_comparison`（2インスタンス比較）をそのまま利用。双安定性の注意を `warnings` に記録 |
| CCC | `capex_run` の `exog` へ baseline（`_ccc_baseline_exog`）をコピーし `policy_rate`/`spread_shock_ex` だけを恒久stepで上書きする。`ai_exp` は動かさない。両concept同時適用時は `sensitivity["contribution_decomposition"]` に反実仮想寄与分解を記録する |
| IS-LM / AD-AS / Mundell-Fleming | 既存の `*_shock`/`*_comparison` ヘルパ（2点比較）をそのまま利用。peak/onset/durationは計算しない |

### 3.3 感応度（`sensitivity`）

各adapterは代表出力変数について ±50% 感応度（`_jf_pm50_sensitivity`）を `sensitivity` へ
記録する。primary_balanceの閉じ変数選択（IS-LM/AD-AS/SIM。§5.3）・CCCの寄与分解は今後の
拡張余地として `sensitivity` の追加キーで表現できる形にしてある。

---

## 4. 診断（`JapanFiscalComparisonDiagnostics`）

`japan_fiscal_coverage(family, model).permitted_diagnostics` が許す範囲だけを計算する
（ADR 0023決定3）。

| claim_level | 計算するフィールド |
|---|---|
| `:direction_only` | `direction`・`sign_of_delta` のみ |
| `:direction_and_relative_timing` | 上記に加え `relative_delta`・`peak`・`trough`・`onset_period`・`duration_periods`・`recovery_period`・（CCCの2concept同時適用時のみ）`contribution_decomposition` |

peak/onset/duration/recovery の計算は `analysis/scenario_diagnostics.jl` の
`_scenario_diag_extremum`/`_scenario_diag_breach`/`_scenario_diag_onset`/
`_scenario_diag_recovery`/`_scenario_diag_rel`（`ScenarioRun` に依存しない純関数）を
そのまま再利用する。`:direction_only` のセルでは、これらのフィールドは `null` として
現れるのではなく、そもそも `to_dict` の出力に**キーとして存在しない**。

`relative_delta` は `Union{Float64,Missing}` を保持するが、JSON化（`to_dict`）の際に
`missing → null` へ変換する（`canonical_json_bytes` は `Missing` をサポートしないため）。

---

## 5. result artifact のフィールドと H-06..H-12 対応

`JapanFiscalScenarioResult` の全フィールドは `to_dict` で以下のキーへ写像する。

| フィールド群 | キー | 対応 |
|---|---|---|
| provenance | `schema_version`・`adapter_contract_version`・`capability_contract_version`・`claim_contract_version`・`scenario_schema_version` | 4契約全てのversion chain |
| scenario identity | `scenario_id`・`scenario_content_hash`・`assumption_set_hash` | #275の2種のhashをそのまま複製 |
| observed context identity | `fre_context_identity` | nullable |
| model identity | `model_name`・`parameter_identity_hash` | baseline paramsのhash（決定11、値配列化） |
| traceability | `applied_inputs` | assumption_id→target→conversion |
| 3分類（H-10） | `observed`（FRE context）・`assumed`（scenario assumptions）・`model_implied`（baseline/scenario系列、numeric_semanticsタグ付き） | |
| coverage（H-06） | `coverage` | `to_dict(japan_fiscal_coverage(family,model))` を丸ごと埋め込む |
| F5 leg分離（H-11） | `funding_cost_legs` | jgb_funding_costのみ非null。sovereignは常に`"unsupported"` |
| 診断 | `diagnostics`・`sensitivity` | §4参照 |
| 実行状態 | `execution_status`・`termination_reason`・`warnings` | |
| identity hash | `generated_at`（volatile）・`result_content_hash`（`generated_at`と自身を除いた正準JSONのSHA-256） | |

`japan_fiscal_validate_claims`（#285）は `japan_fiscal_run` の内部で、まさにこれから生成する
診断・数値意味づけ・開示予定のunsupported一覧を渡して呼ばれ、違反があれば `ArgumentError` で
artifact自体を生成しない（H-07）。

---

## 6. not_adopted セルの扱い

`adoption === :not_adopted`（not_representable 40件 + partial-but-not_adopted 1件、計41件）は
モデルを実行せず `JapanFiscalScenarioRejection`（`status=:not_executed`）を返す。
`japan_fiscal_run` の戻り値は `Union{JapanFiscalScenarioResult,JapanFiscalScenarioRejection}`
であり、呼び出し側は型で分岐しなければならない（ADR 0023決定5）。

---

## 7. determinism・no secrets

- 同一 `family`/`model`/`scenario`（同一`scenario_content_hash`）・同一`horizon` は同一
  `result_content_hash` を生成する。
- `fre_context` だけを変えた2つの scenario は、同一の `model_implied`/`diagnostics` を生成する
  （`assumption_set_hash` が不変であるため。#275 H-05と同型の保証）。
- `save_japan_fiscal_scenario_result` の `base_dir`（ファイルシステムパス）は identity（hash
  対象）に一切含まれない。`to_dict` の出力にファイルシステムパス文字列が現れないことをテストで
  検査する。

---

## 8. 公開 API

```julia
using DME

# JapanFiscalScenario は #275 の型（japan_fiscal_scenario_schema.jl）
sc = JapanFiscalScenario(;
    scenario_id = "example",
    family = :fiscal_consolidation,
    provenance = JapanFiscalScenarioProvenance(; assumption_source = :user),
    assumptions = [
        JapanFiscalScenarioAssumption(;
            assumption_id = "a1", concept = :government_spending,
            magnitude = -10.0, magnitude_source = :derived,
        ),
    ],
)

result = japan_fiscal_run(:sim, sc; horizon = 20)
# => JapanFiscalScenarioResult （adoption != :not_adopted のとき）
# => JapanFiscalScenarioRejection（adoption == :not_adopted のとき）

result isa JapanFiscalScenarioResult && result.diagnostics.direction[:output]
# => :down

d = to_dict(result)
result2 = japan_fiscal_scenario_result_from_dict(d)  # fail-closed round trip

save_japan_fiscal_scenario_result(result, "artifacts/")  # atomic write

japan_fiscal_result_artifact_contract()
# => Dict{String,Any}（Market Analyzer向け、Julia型なしで artifact の形を把握できる）
```

---

## 9. 後続 Issue への引き継ぎ

| Issue | 本契約から引き継ぐもの |
|---|---|
| #277（E2E / consumer fixture） | `japan_fiscal_run`・`JapanFiscalScenarioResult`/`JapanFiscalScenarioRejection`・`japan_fiscal_result_artifact_contract()`（Market Analyzer が読む機械可読 export）・14セルの result 実例 |

`japan_fiscal_result_artifact_contract()` は #276 の artifact contract 全体を1つの
`Dict{String,Any}` として返す。Market Analyzer は Julia 内部型を import せず、この Dict と
実際の `to_dict(result)` のみを consume する。
