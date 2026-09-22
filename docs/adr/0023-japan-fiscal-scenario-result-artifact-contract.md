# ADR 0023: Japan Fiscal Scenario Lab の model adapter・scenario runner・result artifact contract

- **ステータス**: 採用
- **日付**: 2026-09-22
- **関連Issue**: [#273](https://github.com/Yuki-Watanabe7/DME/issues/273)（Japan Fiscal Scenario Lab ロードマップ）・[#274](https://github.com/Yuki-Watanabe7/DME/issues/274)（capability audit。本決定の前提）・[#285](https://github.com/Yuki-Watanabe7/DME/issues/285)（claim-level / coverage 契約。本決定の前提）・[#275](https://github.com/Yuki-Watanabe7/DME/issues/275)（scenario schema。本決定の前提）・[#276](https://github.com/Yuki-Watanabe7/DME/issues/276)（本決定）・downstream [#277](https://github.com/Yuki-Watanabe7/DME/issues/277)
- **前提ADR**: [ADR 0020](0020-japan-fiscal-scenario-capability-contract.md)（55セルのrepresentability・9 assumption concept）・[ADR 0021](0021-japan-fiscal-claim-level-contract.md)（claim-level / coverage・downstream handoff requirements 22件）・[ADR 0022](0022-japan-fiscal-scenario-schema-contract.md)（`JapanFiscalScenario`・`JapanFiscalFREContext`・2種のhash）・[ADR 0011](0011-capex-credit-cycle-dynamics-contract.md)（CCCの動学契約）・[ADR 0018](0018-capex-credit-cycle-empirical-runtime-contract.md)（`compose_exogenous_paths`+`capex_run`による`run_scenario`非経由のシナリオ合成の先例）・[ADR 0008](0008-real-rate-model-artifact-export.md)（hash自己参照排除・RFC 8785正準化・atomic write）
- **関連ドキュメント**: [model adapter / scenario runner / result artifact 契約](../architecture/japan_fiscal_scenario_result_contract.md)（本決定の詳細）・[capability / mapping 契約](../architecture/japan_fiscal_scenario_capability.md)（#274）・[claim-level / coverage 契約](../architecture/japan_fiscal_claim_level_contract.md)（#285）・[scenario schema 契約](../architecture/japan_fiscal_scenario_schema_contract.md)（#275）

---

## コンテキスト

#274/#285/#275 はいずれも**宣言のみ**であり、実際にモデルを実行してbaseline/scenarioの数値を
生成する層を持たない。#274が確定した55セルのうち14セル（`:primary` 5 + `:supporting` 9）が
Phase 3の実装対象であり、#276はこの14セルについて `JapanFiscalScenario`（#275）を実際の9モデル
（capex_credit_cycle・new_keynesian・keen・sim・islm・adas・mundell_fleming・solow・rbc）へ
接続し、baseline/scenarioの比較結果を#285のclaim-level契約に従うversioned artifactとして
出力しなければならない。

このとき解かなければならない設計上の空白が3つある。

1. `JapanFiscalScenarioAssumption`（#275）は `(assumption_id, concept, magnitude,
   magnitude_source, notes)` のみを持ち、**timing/persistenceを持たない**。#275は「family単位の
   horizon/persistence代表値をcatalogに持たせない」（ADR 0022決定7）と決めたが、
   per-(family,model)粒度でも「1つのmagnitudeが期別にどう作用するか」を決める主体が存在しない。
2. CCC（capex_credit_cycle）だけが一般macro-eventレイヤー（`Scenario`/`run_scenario`/
   `map_event`、ADR 0010・0015）に接続済みであり、他8モデルには`map_event`が無い。
   「既存public APIを最大限再利用する」（#276 scope）という要求を、9モデルにどう一様に適用するか。
3. `claim_level`（#285）はセルごとに`:direction_only`（7セル）と
   `:direction_and_relative_timing`（7セル）に分かれ、後者のみpeak/onset/duration/相対差を
   主張できる。診断計算をこの区別に厳密に従わせる仕組みが無い。

## 決定

1. **`JapanFiscalScenarioAssumption`のmagnitudeは、評価区間の先頭期から恒久的に適用される
   step関数として扱う。** 一般macro-eventレイヤーの`shock_shape_path`（`scenarios/scenario_time.jl`）
   をそのまま呼び、`PersistenceSpec(shape=:step, duration=nothing)`を唯一の適用規則として
   `_japan_fiscal_permanent_step_path`に固定する。#274の55セルのmapping行の`reason`・
   `baseline_requirements`がいずれも「恒久的」（"funding コストの恒久的な上昇"・
   "『名目金利を低位に据え置く』は持続的な…ショック"・"目標の変更"）と記述していることと一致する。
   `:shock_process`種別の入力（NKのpolicy_rate・RBCのproductivity_growth）は、モデル自身の
   `impulse_response`が内部で使うモデル固有の減衰パラメータ（NKの`ρ_m`・RBCの`ρ`）をそのまま
   使い、外部からpersistence shapeを注入しない（既存モデルへの分岐追加を避ける）。

2. **9モデルいずれも一般macro-eventレイヤー（`Scenario`/`run_scenario`/`map_event`）を経由せず、
   各モデルの既存public APIを直接呼ぶ。** CCCは`capex_run(m; exog=...)`、SIMは同一module内の
   `_sim_run(m, H0, Gseq, θseq)`、Solowは`transition_path`、RBC/NKは`impulse_response`、
   IS-LM/AD-AS/Mundell-Flemingは既存の`islm_policy_shock`/`adas_shock_compare`/
   `mf_policy_shock`（2インスタンス比較）、Keenは既存の`keen_scenario_comparison`を呼ぶ。
   CCCについても`run_scenario`/`map_event`を経由させない。

3. **診断（peak/onset/duration/relative_delta/contribution_decomposition）は、
   `japan_fiscal_coverage(family,model).permitted_diagnostics`が許すものだけを計算する。**
   計算そのものを`claim_level`でゲートし、許されない診断は`nothing`で隠すのではなく
   フィールドとして最初から生成しない。`result_shape=:static_point`（IS-LM/AD-AS/
   Mundell-Fleming/Keen）は常に`claim_level=:direction_only`と一致する（#274の55セルで
   実際に確認済み）ため、`result_shape=:time_path`かつ`permitted_diagnostics`が`:peak`を
   含む場合にのみtiming診断を計算する、という1つの条件で両方の区別を同時に満たす。

4. **9モデル・14セル共通の結果型`JapanFiscalAdapterOutput`を1つ定義し、`result_shape`を
   `:time_path`（期別系列。CCC/SIM/Solow/RBC/NK）と`:static_point`（均衡2点比較。IS-LM/
   AD-AS/Mundell-Fleming/Keen）の2値に限定する。** 9モデルの個別adapterは`mapping.inputs`
   を読み、`input_kind`（`:model_parameter`/`:shock_process`/`:exogenous_path`/
   `:requires_structural_conversion`）に応じて汎用的に分岐する。model別のcase分けは
   `src/scenarios/adapters/japan_fiscal_model_adapters.jl`という1ファイルに閉じ込め、
   `src/models/*.jl`・`run_scenario`・`map_event`は一切変更しない。

5. **`japan_fiscal_run(model, scenario; horizon)`の戻り値を`Union{JapanFiscalScenarioResult,
   JapanFiscalScenarioRejection}`とする。** `japan_fiscal_model_mapping(scenario.family,
   model).adoption === :not_adopted`（not_representable 40件 + partial-but-not_adopted 1件）
   のときはモデルを実行せず`JapanFiscalScenarioRejection`（`status=:not_executed`・
   `reason`はmappingの`reason`をそのまま複製）を返す。status flagを1つのstruct内に持たせる
   設計ではなく型で分岐させることで、「実行されなかった」ことを呼び出し側が握りつぶせない
   ようにする。

6. **`family`を`japan_fiscal_run`の引数に取らず、`scenario.family`から読む。** baselineと
   scenarioは常に同一のbaselineパラメータから各adapter内部で導出し、2つの独立したモデル
   インスタンスを呼び出し側から受け取らない。これにより「baseline/scenarioのmodel・params・
   初期状態・horizonの一致」はランタイム検証ではなく構成上不可能な誤りとして扱われる。
   `parameter_identity_hash`（baselineモデルの`parameters(m)`のハッシュ）はartifactへ記録し、
   consumer側が独立に確認できるようにする。

7. **result artifactは`japan_fiscal_coverage(family, model)`（#285）を`to_dict`のまま丸ごと
   埋め込む（H-06）。** 独自にunsupported concepts/outputs/channelsを再導出しない。
   `japan_fiscal_run`は実行前に`japan_fiscal_validate_claims`（#285）を、まさにこれから
   計算する診断・数値意味づけ・開示予定のunsupported一覧を渡して呼び、違反があれば
   `ArgumentError`でartifactを生成しない（H-07）。実装上は「計算する診断がpermitted_diagnostics
   そのもの」であるため通常は発火しないが、契約が要求する検査として残す（defense in depth）。

8. **F5（jgb_funding_cost）はsovereign leg（政府の調達コスト）とprivate pass-through leg
   （民間の実効借入コスト）を`funding_cost_legs`という別フィールドで持ち、sovereign legは
   常に`status="unsupported"`とする（H-11）。** 他familyではこのフィールドは`nothing`。

9. **`observed`（FRE context）・`assumed`（scenario assumptions）・`model_implied`
   （baseline/scenario系列+診断）を別々のtop-levelフィールドとして持つ（H-10）。**
   `model_implied`配下の各系列には`coverage.numeric_semantics`をタグ付けする。55セルに
   `:japan_magnitude`は存在しないため（#285）、`model_implied`が日本の量として読める形の
   フィールドを持つことは構造上ない。

10. **identity hash・atomic writeはADR 0008（real-rate model artifact）と同じidiomを
    そのまま再利用する。** `sha256_hex_of_canonical`（`artifacts/json_canonical.jl`）で
    RFC 8785正準化+SHA-256を行い、`generated_at`（volatile）と`result_content_hash`自身
    （自己参照）を除いた識別用dictから`result_content_hash`を計算する。この除外ロジックは
    `_japan_fiscal_result_content_hash`という1つの関数に集約し、`japan_fiscal_run`（計算時）
    と`japan_fiscal_scenario_result_from_dict`（round-trip検証時）の両方がこれだけを使う
    （2箇所に同じ除外対象フィールドを重複して書かない）。`save_japan_fiscal_scenario_result`
    は`.tmp`書き込み+`fsync`+atomic rename（`mv(...; force=false)`）とし、`base_dir`自体は
    hash対象に含めない（secrets/local pathをidentityへ混入させない）。

11. **モデルのGreek文字パラメータ名（NKの`φ_x`・Keenの`κ2`等）を`parameter_identity_hash`の
    JSONキーとして使わない。** `canonical_json_bytes`はASCIIのみのキーをサポートする
    （`artifacts/json_canonical.jl`の既存制約）。`parameters(m)`のNamedTupleは値配列
    （フィールド順）としてハッシュし、`model`シンボルと組にして曖昧さを避ける。

12. **baselineは各モデルの既存example/illustrativeパラメータ（`examples/`・`docs/models/`が
    使う値と同一）を用いる。** CCCが既に`capex_credit_cycle_default_targets()`で行っている
    方針を9モデル全体へ一般化したものであり、新しい日本較正を#276で発明しない（`G-02`は
    解消しない。`calibration_basis`は全14セルで`structural_illustrative`または
    `non_japan_calibrated`のまま）。

## 理由

- **決定1（恒久step固定）は、#275が意図的にtiming/persistenceフィールドを持たなかった
  ことへの唯一の一貫した応答である。** 「family単位の代表値を持たない」（ADR 0022決定7）は
  「per-model粒度でも各adapterが独自にpersistence shapeを選んでよい」ことを意味しない。
  55セル全体で"恒久的"という記述が一貫しているため、選択肢を1つに固定するほうが、
  モデルごとに異なる時間形状の想定を後から呼び出し側が読み違えるリスクより安全である。
- **決定2（一般macro-eventレイヤーを経由しない）は、9モデルの一様性を優先した判断である。**
  `Scenario`/`ScenarioAssumption`/`EventTiming`/`PersistenceSpec`は暦四半期（`period_zero::
  CalendarQuarter`）に固定された枠組みであり、`map_event`を持つのはCCCのみである。CCCだけを
  この枠組みへ通し、残り8モデルには全く別の薄いadapterを書くと、2つの非対称なコードパスが
  生まれ、artifactの一様性（H-06以下）を保つための変換コストが増える。ADR 0018が既に
  「`compose_exogenous_paths`+`capex_run`によるrun_scenario非経由のシナリオ合成」という
  先例をCCCについて確立しており、Japan Fiscal Scenario Labはこの先例が想定する
  ユースケース（暦に紐付かない抽象的なfamily横断比較）に合致する。「既存public APIを
  最大限再利用する」という要求は、`capex_run`/`_sim_run`/`impulse_response`等それ自体が
  既存public APIであるため、この設計でも満たされる。
- **決定3（claim_levelによる計算そのものの抑制）は、#285のH-07・consumer rulesが
  「peak/onset/durationをdirection_onlyの結果に表示しない」ではなく「そもそも計算しない」を
  要求しているためである。** artifactにnullとして存在すると、consumer側の実装ミスで
  「null=未計算」と「null=効果なし」を混同するリスクが残る。フィールド自体が無ければ
  そのリスクが構造的に消える。
- **決定5（Union型の戻り値）は、statusフラグ1つを`JapanFiscalScenarioResult`に持たせる
  設計より安全である。** Juliaの型システムでUnionを分岐させることを呼び出し側に強制でき、
  「resultを取得したがstatusを見ずに中身を使う」というよくある実装ミスの経路を塞ぐ。
- **決定6（baseline/scenarioの構成上の一致保証）は、#276の受け入れ条件
  「baselineとscenarioのmodel/params/initial-state/horizon一致を検証する」を、実行時検証
  より強い形で満たす。** 検証コードが存在してもテストされていなければ穴になるが、
  「そもそも2つの独立したモデルを受け取れないAPI」には検証漏れという状態が存在しない。
- **決定11は、実装中に実際に発生した障害から得られた教訓である。** `parameters(m)`を
  素朴に`Dict{String,Any}`へ変換してハッシュしようとすると、NK/Keen/Solow/RBCのGreek文字
  フィールド名で`canonical_json_bytes`が例外を送出する。値配列化はこの問題を構造的に
  回避し、かつADR 0008が確立した「identityはRFC 8785正準化を経由する」という規律を保つ。

## 見送りとした選択肢

- **CCCだけ`run_scenario`/`map_event`を経由させ、残り8モデルは薄いadapterにする**:
  理由の節で述べた通り、2つの非対称なコードパスがartifactの一様性コストを増やす。
  CCCの`policy_rate`/`spread_shock_ex`は`capex_run`の`exog`引数から直接触れるため、
  `run_scenario`を経由する追加の利点が乏しい。
- **assumptionにtiming/persistence用の新フィールドを#276で追加する**: #275
  （ADR 0022）が確定した`JapanFiscalScenarioAssumption`のフィールド集合を変更することは
  #275の決定を覆すことになり、また「1つのmagnitudeにつき1つの時間形状」という以上の
  柔軟性がPhase 3の14セルにおいて要求されていない。
- **`ScenarioDiagnosticThresholds`/peak・onset・recovery計算を独自に再実装する**:
  `analysis/scenario_diagnostics.jl`の`_scenario_diag_extremum`/`_scenario_diag_onset`/
  `_scenario_diag_recovery`/`_scenario_diag_rel`は`ScenarioRun`に依存しない純関数として
  既に存在し、`Vector{Float64}`の生diffだけを受け取る。独自実装は同じロジックの重複であり、
  将来の閾値変更が2箇所に必要になる。
- **`JapanFiscalScenarioResult`にstatus flagを持たせ、`not_adopted`のときも同じ型を返す**:
  決定5の理由の通り、型による分岐のほうが「statusを見ずに中身を使う」実装ミスを防げる。
- **peak/onset/durationをnullとして常にフィールドに含める**: 決定3の理由の通り、
  「そもそも計算しない」ほうがconsumer側の誤読リスクが低い。

## 影響

- **`src/scenarios/adapters/japan_fiscal_model_adapters.jl`を新設する**（`JAPAN_FISCAL_
  ADAPTER_CONTRACT_VERSION`・`JapanFiscalAppliedInput`・`JapanFiscalAdapterOutput`・9モデル分の
  adapter関数・`JAPAN_FISCAL_MODEL_ADAPTERS` registry）。
- **`src/scenarios/japan_fiscal_result.jl`を新設する**（`JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_
  VERSION`・`JapanFiscalComparisonDiagnostics`・`JapanFiscalScenarioResult`・
  `JapanFiscalScenarioRejection`・`japan_fiscal_run`・serialization・`japan_fiscal_result_
  artifact_contract`・`save_japan_fiscal_scenario_result`）。
- **`src/DME.jl`のinclude（末尾に2件追加）とexportのみを変更する。** #274/#285/#275の
  実装ファイル・モデル方程式（`src/models/*.jl`）・一般macro-eventレイヤー
  （`scenario_runner.jl`・`map_event`）・`SimulationResult`は変更しない。既存テスト・
  既存artifactの数値互換に影響しない。
- **#277（E2E / consumer fixture）は本ファイルの`japan_fiscal_run`・
  `japan_fiscal_result_artifact_contract()`を入力として使う。** Market Analyzerは
  Julia内部型をimportせず、この関数が返すDict/JSONのみをconsumeする。

## 参考

- [model adapter / scenario runner / result artifact 契約](../architecture/japan_fiscal_scenario_result_contract.md) — 14セルの adapter 実装詳細・artifact field表・H-06..H-12対応表
- [capability / mapping 契約](../architecture/japan_fiscal_scenario_capability.md)（#274） — 55セルの判定・§5 model-specific mapping requirements（本契約の実装対象）
- [claim-level / coverage 契約](../architecture/japan_fiscal_claim_level_contract.md)（#285） — H-06..H-12の要件定義元
- [scenario schema 契約](../architecture/japan_fiscal_scenario_schema_contract.md)（#275） — `JapanFiscalScenario`・2種のhashの定義元
- [ADR 0018](0018-capex-credit-cycle-empirical-runtime-contract.md) — `run_scenario`非経由のシナリオ合成の先例
- [ADR 0008](0008-real-rate-model-artifact-export.md) — hash自己参照排除・RFC 8785正準化・atomic writeの先例
- [イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md) — 一般macro-eventレイヤー（`Scenario`/`run_scenario`/`map_event`）の責務範囲（本契約が経由しない理由）
