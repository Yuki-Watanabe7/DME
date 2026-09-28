# PNE sector-output-path 受け入れ契約（cross-model input 契約）

production-network-engine（以下 PNE）が出力する `production-network-sector-output-path/v1` を、DME が
**観測事実ではなく上流モデルの導出結果として**受理し、DME の Scenario / Applied Model Input へ変換する
ための cross-model integration contract。[Issue #280](https://github.com/Yuki-Watanabe7/DME/issues/280)
の成果物であり、実装は #281（compatibility / mapping 層）・#282（CCC adapter / 実行接続）・
#283（cross-repository fixture / provenance / replay E2E）が本書に従って行う。

> 関連: [ADR 0024](../adr/0024-pne-sector-output-cross-model-input-contract.md)（本書の決定記録）・
> [マクロイベント変換契約](macro_event_contract.md)・[イベント・シナリオ実行層 統合設計](macro_event_runtime_integration.md)
> （[ADR 0010](../adr/0010-macro-event-scenario-contract.md)・[ADR 0015](../adr/0015-macro-event-runtime-contract.md)）・
> [シナリオ時間軸の意味論](scenario_time_semantics.md)・[クロスモデル推論層の設計](cross_model_reasoning.md)
> （[ADR 0006](../adr/0006-cross-model-reasoning-contract.md)）・
> [部門別CAPEX・信用循環モデル 部門境界と変数定義](../models/capex_credit_cycle_sectors_variables.md)

---

## 0. メタ情報

| 項目 | 内容 |
|---|---|
| 文書 version | `1.0.0` |
| 本書が定める契約 version | `cross-model-input/1.0.0`（実装時に `CROSS_MODEL_INPUT_CONTRACT_VERSION` として定義する。§14） |
| ステータス | 確定（設計のみ。実装は #281・#282・#283） |
| 関連 Issue | #280（本書）・#281・#282・#283・#125（ロードマップ）・PNE #2 Phase 1.5・PNE #32（producer 契約）・PNE #33（producer fixture） |
| 上流契約（PNE 側が正本） | [`contracts/production-network-sector-output-path-v1.schema.json`](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/contracts/production-network-sector-output-path-v1.schema.json)・[`docs/sector-output-path-contract.md`](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/docs/sector-output-path-contract.md)・[PNE ADR 14](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/docs/decisions/0014-macro-boundary-is-native-sector-output-not-dynamic-state.md) |
| 参照した PNE コミット | `30beab183ef7f2387ce469ae19ad9885f9f55d71` |
| 前提 ADR | [0006](../adr/0006-cross-model-reasoning-contract.md)（概念対応の明示・同名変数の非同一視）・[0008](../adr/0008-real-rate-model-artifact-export.md)（RFC 8785 正準化・汎用 JSON Schema バリデータ不使用）・[0010](../adr/0010-macro-event-scenario-contract.md)（4 層分離・適用先 7 変数・固定順合成）・[0013](../adr/0013-capex-credit-cycle-integration-contract.md)（`SimulationResult` 非変更・metadata 予約キー）・[0015](../adr/0015-macro-event-runtime-contract.md)（失敗 3 層・status 4 値・fail closed・replay）・[0018](../adr/0018-capex-credit-cycle-empirical-runtime-contract.md)（`ext_demand_s` 分割の非識別） |

---

## 1. この文書が決めること・決めないこと

決めること。

- PNE artifact が DME 内でどの意味論上の層に属するか（§3）。
- 受理から実行までの処理段と、段ごとの責務・禁止事項（§4）。
- DME が PNE v1 artifact を受理する条件と、DME 側で再実装する検証（§5）。
- geography 互換性の fail closed 規則と 3 つの transmission mode の区別（§6）。
- どの DME モデルが PNE 由来入力を受け付けるか。CCC の受理プロファイルと、外生 7 変数ごとの判定（§7）。
- sector / classification mapping を DME consumer 側の責務とし、mapping artifact に持たせる項目（§8）。
- PNE の離散期間パスと DME の四半期時間軸の関係（§9）。
- 既存イベント実行層（#196–#205）を再利用する範囲としない範囲（§10）。
- 失敗の返し方と拒否・警告コード（§11）。
- DME 結果から PNE 入力までの provenance chain と replay 契約（§12）。
- 実装 Issue #281・#282・#283 への責務分割（§16）。

決めないこと（Issue #280 の Non-goals を継承）。

- Japan → US 等の cross-economy transmission の推定・実装。
- PNE 内部の在庫・binding input・代替・critical input 機構の DME 再実装。
- マクロパラメータの再較正、DME Phase 4 のモデル比較、企業レベル linkage、予測・投資推奨。
- 個々の mapping artifact の**内容**（どの PNE 部門をどの DME 対象へ割り当てるか・weight の数値）。本書は
  mapping artifact が満たすべき**形式と検証規則**のみを定める。

---

## 2. 前提

### 2.1 上流 artifact（PNE v1）が保証すること

PNE v1 artifact は、PNE の多期間 supply-shock シミュレーション結果を、native sector ごと・期間ごとの
**実現産出比**へ射影した独立 JSON である。DME が依拠する性質は次のとおり（正本は PNE 側の schema と
`docs/sector-output-path-contract.md`）。

| PNE フィールド | PNE が保証する内容 | DME での用途 |
|---|---|---|
| `schema_version` | `"production-network-sector-output-path/v1"` | 受理可否（§5.1） |
| `result_type_boundary` | 4 役割を固定値で分離（`source_data_with_declared_estimation_status`・`pne_scenario_assumption`・`pne_model_derived_endogenous_result`・`downstream_application = not_present`） | 意味論上の層の根拠（§3.1） |
| `status` / `unsupported_reasons` | `complete` は全期間が揃い error 警告が無いこと。`unsupported` の部分値は consumer が適用してはならない | 受理条件（§5.2） |
| `geography` / `geography_compatibility` | `(system, economy_id)` が identity。v1 は常に `mode = same_economy_only`・`explicitly_modeled_cross_economy = false`・`model_reference = null` | geography 判定（§6） |
| `classification` | `system`・`version`・`level` が必須。`sector_id` は opaque、`source_label` は `presentation_only` | classification 判定（§8） |
| `aggregation` | 常に `native_sector_path`（PNE は DME 固有の集約を行わない。coverage = 1.0） | 集約が DME 側責務であることの根拠（§8.1） |
| `time` | `period_unit`（`baseline_period`/`day`/`week`/`month`/`quarter`/`year`）・`frequency = 1`・`period_index_origin = 0`・任意の `calendar_anchor`（期 0 のラベル）・`interval_semantics = start_inclusive_end_exclusive`・`value_semantics = period_total_realized_output_ratio`・`rescaled_by_exporter = false` | 時間 mapping（§9） |
| `sectors[].periods[]` | `realized_output_ratio ∈ [0, 1]`・`output_loss_ratio = 1 − realized_output_ratio`（PNE の許容誤差 `1e-12`）・有限値 | 変換の入力値 |
| `sectors[].baseline_output` | source network が持つ場合のみ、単位つき（PNE は単位変換しない） | `:source_baseline_output` weight（§8.3） |
| `sectors[].source_data_status` | `observed`/`estimated`/`inferred`/`synthetic` | hypothetical override の条件（§6.3）・警告 |
| `source` | `source_input_hash`・`dynamic_artifact_id`/`_hash`・`scenario_hash`・`scenario_policy_hash`・`scenario_config_hash`・`export_config_hash`・`network_id` | provenance chain（§12） |
| `source_provenance` | `is_synthetic`・`network_as_of`・推定ステータス件数・参照 | 同上・警告 |
| `producer` | engine / algorithm / exporter の version | provenance chain |

PNE が**保証しない**こと: DME の部門・頻度・経済圏への適合、DME の変数との対応、cross-economy transmission、
価格・金融条件、需要側の反応（PNE は supply-constraint の下流伝播モデルであり、上流への需要減少を
モデル化しない）。これらはすべて DME 側の判断であり、本書がその規則を定める。

### 2.2 DME 側で本書が変更しないもの

| 対象 | 状態 |
|---|---|
| 4 層（`MACRO_EVENT_LAYERS`）・イベント型 10 種（`MACRO_EVENT_TYPES`）・target concept 語彙・拒否コード 12 種・警告コード 12 種 | **変更しない** |
| `ObservedEvent`・`InterpretedSignal`・`ScenarioAssumption`・`AppliedModelInput`・`EventProvenance`・`PersistenceSpec` の型 | **変更しない**（`AppliedModelInput` は再利用する。§10.3） |
| `Scenario`・`ScenarioRun`・`run_scenario`・`map_event`・`schedule_events`・`compose_exogenous_paths` | **変更しない** |
| `scenario.json`（`dme.scenario/1.0.0`）・`event_set_hash`・`scenario_content_hash`・`save_scenario_artifact`・`load_scenario`・`replay_scenario` | **変更しない** |
| `CapexCreditCycleModel`・`exogenous_variables`（7 変数）・`capex_run`・`SimulationResult` | **変更しない** |
| 実証層（catalog → … → historical replay、ADR 0018） | **変更しない**。PNE 由来入力は実証層の観測入力にならない |

### 2.3 なぜ直接接続できないか

| 軸 | PNE 現状 | DME（CCC）現状 | 直接接続した場合の誤り |
|---|---|---|---|
| 結果の性質 | シナリオ条件付きのモデル導出結果 | Observed Event → … → Applied Model Input の 4 層 | 観測事実として event registry へ入れると、`L1` の「観測された事象」という意味が壊れる |
| geography | 日本（2020 IO） | 米国（[分析契約](../models/capex_credit_cycle_analysis_contract.md) の基準経済） | 日本の供給ショックを米国へ直接投入すると、推定していない cross-border transmission を主張することになる |
| 部門 | 108 部門（統合中分類）・opaque id | 5 部門（`S1`–`S5`） | ラベルの類似で対応付けると、分類体系の違いが隠れる |
| 時間 | 期間 = network の baseline 期間（real profile は年次 IO） | 四半期（`Δt = 0.25` 年） | 年次比を四半期へ按分すると、測定されていない季節・期内プロファイルを作る |
| 量 | 部門の**実現産出**の baseline 比（供給側の結果） | 外生 7 変数（需要期待・計画・スプレッド・政策金利・モデル外需要・価格） | 供給制約の結果を需要変数へ入れると、供給ショックを需要ショックとして扱う代理になる |

---

## 3. 意味論上の層（Issue #280 Scope 1）

### 3.1 PNE artifact の各部分の DME 内での位置づけ

| PNE の内容（`result_type_boundary`） | DME での位置づけ | 扱い |
|---|---|---|
| network baseline・ラベル・provenance（`source_data_with_declared_estimation_status`） | 上流モデルの**入力データ**。DME の観測データではない | `UpstreamModelArtifactRef` の provenance 要約として参照のみ保持する。DME の `DataSeries` / 実証層へ入れない |
| shock path などの分析者選択（`pne_scenario_assumption`） | **上流側の**シナリオ仮定 | DME の `ScenarioAssumption` へ写さない。`scenario_hash` 等で参照する |
| 部門産出・損失パス（`pne_model_derived_endogenous_result`） | **upstream model-derived scenario result** | 本書の変換対象。DME 側で明示的に採用・mapping したときに限り、`ModelDerivedInput` を経て `AppliedModelInput` になる |
| DME mapping・頻度変換・マクロ応答（`downstream_application = not_present`） | DME の責務 | 本書 §8–§10 |

### 3.2 4 層との関係

PNE の産出パスは次のいずれでもない。

- **Observed Event（`L1`）ではない**: 観測された事象ではなく、PNE のシナリオ仮定の下で計算された反実仮想である。
- **Interpreted Signal（`L2`）ではない**: 観測事実を解釈した belief ではない。解釈すべき観測が存在しない。
- **event 由来の Scenario Assumption（`L3`、`ScenarioAssumption`）ではない**: 分析者がイベントに対して置いた
  仮定ではなく、`event_type`（10 種）・`magnitude_source` のいずれにも正しく当てはまらない。

DME は PNE の結果を**第 5 の層として追加しない**。代わりに、`L3` と同じ位置（「シナリオへ入れる入力の仮定」）
に**出自の異なる兄弟型** `ModelDerivedInput` を置き、`L4`（`AppliedModelInput`）で両者が合流する。

```text
            event 由来（既存・変更なし）                     上流モデル由来（本書）
  L1 ObservedEvent                                  PNE sector-output-path/v1（JSON artifact）
      │ interpret                                        │ ingest（§5）→ UpstreamModelArtifactRef
  L2 InterpretedSignal                                   │ compatibility（§6・§8・§9）+ mapping artifact
      │ assume                                           │ apply mapping（§8・§9）
  L3 ScenarioAssumption          ◀─ 兄弟 ─▶      ModelDerivedInput（input_origin = :upstream_model_derived）
      │ map_event（CCC、既存）                            │ map_model_derived_input（CCC、#282）
      └──────────────▶  L4 AppliedModelInput（共通・型は変更しない） ◀──────────────┘
                              │ schedule_events / compose_exogenous_paths（既存の固定順合成）
                              ▼
                        capex_run → SimulationResult（metadata に両系統の provenance）
```

「PNE の結果が DME のシナリオ仮定になる」のは、DME 側の分析者が **mapping artifact を用意し、その
`ModelDerivedInput` を実行に含めると明示的に選んだとき**に限られる。この選択が DME 側の仮定であり、
PNE の結果そのものを DME の仮定と同一視しない。

### 3.3 新しい generic 型（実装は #281・#282）

**`UpstreamModelArtifactRef`**（#281）: 上流 artifact の identity と provenance の参照。値パスは持たない。

| フィールド | 内容 |
|---|---|
| `producer` / `producer_version` / `exporter_version` / `algorithm_versions` | PNE の `producer` をそのまま写す |
| `contract_version` | `"production-network-sector-output-path/v1"` |
| `artifact_id` | PNE が付与した `artifact_id`（DME は導出式を再計算しない。§5.3） |
| `content_hash` | DME が計算する RFC 8785 正準 JSON の SHA-256（`"sha256:…"`。§5.3） |
| `source_bytes_sha256` | 読み込んだバイト列の SHA-256。ファイルから読んだ場合のみ。**hash 対象外**（監査用） |
| `network_id`・`source_input_hash`・`dynamic_artifact_id`・`dynamic_artifact_hash`・`scenario_hash`・`scenario_policy_hash`・`scenario_config_hash`・`export_config_hash` | PNE `source` の値を**再計算せず**そのまま写す |
| `geography`（`system`・`economy_id`）・`classification`（`system`・`version`・`level`） | PNE の identity をそのまま写す |
| `is_synthetic`・`network_as_of`・`estimation_status_counts` | PNE `source_provenance` の要約 |
| `result_role` | `:upstream_model_derived_endogenous_result`（固定値） |

**`ModelDerivedInput`**（#282）: 上流モデル由来の、特定 DME モデル向けに mapping 済みの入力。`L3` と同じ
位置に置くが `ScenarioAssumption` ではなく、**`AbstractMacroEvent` の subtype にしない**（`map_event`・
`validate_event`・`observed_events.json` の経路へ入れない。ADR 0015 決定 3 の型による層分離を維持する）。

```julia
struct ModelDerivedInput
    input_id::String                 # "xm-" 接頭辞（§10.4）
    input_origin::Symbol             # :upstream_model_derived（固定）
    upstream::UpstreamModelArtifactRef
    mapping_id::String
    mapping_version::String
    mapping_hash::String             # "sha256:…"（§8.2）
    compatibility_report_hash::String
    target_model::Symbol             # model_symbol（例 :capex_credit_cycle）
    target_concept::Symbol           # 例 :derived_out_of_model_demand（§7.4）
    target_group::Symbol             # 例 :ext_demand_s2_customers
    value_semantics::Symbol          # 例 :target_relative_change（§8.3）
    values::Vector{Float64}          # DME 四半期 k = 0..Q-1 ごとの値（§9）
    timing_basis::Symbol             # :calendar / :period（§9.5）
    anchor_quarter::Union{CalendarQuarter,Nothing}
    t_start::Union{Int,Nothing}      # :period 基準でのみ指定
    post_horizon::Symbol             # :recovered_at_source_horizon_end（v1 唯一値、§9.6）
    transmission_mode::Symbol        # §6.2
    claim_scope::Symbol              # §13
    coverage::Dict{String,Any}       # covered_share・uncovered_share・members・producer_set（§8.4）
    notes::String                    # hash 対象外
end
```

実装はフィールドを追加してよいが、上表・上記の情報を削ってはならない。

### 3.4 不変条件

| ID | 不変条件 | 担保の手段 |
|---|---|---|
| `UM-1` | PNE 由来の値は `ObservedEvent`・`InterpretedSignal`・`ScenarioAssumption` のいずれにもならない | `ModelDerivedInput` を `AbstractMacroEvent` の subtype にしない。変換関数を提供しない |
| `UM-2` | PNE 由来の値は DME の観測データ（`DataSeries`・実証層の raw observation / measurement）にならない | 実証層の API へ渡す経路を作らない |
| `UM-3` | `MACRO_EVENT_LAYERS`・`MACRO_EVENT_TYPES`・`MACRO_EVENT_REJECTION_CODES`・`MACRO_EVENT_WARNING_CODES` を変更しない | cross-model 側は独立した語彙を持つ（§11） |
| `UM-4` | PNE の結果は DME 側の mapping artifact と明示的な採用がなければモデルへ適用されない | `ModelDerivedInput` は compatibility report が `accepted` の場合にしか構築できない |
| `UM-5` | 部門ラベル・経済圏の名称（`name`・`source_label`）を対応付けの根拠にしない | 比較は `(system, economy_id)`・`(system, version, level)`・`sector_id` の完全一致のみ |
| `UM-6` | 欠損・対応不能・範囲外を 0 ショック・baseline 値・近い変数で埋めない | §8.4・§9.4・§9.6・§7.3 |
| `UM-7` | PNE 由来の結果であることが `AppliedModelInput` → `SimulationResult` まで失われない | provenance chain（§12）と metadata 予約キー（§12.3） |
| `UM-8` | PNE を DME の実行時依存にしない（Python package を import しない。PNE の検証を呼ばない） | DME が JSON を読み、PNE の意味論的不変条件を Julia で再実装する（§5.2。ADR 0008 と同じ doctrine） |

---

## 4. 処理段と責務境界

処理は一方向であり、後段は前段の出力を書き換えない。

| 段 | 名称 | 入力 | 出力 | 責務 Issue | 禁止事項 |
|---|---|---|---|---|---|
| `X0` | 生成（PNE 側） | PNE dynamic artifact + export config | PNE v1 artifact | PNE #32・#33 | （DME の責務外） |
| `X1` | 受理 | JSON bytes / Dict | `PNESectorOutputPath` + `UpstreamModelArtifactRef` | #281 | PNE package の import・値の補正・未知キーの無視 |
| `X2` | 互換性判定 | `X1` + mapping artifact + target profile | `CrossModelCompatibilityReport` | #281 | 1 件目の失敗で打ち切ること（全件を列挙する）・ラベル照合 |
| `X3` | mapping 適用 | `X1` + mapping artifact + accepted report | `MappedGroupPath`（target group ごとの DME 四半期パス） | #281 | 欠損の 0 埋め・weight の再正規化（`:declared_target_share`）・部分四半期の按分 |
| `X4` | `ModelDerivedInput` 構築 | `X3` + 時点配置 | `ModelDerivedInput` | #282 | 経済圏・部門・頻度の再判定の省略 |
| `X5` | モデル固有 mapping | `ModelDerivedInput` + モデル | `AppliedModelInput` または `CrossModelRejection` | #282 | `exogenous_variables(m)` 外への適用・代理変数への寄せ |
| `X6` | 実行 | `Scenario` + `ModelDerivedInput` 集合 | `CrossModelScenarioRun` | #282 | `run_scenario` の変更・イベント由来入力と拒否コードの混同 |
| `X7` | 保存・replay | `X6` | 成果物・replay 結果 | #282（保存）・#283（E2E・drift） | PNE bytes への replay 依存・環境依存値 |

---

## 5. 受理（ingestion）契約

### 5.1 受理する schema version

`schema_version == "production-network-sector-output-path/v1"` の完全一致のみを受理する
（`PNE_SECTOR_OUTPUT_PATH_ACCEPTED_SCHEMA_VERSIONS = ("production-network-sector-output-path/v1",)`）。
それ以外は例外（`unsupported_upstream_schema_version`）。PNE v2 の受理は DME 側の実装変更と本書・ADR 0024
の改訂を要する。**同一 version に黙って breaking change を入れない**ことは PNE 側の契約であり、DME は
vendor copy した schema と fixture の hash で drift を検出する（§15・#283）。

### 5.2 DME が再実装する検証

DME は汎用 JSON Schema バリデータを内蔵しない（ADR 0008 と同じ）。PNE schema の制約と
`x-semantic-invariants` を Julia で個別に再実装する。**以下の違反は「そのような artifact は存在しえない」
（層(1)）ため、decode 時の例外（`ArgumentError`、メッセージ先頭にコード）とする**（`scenario_from_dict`
の fail closed decode と同型）。

| 検査 | 規則 |
|---|---|
| キー集合 | 各オブジェクトで必須キーの欠落・**未知キー**（schema は全階層 `additionalProperties: false`）を拒否 |
| 固定値 | `result_type_boundary` の 4 値・`aggregation.status = native_sector_path`（他 5 項目は `null` / `coverage = 1.0`）・`time.frequency = 1`・`period_index_origin = 0`・`interval_semantics`・`value_semantics`・`rescaled_by_exporter = false`・`geography_compatibility.mode = same_economy_only`・`explicitly_modeled_cross_economy = false`・`model_reference = null`・`classification.sector_id_semantics = opaque`・`source_label_semantics = presentation_only`・`aggregate_path_definition` の 4 値・`producer.engine` |
| 閉じた語彙 | `status`・`period_unit`・`source_data_status`・`severity`・warning `source` |
| 識別子形式 | `sector_id`・`economy_id`・`artifact_id` 等の pattern、hash の `^sha256:[0-9a-f]{64}$` |
| 数値 | すべて有限（NaN・Infinity・文字列 `"NaN"` を拒否）。`realized_output_ratio`・`output_loss_ratio ∈ [0, 1]` |
| 損失比 | `output_loss_ratio` と `1 − realized_output_ratio` の差の絶対値が `1e-12` 以下（PNE と同じ許容誤差 `PNE_RATIO_ABS_TOL`） |
| 部門 | `sector_id` が一意かつ昇順（opaque 文字列の辞書順） |
| 期間被覆 | 各部門・`aggregate_path` が `period_index = 0 … available_periods − 1` をちょうど 1 回ずつ昇順で持つ |
| status 整合 | `complete` ⇒ `unsupported_reasons` が空かつ `available_periods = horizon_periods`。`unsupported` ⇒ `unsupported_reasons` が 1 件以上 |
| geography 整合 | `geography_compatibility.compatible_economy_ids == [geography.economy_id]` |

decode に成功した artifact でも、次は**構造化拒否**（§11、互換性判定 `X2` の段）とする。値として存在し
うるが、DME が適用してはならないためである。

- `status = unsupported`（`upstream_status_unsupported`。部分値は診断用にのみ保持し、適用しない）。
- `warnings` に `severity = error` が含まれる（`upstream_error_warning`。v1 では `complete` と両立しない
  はずだが、DME 側でも独立に検査する）。

`info` / `warning` severity の PNE 警告は `upstream_warning_carried` として DME の警告へ転記する（§11.3）。
`aggregate_path` は検証するが、v1 ではいかなるモデル入力にも用いない（§7.1）。

### 5.3 identity（3 種の識別子）

| 識別子 | 計算 | hash 対象 | 用途 |
|---|---|---|---|
| `artifact_id` | PNE が付与（DME は再計算しない） | 対象 | PNE 側の成果物との突合 |
| `content_hash` | parse 後の文書全体を DME の RFC 8785 正準化（`canonical_json_bytes`）で直列化した SHA-256 | 対象 | **DME 内での上流 artifact の正本 identity**。mapping・`ModelDerivedInput`・provenance が参照する |
| `source_bytes_sha256` | 読み込んだファイルのバイト列の SHA-256 | **対象外** | 監査・vendor fixture の drift 検出（#283） |

**決定**: DME は PNE 自身の `hash_document`（Python の compact JSON + 12 桁丸め + Python の float 表記）を
再計算しない。その規則は PNE の実装詳細であり、Julia で float 表記まで再現すると PNE 内部への結合になる。
PNE の `artifact_id` の導出式（`sop-` + dynamic hash 等の SHA-256 接頭辞）も同じ理由で検証しない。
PNE が将来 artifact 自身の hash を契約フィールドとして公開した場合は、DME はそれを照合する version を
追加する。

---

## 6. geography 互換性（Issue #280 Scope 3）

### 6.1 identity と比較規則

- geography の identity は `(system, economy_id)` の**完全一致**のみで判定する。大文字小文字の正規化・
  別名表・`name` の比較を行わない（`name` は presentation only）。
- DME 側の経済圏は **target model profile** が宣言する（`CrossModelTargetProfile`、§7.2）。CCC は
  `(system = "ISO 3166-1 alpha-2", economy_id = "US")`。これは CCC の[分析契約](../models/capex_credit_cycle_analysis_contract.md)
  の基準経済（米国）を識別子にしたものであり、CCC が米国に較正済みであることを意味しない。
- mapping artifact は `source_geography` と `target_geography` を**明示的に宣言**し、validator はそれぞれを
  PNE artifact・target profile と照合する（宣言と実体の不一致は `geography_declaration_inconsistent`）。
  mapping 作成者が経済圏の組を意識せずに mapping を書けない形にする。

### 6.2 transmission mode

mapping artifact の `transmission.mode` は次の 3 値のいずれかであり、既定値を持たない（省略は拒否）。

| mode | 意味 | v1 での扱い |
|---|---|---|
| `:same_economy` | source と target が同一経済圏。PNE の結果をその経済のモデルへ入れる | geography identity が完全一致する場合のみ受理 |
| `:explicit_cross_economy` | 別途 version 管理された transmission artifact / model が、source 経済のショックを target 経済へ伝える | **受理先なし**（§6.4）。常に `cross_economy_transmission_unavailable` |
| `:hypothetical_override` | 実在経済間の伝播を主張せず、架空の入力として target モデルへ入れる | synthetic source に限り受理（§6.3） |

判定表（`X2` 段。geography 以外の判定と独立に全件評価する）。

| source identity と target identity | 宣言 mode | 結果 |
|---|---|---|
| 一致 | `:same_economy` | 受理（`claim_scope = :same_economy_model_derived`） |
| 一致 | `:hypothetical_override` / `:explicit_cross_economy` | 拒否 `transmission_mode_inconsistent`（同一経済圏に override / 伝播を宣言しない） |
| 不一致 | `:same_economy` | 拒否 `geography_mismatch` |
| 不一致 | `:explicit_cross_economy` | 拒否 `cross_economy_transmission_unavailable` |
| 不一致 | `:hypothetical_override`、source が synthetic（§6.3） | 受理（`claim_scope = :hypothetical_fictional`、警告 `hypothetical_transmission`） |
| 不一致 | `:hypothetical_override`、source が synthetic でない | 拒否 `hypothetical_override_requires_synthetic_source` |

### 6.3 `:hypothetical_override` の条件

次の**すべて**を満たす場合に限る。

1. `source_provenance.is_synthetic == true`。
2. すべての部門の `source_data_status == synthetic`。
3. mapping artifact の `transmission.justification` が空でない（何のための架空入力かを記録する）。

実データ（`observed`/`estimated`/`inferred` を 1 つでも含む）の artifact に override を許さない。
実データの結果を別経済のモデルへ入れた数値は、`hypothetical` と表示しても「その経済のショックがこの経済へ
及ぼす影響」と読まれ、本 Issue が推測しないと決めた cross-border transmission の主張になるためである。
実データを用いた仮想シナリオが必要になった場合は、claim scope と表示義務を定める別 ADR を要する。

### 6.4 `:explicit_cross_economy` の条件（v1 では受理先なし）

cross-economy transmission を受理するには、少なくとも次を持つ transmission artifact が必要である。

- 独自の contract version・artifact id・content hash。
- source economy・target economy・target model の identity。
- 伝播の機構（貿易・価格・為替・サプライチェーンのいずれか）と根拠（evidence）の参照。
- source artifact（PNE）の `content_hash` への参照。

v1 では**受理する transmission contract version の集合を空**とする
（`ACCEPTED_CROSS_ECONOMY_TRANSMISSION_CONTRACTS = ()`）。mapping artifact が
`transmission.transmission_ref` を持つ場合、validator はその identity（source / target economy が実体と
一致するか）を検査したうえで、version が集合に無いため `cross_economy_transmission_unavailable` として
拒否する。これにより「伝播 artifact が無い」（`geography_mismatch`）と「伝播 artifact はあるが未対応」を
区別して報告できる。集合へ version を加えるには ADR 0024 の改訂を要する。PNE v1 の
`geography_compatibility.explicitly_modeled_cross_economy` は常に `false` であり、PNE 側もこの経路を
提供していない。

### 6.5 現行 Japan-PNE → US-CCC の扱い

現行の PNE real profile（日本 2020 IO・統合中分類 108 部門・`is_synthetic = false`）を CCC（US）へ
入れる mapping は、どの mode を宣言しても拒否される。

| 宣言 mode | 拒否コード |
|---|---|
| `:same_economy` | `geography_mismatch` |
| `:explicit_cross_economy` | `cross_economy_transmission_unavailable` |
| `:hypothetical_override` | `hypothetical_override_requires_synthetic_source` |

この 3 件を #283 の negative golden として固定する。**positive E2E を通すために geography guard を弱めない**
（テスト用に CCC の target profile の経済圏を差し替える経路を作らない。§15）。

---

## 7. target model の選定（Issue #280 Scope 2）

### 7.1 モデル別判定（v1）

| model | 判定 | 理由 |
|---|---|---|
| `:capex_credit_cycle`（CCC） | **限定的に受理**（§7.2–§7.4） | 部門次元と、モデル外需要の外生入力 `ext_demand_s2` / `ext_demand_s3` を持つ。受理するのは派生中間需要チャネル 1 種のみ |
| `:ramsey`・`:rbc`・`:solow`・`:keen` | `unsupported_target_model` | 1 部門の集計モデルで部門次元を持たない。PNE の `aggregate_path` は供給網伝播を経た**内生的な実現産出比**であり、TFP・生産性・資本といったモデルのプリミティブではない。プリミティブへ写すと「結果」を「原因」として再度モデルへ通す代理になる |
| `:adas`・`:new_keynesian` | `unsupported_target_model` | 同上（集計の供給ショック／コストプッシュへ写すと、実現産出比を外生ショックの大きさとして扱う代理になる。PNE は価格を出力しない） |
| `:islm`・`:mundell_fleming`・`:sim` | `unsupported_target_model` | 供給側（産出能力）を外生入力として持たない |
| `:var` | `unsupported_target_model` | 構造識別を持たない誘導形であり、外生ショックの入口が定義されない |

`unsupported_target_model` は「v1 の mapping registry に行が無い」ことを示す。将来の受理は、そのモデル向けの
mapping registry・target profile・ADR 0024 の改訂を要する。

### 7.2 CCC の受理プロファイル

`CrossModelTargetProfile`（#281 が定義し、v1 は CCC の 1 件のみ登録する）。

| 項目 | CCC の値 |
|---|---|
| accepted input dimension | target group 単位の 1 本の四半期パス。target group は `:ext_demand_s2_customers`・`:ext_demand_s3_customers` の 2 種 |
| accepted target concept | `:derived_out_of_model_demand` のみ（§7.4） |
| aggregation requirement | many-to-one。weight basis は `:declared_target_share` のみ（`:source_baseline_output`・`:direct_one_to_one` は `weight_basis_not_allowed`）。weight は再正規化しない（§8.3） |
| value semantics | `:target_relative_change`（target 変数の baseline に対する相対変化、`≤ 0`） |
| units | 無次元比 → `AppliedModelInput` の `unit = "%"`・`application_mode = :multiplicative`。PNE の `baseline_output`（例: JPY billion）を DME の単位（`bn USD (2017 chained)`）へ**換算しない** |
| frequency | 四半期。source の `period_unit` は `quarter` と `month` のみ受理（§9.1） |
| geography | `("ISO 3166-1 alpha-2", "US")`。§6 の規則に従う |
| mapping method | `:derived_intermediate_demand_fixed_coefficients`（§7.4） |
| unsupported reason | §7.3 の表の各行 |
| profile version | `cross-model-target-profile/1.0.0` |

### 7.3 CCC 外生 7 変数ごとの判定

CCC の適用先は `exogenous_variables(m)` の 7 変数に限る（[マクロイベント変換契約](macro_event_contract.md) §4.1）。
PNE 由来入力の適用先をこの外へ広げない。

| # | 外生変数 | PNE 由来入力 | 判定 | 理由 |
|---|---|---|---|---|
| 1 | `ai_exp` | — | `unmapped_target_concept` | AI 需要・収益**期待**の指数。供給網の実現産出比は期待ではない |
| 2 | `capex_plan_shock_ex` | — | `unmapped_target_concept` | `S1` の計画 CAPEX の外生シフト（意思決定）。資本財の供給制約は CCC 内で受注残・出荷を通じて内生的に扱われるものであり、計画改定へ写すと供給制約を需要側の意思決定として扱う代理になる |
| 3 | `spread_shock_ex` | — | `unmapped_target_concept` | 金融条件。PNE は金融変数を出力しない |
| 4 | `policy_rate` | — | `unmapped_target_concept` | 同上 |
| 5 | `ext_demand_s2` | 派生中間需要（`:ext_demand_s2_customers`） | **条件付き受理** | モデル外顧客（スマートフォン・自動車等）の `S2` 製品需要。固定係数の下で、顧客部門の実現産出の低下は投入需要の同率の低下を意味する（§7.4） |
| 6 | `ext_demand_s3` | 派生中間需要（`:ext_demand_s3_customers`） | **条件付き受理** | 同上（`S3` 製品：製造装置・建設・電力設備） |
| 7 | `price_s1` | — | `unmapped_target_concept` | PNE は価格を出力しない |
| — | `S1`–`S3` 自身の供給能力（例: 半導体部門の産出制約） | `:sector_supply_capacity` | `unmapped_target_concept`（gap `PG-01`） | CCC は供給能力の外生入力を持たない（`ycap_s = cap_s[t−1] / st_cor_s` は内生）。`ext_demand_s`・`capex_plan_shock_ex` への代理を**禁止**する |
| — | `S5` 等の部門産出・総産出 | `:aggregate_realized_output` | `unmapped_target_concept` | `y_s`・`y_s5` は内生変数であり、外生入力で上書きするとモデルの解を置き換えることになる |

`unmapped_target_concept` は「CCC が構造上その概念を表現しない」ことを意味し、「影響が無い」ことを
意味しない（[マクロイベント変換契約](macro_event_contract.md) §4.5 と同じ規律）。

### 7.4 派生中間需要チャネル（`:derived_out_of_model_demand`）

**定義**: PNE の顧客部門 `j`（CCC のモデル外顧客）の実現産出比 `r_j(q)` が 1 を下回るとき、固定投入係数の下で
`j` の `S`（`s ∈ {s2, s3}`）製品への需要も同率で下がる。target group `g` の値は

```text
v_g(q) = − Σ_{j ∈ members(g)} w_j · (1 − r_j(q))          （:target_relative_change、v_g(q) ∈ [−Σw_j, 0]）
AppliedModelInput.values(q) = 100 · v_g(q)                  （unit = "%"、:multiplicative）
ext_demand_s(q) = ext_demand_s^{baseline}(q) · (1 + values(q)/100)
```

ここで `w_j` は **target 変数の baseline（`ext_demand_s^{ss}`）のうち顧客 `j` の購入が占める割合**
（`:declared_target_share`）であり、`Σ w_j ≤ 1`。`r_j(q)` は §9 の時間集約後の四半期値である。

**受理条件**（すべて満たさない場合は拒否。validator が機械的に検査するものと、mapping artifact の宣言として
記録するものを区別する）。

| ID | 条件 | 検査 |
|---|---|---|
| `DD-1` | geography が §6 で受理されている | 機械的 |
| `DD-2` | classification identity が完全一致（§8.5） | 機械的 |
| `DD-3` | group の `target_concept = :derived_out_of_model_demand`・`target_group ∈ {:ext_demand_s2_customers, :ext_demand_s3_customers}` | 機械的 |
| `DD-4` | weight basis が `:declared_target_share`。各 `w_j` は有限かつ `> 0`、`Σ w_j ≤ 1`、`weight_provenance`（出所・version・算出方法）が空でない | 機械的（数値）+ 宣言（出所） |
| `DD-5` | members は **CCC がモデル化していない顧客**である（`S1` の AI 用資本財需要・`S2`/`S3` 相互の投資需要・`S5` の一般需要 `L50` に当たる購入を含めない） | 宣言（`customer_scope = :out_of_model` と根拠）。`ext_demand_s` と `order_gen_s` の分割は識別されない（[ADR 0018](../adr/0018-capex-credit-cycle-empirical-runtime-contract.md) 決定 7）ため、この宣言は**識別仮定**として provenance に記録する |
| `DD-6` | target 製品の**生産部門集合**（producer set。PNE 上で `S2`/`S3` 製品を生産する部門）を宣言し、producer set の全部門が**全期間で `realized_output_ratio` が 1 との差 `≤ 1e-12`** であること | 機械的（`own_supply_constraint_present`）。producer set が空の場合は `producer_set_absent_reason` を必須とし警告 `producer_set_absent` |
| `DD-7` | members と producer set は互いに素 | 機械的（`duplicate_sector_assignment`） |
| `DD-8` | 時間 mapping（§9）が受理され、PNE horizon 末で members が回復している（§9.6） | 機械的 |

**`DD-6` の理由**: PNE は供給制約の下流伝播モデルである。PNE のショックが `S2` 製品の生産部門自身に
かかっていると、顧客 `j` の産出低下は「`S2` 製品が手に入らなかった」ことの結果であり、`j` の `S2` 製品
**需要**の低下ではない。これを `ext_demand_s2` の低下として入れると、`S2` の供給制約を `S2` の需要減少
として扱う代理（§7.3 で禁止したもの）を裏口から行うことになる。producer set の産出が baseline のまま
であれば、`S2` 製品の供給は制約されておらず、顧客の産出低下は他の投入の不足によるものであるため、
固定係数の下での派生需要として読める。producer set の宣言が完全であることは DME からは検証できない
（`sector_id` は opaque）ため、宣言として記録する（gap `PG-06`）。

**baseline 参照**: `AppliedModelInput.baseline_values` は CCC の定常状態の外生パス（`run_scenario` と
同じ `_ccc_baseline_exog(m, n)` の該当キー）。`:multiplicative` は同一時点の baseline 値に対する比として
解釈する（`Y-05`）。`ext_demand_s ≥ 0` は `1 + values/100 ≥ 1 − Σw_j ≥ 0` により常に満たされる。

**符号**: `values(q) ≤ 0`。正の値は入力の不変条件違反（例外）。

### 7.5 gap register

| ID | gap | 帰結 | 解消に必要なもの |
|---|---|---|---|
| `PG-01` | CCC に供給能力の外生入力が無い | PNE の最も直接的な用途（CCC 対応部門そのものの供給制約）を CCC へ入れられない | CCC のモデル変更と ADR（#282 の Non-goal「新しい CCC 外生変数の追加」の外） |
| `PG-02` | CCC の経済圏（US）の PNE real profile が存在しない | 実データでの positive path が現時点で存在しない | US（または CCC と同一経済圏）の IO profile を PNE 側で整備すること |
| `PG-03` | cross-economy transmission 契約が存在しない | Japan-PNE を US-CCC へ入れる正当な経路が無い | §6.4 の条件を満たす transmission 契約と ADR |
| `PG-04` | `ext_demand_s` の顧客別構成が識別されない | `:declared_target_share` の weight は推定値ではなく識別仮定 | `ext_demand_s` の顧客別観測（DME 実証層の対象外） |
| `PG-05` | source `period_unit` の `day`・`week` を受理しない | 日次・週次 profile の PNE 結果を使えない | 週が四半期境界を跨ぐことの扱い・日数規約を定める version 追加。`year`・`baseline_period` は原理的に受理しない（§9.1） |
| `PG-06` | producer set の完全性を DME が検証できない | `DD-6` は宣言された producer set についてのみ成立する | PNE 側が binding input・供給元の情報を bridge 契約へ含めること（PNE ADR 14 の境界の変更を伴う） |
| `PG-07` | PNE は価格・金融条件を出力しない | CCC の `price_s1`・`spread_shock_ex`・`policy_rate` へは原理的に適用しない | （gap ではなく設計上の境界） |
| `PG-08` | CCC 以外の 10 モデルを v1 で受理しない | §7.1 | モデルごとの registry と ADR |
| `PG-09` | DME は PNE の `hash_document` 値を再計算しない | 上流 artifact の identity は DME 側 `content_hash` と PNE の `artifact_id` で追跡する | PNE が自身の hash を契約フィールドとして公開すること |
| `PG-10` | PNE horizon 末で未回復のパスを適用しない | 恒久的な損失（horizon 後も続く供給制約）を CCC へ入れられない | horizon 後の持続仮定を明示する規則と version 追加（§9.6） |
| `PG-11` | 部分四半期を受理しない | PNE を月次で実行する場合、四半期初日に anchor し horizon を 3 の倍数にする必要がある | 部分四半期の扱いを定める version 追加（§9.4） |

---

## 8. sector / classification mapping 境界（Issue #280 Scope 5）

### 8.1 責務の所在

- PNE → DME の部門対応・集約・weight の決定は **DME consumer 側の責務**である。PNE v1 は
  `aggregation.status = native_sector_path` であり、DME 固有の集約を行わない（PNE ADR 14）。DME は mapping を
  PNE 側へ押し戻さない（PNE の export config へ DME の部門を持ち込まない）。
- mapping は **DME が所有する versioned な mapping artifact**（`dme.cross-model-mapping/1.0.0`）として
  宣言する。LLM による自動生成・ラベル類似による推定を行わない。

### 8.2 mapping artifact の必須項目

| キー | 内容 |
|---|---|
| `schema_version` | `"dme.cross-model-mapping/1.0.0"` |
| `mapping_id` / `mapping_version` | 識別子と version |
| `source_contract` | `"production-network-sector-output-path/v1"` |
| `source_geography` / `target_geography` | `{system, economy_id}`（§6.1） |
| `source_classification` | `{system, version, level}` |
| `target_model` / `target_model_mapping_version` | 例 `"capex_credit_cycle"` / `"ccc-cross-model-mapping/1.0.0"` |
| `transmission` | `{mode, justification, transmission_ref}`（§6.2–§6.4。`justification` は override で必須、`transmission_ref` は `:explicit_cross_economy` で必須・他で `null`） |
| `groups[]` | target group ごとに `{target_group, target_concept, weight_basis, members: [{sector_id, weight}], producer_set: [sector_id], producer_set_absent_reason, customer_scope, weight_provenance: {source, version, method, data_hash}, identifying_assumptions: [String]}` |
| `declared_unmapped_source_sectors` | どの group にも属さない（member でも producer set でもない）PNE 部門の**明示リスト** |
| `time` | `{expected_source_period_unit, target_frequency: "quarter", aggregation_rule, partial_quarter: "reject", post_horizon: "require_recovered"}`（§9） |
| `assumptions` | mapping 作成上の仮定（自由記述の配列） |
| `notes` | 自由記述（**hash 対象外**） |

`mapping_hash` は `notes` を除く全キーの RFC 8785 正準 JSON の SHA-256（`"sha256:…"`）とする。mapping artifact
自身は hash フィールドを持たない（自己参照を排除する。ADR 0008・0022 と同型）。配列は `sector_id` / `target_group`
の昇順に整列してから hash する（整列はエンコーダの責務）。

### 8.3 weight basis と値の意味

| weight basis | weight の意味 | 正規化 | 群の値（`value_semantics`） | 必要データ |
|---|---|---|---|---|
| `:source_baseline_output` | PNE の `baseline_output` | 群内で和 1 に正規化 | `:group_realized_output_ratio` = `Σ_j (B_j / Σ_k B_k) · r_j` | 全 member に `baseline_output` があり単位が完全一致。欠ければ `baseline_output_missing` / `baseline_output_unit_mismatch`（**非加重平均へ落とさない**。PNE の `aggregate_path` と同じ方針） |
| `:direct_one_to_one` | member 1 件、weight 1 | — | `:group_realized_output_ratio` = `r_j` | member がちょうど 1 件 |
| `:declared_target_share` | target 変数の baseline のうち member が占める割合 | **再正規化しない**（`Σ w_j ≤ 1`） | `:target_relative_change` = `−Σ_j w_j (1 − r_j)` | `weight_provenance` 必須 |

`:group_realized_output_ratio` は PNE の産出比と同じ量（群の実現産出の baseline 比）であり、#281 の generic
層が提供する。v1 の CCC はこれを受理しない（§7.3。供給側の産出比を適用する外生変数が無い）。

`:declared_target_share` で再正規化しない理由: 再正規化（`Σ w_j` で割る）は、カバーされない需要が
カバーされた顧客と同じ率で変化すると仮定することに等しく、PNE が何も述べていない部分へ結果を外挿する。

### 8.4 coverage と unmapped の扱い

| 概念 | 定義 | 扱い |
|---|---|---|
| unmapped source sector | どの group の member でも producer set でもない PNE 部門 | 入力に用いない（0 としても 1 としても使わない）。実際の集合が `declared_unmapped_source_sectors` と一致しなければ `unmapped_sector_undeclared` で拒否。0 件でなければ警告 `unmapped_source_sectors_present` |
| 群の member の欠落 | mapping が参照する `sector_id` が artifact に無い | `unknown_source_sector` で拒否。**欠落を baseline 値（比 1）で埋めない** |
| target covered share | `:declared_target_share` の `Σ w_j` | report と `ModelDerivedInput.coverage` に記録 |
| target uncovered share | `1 − Σ w_j` | `uncovered_share_treatment = :not_covered_by_upstream_input`（固定）として記録し、`< 1` なら警告 `partial_target_coverage`。**「影響が無い」ではなく「本入力の対象外」**と記録・説明する（§13） |
| source のない target group | CCC の target group のうち mapping が 1 件も持たないもの | report の `target_groups_without_source` に列挙。その group には `ModelDerivedInput` を作らない |
| 表現不能な target concept | §7.3 の `unmapped_target_concept` 行 | mapping artifact に書かれた時点で拒否（`X2`）。`X5` でも防御的に拒否 |

### 8.5 classification の検証規則

- `source_classification` の `(system, version, level)` が PNE artifact の `classification` と**完全一致**
  すること（`classification_mismatch`）。version 違い・level 違い（例: 統合中分類と基本分類）を同一視しない。
- `sector_id` は opaque 文字列として完全一致で照合する。`source_label` を照合に使わない。
- 1 つの PNE 部門は高々 1 つの group の member、または producer set の 1 か所にのみ現れる
  （`duplicate_sector_assignment`）。1 部門を複数の DME 対象へ按分する（one-to-many）mapping は v1 では
  受理しない（按分キーの妥当性を DME が検証できないため）。

---

## 9. 時間軸・頻度 mapping（Issue #280 Scope 4）

### 9.1 source の期間単位ごとの扱い

DME の目標頻度は四半期（CCC の `Δt = 0.25` 年）。PNE の 1 期間は **source network の baseline 期間そのもの**
であり（PNE `PeriodCalendar`：`period_unit` はラベルであって換算係数ではない）、各期間の値は「その期間の
実現産出 / baseline 1 期間分の産出」である。

| `period_unit` | 扱い | 集約規則 | 理由 |
|---|---|---|---|
| `quarter` | **受理** | `:identity`（1 期間 = 1 四半期） | 同一頻度 |
| `month` | **受理** | `:mean_of_three_months`（§9.2） | 高頻度 → 四半期の集約は flow 比の定義から一意に決まる |
| `week` | 拒否 `unsupported_source_period_unit` | — | 週は四半期境界を跨ぐ。按分規則を置くと測定されていない期内配分を作る（`PG-05`） |
| `day` | 拒否 `unsupported_source_period_unit` | — | 日数規約（四半期 90–92 日）を v1 では定めない（`PG-05`） |
| `year` | 拒否 `unsupported_source_period_unit` | — | 低頻度 → 高頻度の分解は期内プロファイルの捏造になる（PNE 自身が年次表を月次へ按分しないのと同じ原理） |
| `baseline_period` | 拒否 `ambiguous_source_period_unit` | — | 期間の長さが宣言されていない |

### 9.2 値の意味と集約式

PNE の値は flow の比（期間合計の実現産出 / baseline 1 期間分）である。月次 source の四半期値は

```text
r_j^Q(k) = ( r_j^M(3k) + r_j^M(3k+1) + r_j^M(3k+2) ) / 3
```

とする。PNE では各期間の baseline が同一の「baseline 1 期間分」であるため、四半期合計の実現産出を四半期
baseline（= 3 期間分）で割った比は 3 か月の比の算術平均に**厳密に**一致する（近似ではない）。月ごとの
季節性は PNE の baseline に存在せず、これは PNE のモデル仮定として DME へ引き継がれる（警告は出さないが
provenance の `model_assumptions` に残る）。

- 集約は `realized_output_ratio` に対して行い、`output_loss_ratio` は集約しない（DME 内の損失は常に `1 − r`）。
- 水準（`baseline_output`）への換算は行わない。比のまま扱うことで、PNE と DME の単位・価格基準の違い
  （例: JPY 名目 vs USD 2017 年連鎖）を持ち込まない。
- ratio を累積・合計しない（flow 比を stock として扱わない）。

### 9.3 calendar anchor

- PNE の `calendar_anchor` は PNE が一切解釈しない任意文字列である。DME は **`YYYY-MM-DD`（日付のみ、
  ISO 8601 基本形）**だけを解釈し、それ以外の形式（日時・タイムゾーン付き・年月のみ等）は
  `calendar_anchor_invalid` で拒否する。
- `quarter` source: anchor がある場合、四半期初日（1/4/7/10 月の 1 日）でなければ `calendar_anchor_misaligned`。
- `month` source: anchor は**必須**（どの 3 か月が 1 四半期を成すかを決めるため。無ければ
  `calendar_anchor_required`）。anchor は四半期初日でなければならない（`calendar_anchor_misaligned`。
  §9.4 により先頭の部分四半期を受理しないため）。

### 9.4 部分四半期・欠損期

- `month` source で `available_periods` が 3 の倍数でない（末尾が部分四半期）場合は `partial_quarter` で拒否する。
  先頭の部分四半期は §9.3 で拒否される。部分四半期の値を残りの月から外挿したり、欠けた月を比 1（回復済み）
  で埋めたりしない（`PG-11`）。
- 欠損期は PNE v1 の `complete` artifact には存在しない（§5.2 の期間被覆検査）。`unsupported` artifact の
  部分値は適用しない（§5.2）。

### 9.5 DME 時間軸への配置（2 基準）

[シナリオ時間軸の意味論](scenario_time_semantics.md) と ADR 0015 決定 5 の 2 基準を踏襲し、**基準は
`Scenario.period_zero` の有無で決まる**（`ModelDerivedInput` 側で別途選ばない。1 シナリオ内での混在を
構造的に起こさない）。

| `Scenario.period_zero` | 基準 | 配置 | 条件 |
|---|---|---|---|
| あり | `:calendar` | `t0 = quarter_index(quarter_of(anchor), period_zero)` | anchor 必須（`calendar_anchor_required`）。`t_start` を指定してはならない（`timing_basis_conflict`） |
| なし | `:period` | `t0 = t_start`（分析者が明示） | `t_start` 必須。anchor があっても配置には使わず、警告 `upstream_calendar_anchor_unused`。`month` source は §9.3 により anchor 必須だが、その用途は四半期の区切りの検証に限る |

- DME 四半期 `t = t0 + k`（`k = 0 … Q − 1`、`Q` は集約後の四半期数）に値を置く。
- `t0 < 0`（助走区間）は `upstream_path_in_runup` で拒否する。助走区間の外生は定常固定である（ADR 0018）。
- `t0 + Q − 1 > horizon_eval − 1` の場合、評価区間を超える末尾を切り捨て、警告 `upstream_path_truncated`
  を出す（評価区間内の値は変えない）。
- `t < t0` の DME 期には上流入力を置かない（PNE のシミュレーションは baseline 状態から始まり、期 0 より
  前について何も述べていない）。

### 9.6 PNE horizon 後の扱い

PNE horizon の後（`t > t0 + Q − 1` かつ評価区間内）について PNE artifact は何も述べていない。v1 の規則は
`post_horizon = :require_recovered` の 1 値のみとする。

- 集約後の最終四半期 `Q − 1` で、入力に用いる全 member が `|1 − r_j^Q(Q−1)| ≤ 1e-12` のとき、horizon 後の
  上流入力を 0（変化なし）とし、`ModelDerivedInput.post_horizon = :recovered_at_source_horizon_end` を記録する。
- そうでなければ `upstream_path_unrecovered_at_horizon_end` で拒否する。最終値を保持する・baseline へ戻す
  といった仮定を DME が暗黙に置かない（`PG-10`）。

### 9.7 処理順序

`X3` 段は **時間集約（部門ごと）→ 部門集約（group ごと）** の順に固定する。両者は線形であり数学的には
可換だが、浮動小数点の結果を一意にするため順序を固定し、部門集約は `sector_id` 昇順の逐次加算とする
（総和関数の実装差に依存しない）。

---

## 10. イベント層との関係（Issue #280 Scope 6）

### 10.1 候補と判定

| 候補 | 判定 | 理由 |
|---|---|---|
| A. 新しいイベント型（例 `:UpstreamSupplyShock`）を `MACRO_EVENT_TYPES` へ追加し、`ScenarioAssumption` として event registry を通す | **不採用** | `L3` のイベント型は `L1`（観測事象）→ `L2` → `L3` の連鎖を前提とする。上流に観測が存在しない型を追加すると 4 層の意味が崩れる。`magnitude_source` の 5 値のいずれも「上流モデルの導出結果」を正しく表さない。`event_set_hash`・macro-event contract version が動き、既存 artifact の意味が変わる |
| B. 既存イベント型（例 `:DemandOutlookRevision`・`:OrderCancellation`）へ変換できる場合だけ event path を使う | **不採用** | 派生中間需要は「需要見通しの改定」でも「受注取消」でもない。型名が意味を誤って伝え、LLM 説明（`magnitude_source` 等）も誤る。条件付きの二重経路は同じ入力が経路によって別のログ・hash を持つ状態を生む |
| **C. event registry を経由せず、`ModelDerivedInput` をモデル固有 adapter で `AppliedModelInput` へ変換し、`L4` 以降の共通基盤（合成・実行・ログ・保存）を再利用する** | **採用** | 4 層と既存 API を変更しない。共通化するのは「同じ数値を返すべき計算」（固定順合成）と実行・監査の基盤だけであり、ADR 0015 決定 8・9 の方針（表現対象の異なるものの型は分け、計算だけ共通化する）と同型 |

### 10.2 採用した構成

- `map_model_derived_input(m, x::ModelDerivedInput; periods, baseline, period_zero)` を新設する（#282）。
  既定メソッドは `unsupported_target_model` を返し、CCC メソッドが §7.4 を実装する。`map_event` の
  引数型は `ScenarioAssumption` のまま変えない。
- CCC のモデル固有 mapping registry `CCC_CROSS_MODEL_MAPPING_RULES`（`ccc-cross-model-mapping/1.0.0`）を
  宣言的に持つ。各行は source concept・target group・target 変数（`nothing` 可）・unit・application mode・
  value semantics・baseline 参照・符号規約・frequency・`unsupported_reason`・契約行の出典を持ち、§7.3 の
  表と 1:1 に対応する（表とコードの一致をテストで検査する。ADR 0015 決定 2 と同じ方式）。
- 実行入口は新設の `run_cross_model_scenario(m, sc::Scenario, xs::Vector{ModelDerivedInput}; options)`
  とし、**`run_scenario` を変更しない**。`xs` が空のとき、結果の外生パス・系列は同じ `m`・`sc`・`options`
  の `run_scenario` と bit 単位で一致しなければならない（回帰テスト）。

### 10.3 再利用する / しない基盤

| 基盤 | 扱い |
|---|---|
| `AppliedModelInput`（型） | **再利用**。`assumption_id` には `ModelDerivedInput.input_id` を入れ、`provenance = EventProvenance(layer = :applied, derived_from = [x.input_id], rule_id = <CCC registry 行 id>, rule_version = "ccc-cross-model-mapping/1.0.0", generator = "DME.map_model_derived_input")`。`persistence = PersistenceSpec(shape = :path, params = (values = …,))`、`magnitude = maximum(abs, values)`（`Y-12`）。`warnings` は `MACRO_EVENT_WARNING_CODES` のみ（cross-model 警告は別に持つ） |
| `schedule_events` / `compose_exogenous_paths`（全順序・固定順合成） | **再利用**。イベント由来と上流由来の `L4` を連結して 1 回だけ呼ぶ |
| `ScenarioRunOptions` | **再利用**。ただし `on_unmapped = :warn` は cross-model 拒否を緩めない（§10.5） |
| 実行ステータス 4 値（`SCENARIO_EXECUTION_STATUSES`） | **再利用**。5 値目を追加しない |
| `EventRejection` / `ScenarioWarning` とそのコード | **再利用しない**（コード集合を変更しないため）。cross-model は `CrossModelRejection` / `CrossModelWarning` と独自語彙（§11） |
| `event_log`（`EventLogEntry` 14 項目） | **変更しない**。上流由来 `L4` は `assumption_id` に対応する `ScenarioAssumption` が無いため既定値（`timing_basis = :period` 等）で記録される。正確な上流情報は別の `cross_model_input_log` に記録する（§12.4） |
| `ScenarioProvenance`・`params_hash`・`initial_state_id`・`solver_settings_hash` | **再利用**。cross-model 固有の identity は `CrossModelProvenance` に分けて持つ |
| `scenario.json`・`save_scenario_artifact`・`replay_scenario` | **変更しない**。cross-model 実行は別 schema の成果物で保存する（§12.4） |
| `run_scenario`・`map_event`・`Scenario` | **変更しない** |

### 10.4 イベント由来入力との合成

- **input_id の名前空間**: 上流由来 `ModelDerivedInput.input_id` は `"xm-"` 接頭辞を必須とし、生成される
  `AppliedModelInput.input_id` は `"<input_id>/<target_variable>"` とする。イベント由来の `assumption_id`・
  `input_id` と衝突した場合、`schedule_events` の `duplicate_dropped`（警告して片方を捨てる）へ委ねず、
  実行前に `duplicate_input_id` で**拒否**する（片方が黙って落ちることを防ぐ）。
- **合成順序**: 既存の固定順合成（`:absolute` → `:multiplicative` → `:additive`、各クラス内は全順序
  `order_key = (t_apply, class_rank, target_rank, timing_sort_key, input_id)` の昇順逐次適用）をそのまま適用する。
  上流由来 `L4` は `:multiplicative` であり、対応する `ScenarioAssumption` を持たないため `timing_sort_key`
  はモデル期の符号付き 0 埋め文字列（例 `"+0003"`）になる。暦日基準のシナリオでは、同じ
  `(t_apply, class_rank, target_rank)` に event 由来（日付文字列）と上流由来が並ぶことがあるが、文字列比較により
  決定的に順序づく。上流由来とイベント由来を区別する追加の順序キーを設けない（合成規則を 2 つにしない）。
- **二重計上の警告**: 同一 `target_variable` に上流由来とイベント由来の `L4` が重なる期がある場合、警告
  `upstream_event_same_target` を出す。例: 分析者が「自動車の減産で半導体需要が落ちる」ことを
  `:DemandOutlookRevision`（`S2`）として既に置いている場合、同じ現象の PNE 派生需要を重ねると二重計上に
  なりうる。DME は両者が同じ現象かを判定できないため拒否はせず、警告と metadata で可視化する。
- 合成後の値の制約（`ext_demand_s ≥ 0` 等）は既存の `constraint_violation` 規則に従う。

### 10.5 `run_cross_model_scenario` の実行順

1. **検証**: `_scenario_validate_structure`（既存）に加え、`xs` の集合検証（`input_id` の一意性と接頭辞・
   イベント側 ID との衝突・`target_model == model_symbol(m)`・§9.5 の基準整合・`mapping_hash` /
   `compatibility_report_hash` の存在）。失敗は `status = :rejected_validation`。
2. **mapping**: `sc.assumptions` に `map_event`（既存）、`xs` に `map_model_derived_input`。cross-model 拒否が
   1 件でもあれば `status = :rejected_mapping`（**`on_unmapped = :warn` でも実行しない**。`ModelDerivedInput`
   は特定モデル向けに構築されたものであり、写せないことは入力集合の構成誤りだからである）。
3. **schedule**: 両系統の `L4` を連結して `schedule_events`（既存）。
4. **model**: `capex_run`（既存、`exog` を明示的に渡す）。
5. **会計・診断**: 既存と同じ。
6. **result**: `to_simulation_result` + イベント層 metadata 20 キー（既存）+ cross-model metadata（§12.3）。

戻り値 `CrossModelScenarioRun` は `ScenarioRun` と同じ情報に加え、`model_derived_inputs`・
`cross_model_rejections`・`cross_model_warnings`・`cross_model_provenance` を持つ。イベント由来の拒否・警告と
cross-model の拒否・警告を**同じ配列へ混ぜない**。

---

## 11. 失敗契約

### 11.1 3 層（ADR 0015 決定 6 を継承）

| 層 | 対象 | 返し方 |
|---|---|---|
| (1) 値の不変条件 | PNE artifact・mapping artifact の decode 不能（§5.2）、`ModelDerivedInput` のフィールド不変条件（`values` の非有限・正の値・長さ不整合等） | 例外（`ArgumentError`、メッセージ先頭にコード） |
| (2) 集合の整合 | 互換性判定・mapping・実行前検証 | 構造化拒否 `CrossModelRejection` を**全件列挙**して返す。モデルを実行しない |
| (3) 解釈に影響する事項 | coverage・truncation・synthetic 等 | 警告 `CrossModelWarning`。実行する |

### 11.2 拒否コード（`CROSS_MODEL_REJECTION_CODES`）

実装はこれ以外のコードを生成しない。コードの追加・削除は `cross-model-input` の minor 以上の version 変更と
ADR 0024 の改訂を要する。

| コード | 段 | 条件 |
|---|---|---|
| `upstream_status_unsupported` | `X2` | PNE `status = unsupported` |
| `upstream_error_warning` | `X2` | PNE 警告に `severity = error` |
| `geography_mismatch` | `X2` | identity 不一致で `:same_economy` を宣言 |
| `geography_declaration_inconsistent` | `X2` | mapping の `source_geography` / `target_geography` が実体と不一致 |
| `transmission_mode_inconsistent` | `X2` | identity 一致なのに override / cross-economy を宣言、または mode の必須フィールド欠落 |
| `cross_economy_transmission_unavailable` | `X2` | `:explicit_cross_economy`（v1 は受理先なし） |
| `hypothetical_override_requires_synthetic_source` | `X2` | override だが source が synthetic でない |
| `classification_mismatch` | `X2` | `(system, version, level)` 不一致 |
| `unknown_source_sector` | `X2` | mapping が artifact に無い `sector_id` を参照 |
| `duplicate_sector_assignment` | `X2` | 1 部門が複数 group / member と producer set に重複 |
| `unmapped_sector_undeclared` | `X2` | 実際の unmapped 集合 ≠ `declared_unmapped_source_sectors` |
| `invalid_weights` | `X2` | weight の欠落・非有限・非正・`Σ w > 1`・`weight_provenance` 欠落 |
| `weight_basis_not_allowed` | `X2` | target concept が許さない weight basis |
| `baseline_output_missing` | `X2` | `:source_baseline_output` で `baseline_output` が無い部門 |
| `baseline_output_unit_mismatch` | `X2` | 群内で `baseline_output.unit` が不一致 |
| `unmapped_target_concept` | `X2`・`X5` | target model が構造上表現しない概念（§7.3） |
| `unsupported_target_model` | `X2`・`X5` | target profile / registry が無いモデル（§7.1） |
| `own_supply_constraint_present` | `X2` | `DD-6` 違反 |
| `producer_set_undeclared` | `X2` | producer set も `producer_set_absent_reason` も無い |
| `unsupported_source_period_unit` | `X2` | `week`・`day`・`year` |
| `ambiguous_source_period_unit` | `X2` | `baseline_period` |
| `calendar_anchor_required` | `X2`・`X4` | §9.3・§9.5 |
| `calendar_anchor_invalid` | `X2` | `YYYY-MM-DD` でない |
| `calendar_anchor_misaligned` | `X2` | 四半期初日でない |
| `partial_quarter` | `X2` | §9.4 |
| `upstream_path_unrecovered_at_horizon_end` | `X2` | §9.6 |
| `upstream_path_in_runup` | `X4`・実行前検証 | `t0 < 0` |
| `timing_basis_conflict` | 実行前検証 | §9.5 の基準と `ModelDerivedInput` の指定が矛盾 |
| `duplicate_input_id` | 実行前検証 | ID の重複・接頭辞違反・イベント側 ID との衝突 |
| `provenance_chain_broken` | 実行前検証・replay | `ModelDerivedInput` の `mapping_hash` / `compatibility_report_hash` / `upstream.content_hash` が、同梱された mapping・report・artifact と一致しない |

`detail` は日本語で記述し、「影響が無い」「効果が無い」を含めない（`EventRejection` と同じ規律）。

### 11.3 警告コード（`CROSS_MODEL_WARNING_CODES`）

| コード | 条件 |
|---|---|
| `upstream_warning_carried` | PNE の `info` / `warning` severity 警告の転記 |
| `synthetic_upstream_source` | source が synthetic |
| `upstream_estimated_inputs` | PNE network に `estimated` / `inferred` の node / edge が含まれる |
| `hypothetical_transmission` | `:hypothetical_override` で受理 |
| `unmapped_source_sectors_present` | unmapped source sector が 1 件以上 |
| `partial_target_coverage` | `Σ w_j < 1` |
| `producer_set_absent` | producer set が空（`producer_set_absent_reason` あり） |
| `upstream_calendar_anchor_unused` | `:period` 基準で anchor を配置に使わなかった |
| `upstream_path_truncated` | 評価区間を超える末尾を切り捨てた |
| `upstream_event_same_target` | 同一 target 変数に上流由来とイベント由来の入力が重なる |

### 11.4 compatibility report

`check_cross_model_compatibility(artifact, mapping, profile) -> CrossModelCompatibilityReport`（#281）。
変換前に machine-readable に生成し、`accepted` でなければ `X3` へ進めない。

```text
schema_version   "dme.cross-model-compatibility-report/1.0.0"
decision         "accepted" | "rejected"
upstream         UpstreamModelArtifactRef（§3.3）
mapping          {mapping_id, mapping_version, mapping_hash}
target           {model, profile_version, geography}
geography        {status, source, target, transmission_mode, claim_scope}
classification   {status, source, declared}
time             {status, source_period_unit, aggregation_rule, calendar_anchor, timing_quarters, partial_quarter, post_horizon}
coverage         {source_sectors_total, member_sectors, producer_set_sectors, unmapped_source_sectors,
                  groups: [{target_group, weight_basis, covered_share, uncovered_share}], target_groups_without_source}
rejections       [{code, stage, subject_ids, detail}]   （全件）
warnings         [{code, subject_ids, detail}]
```

report 自身は hash フィールドを持たず、`compatibility_report_hash` は report 全体の RFC 8785 正準 JSON の
SHA-256 とする（配列は `code`・`subject_ids` 等で整列する）。report には生成時刻を入れない（決定性）。

---

## 12. provenance / replay（Issue #280 Scope 7）

### 12.1 provenance chain

```text
SimulationResult（metadata: cross_model_inputs / cross_model_upstream_artifacts / …、§12.3）
  → AppliedModelInput（input_id = "xm-…/ext_demand_s2"、provenance.derived_from = [xm-…]、
                       rule_id / rule_version = CCC registry 行 / ccc-cross-model-mapping/1.0.0）
  → ModelDerivedInput（input_id、mapping_hash、compatibility_report_hash、upstream.content_hash）
  → mapping artifact（mapping_id / mapping_version / mapping_hash）+ compatibility report（report hash）
  → PNE sector-output-path（artifact_id / content_hash / [source_bytes_sha256]）
  → PNE dynamic artifact（source.dynamic_artifact_id / dynamic_artifact_hash;
                          scenario_hash / scenario_policy_hash / scenario_config_hash; export_config_hash）
  → PNE input / source provenance（source.source_input_hash / network_id; source_provenance.references）
```

DME が検証できるのは `ModelDerivedInput` → mapping / report → PNE bridge（`content_hash`）までである。PNE
dynamic artifact 以降の hash は PNE が付与した値を**そのまま保持して辿れるようにする**が、DME は PNE の
dynamic artifact を読まず、再計算もしない（UM-8）。

### 12.2 hash と対象

| hash | 対象 | 除外 |
|---|---|---|
| `upstream.content_hash` | PNE artifact 全体（§5.3） | なし（`source_bytes_sha256` は hash ではなく監査属性） |
| `mapping_hash` | mapping artifact（§8.2） | `notes` |
| `compatibility_report_hash` | report 全体（§11.4。生成時刻を持たない） | `upstream.source_bytes_sha256`（監査属性。§3.3・§19） |
| `cross_model_input_set_hash` | `ModelDerivedInput` 全件（`input_id` 昇順） | `notes`・`upstream.source_bytes_sha256` |

いずれも ASCII snake_case キー・RFC 8785 正準化（既存の `canonical_json_bytes` を変更せずに再利用し、前段に
型写像 encoder を置く。ADR 0015 決定 13）・`"sha256:…"` 形式。

### 12.3 `SimulationResult` metadata 予約キー（cross-model、10 個）

イベント層の 20 キー（統合設計 §9.3）と CCC の予約キーを上書きしない。`run_cross_model_scenario` が生成した
結果にのみ付与し、他モデル・`run_scenario` に要求しない。

| キー | 内容 |
|---|---|
| `cross_model_contract_version` | `"cross-model-input/1.0.0"` |
| `cross_model_input_set_hash` | §12.2 |
| `cross_model_inputs` | 入力ごとの要約（`input_id`・`applied_input_ids`・`target_variable`・`target_group`・`t0`・`Q`・適用期・値の最小/最大・`covered_share`・`uncovered_share`・`post_horizon`） |
| `cross_model_upstream_artifacts` | `UpstreamModelArtifactRef` の一覧（`content_hash` で重複除去） |
| `cross_model_mapping_refs` | `{mapping_id, mapping_version, mapping_hash, target_model_mapping_version}` の一覧 |
| `cross_model_compatibility_report_hashes` | report hash の一覧 |
| `cross_model_transmission_modes` | 入力ごとの transmission mode |
| `cross_model_claim_scope` | 結果全体の claim scope（入力のうち最も制限の強いもの。§13） |
| `cross_model_warnings` | `CrossModelWarning` の辞書表現 |
| `cross_model_rejections` | `CrossModelRejection` の辞書表現（完了時は空） |

### 12.4 成果物と replay

`save_cross_model_scenario_artifact(dir, run::CrossModelScenarioRun)`（#282）は次を書き出す。既存の
`scenario.json` は**書かない**（既存 `replay_scenario` が上流入力を欠いたまま再実行することを、ファイルの
不在によって構造的に防ぐ）。

| ファイル | schema | 内容 |
|---|---|---|
| `cross_model_scenario.json` | `dme.cross-model-scenario/1.0.0` | `scenario`（`scenario_to_dict` の出力をそのまま埋め込み、decode 時に `scenario_from_dict` で検証）+ `model_derived_inputs` + `cross_model_input_set_hash` |
| `mappings.json` | 同上 | 参照される mapping artifact 全件 |
| `compatibility_reports.json` | 同上 | 参照される report 全件 |
| `event_log.json` | 既存形式 | `schedule_events` のログ（両系統の `L4`） |
| `cross_model_input_log.json` | 同上 | 上流由来 `L4` ごとの正確な出自（upstream ref・mapping・timing 基準・`t0`・切り捨て） |
| `manifest.json` | 既存キー + `run_kind = "cross_model"`・`cross_model_input_set_hash`・`cross_model_contract_version` | 再現契約 |
| `result_summary.json` / `report.md` | 既存形式 | 要約（report には §13 の必須記載を含める） |

**replay 契約**（`replay_cross_model_scenario(m, dir; upstream_artifacts = nothing)`、#282 実装・#283 E2E）:

1. replay の入力は `cross_model_scenario.json` のみ（+ 照合用の `mappings.json`・`compatibility_reports.json`・
   `manifest.json`）。**PNE artifact のバイト列を必要としない**。ネットワーク・API キー・ローカル絶対パスに
   依存しない。
2. `ModelDerivedInput` の `mapping_hash` / `compatibility_report_hash` が同梱ファイルの再計算値と一致しなければ
   `provenance_chain_broken`（例外）。`params_hash` / `initial_state_id` / `solver_settings_hash` を manifest と
   照合する（ADR 0015 決定 12 と同じ）。
3. `upstream_artifacts`（`content_hash => path`）が与えられた場合に限り、PNE artifact から `X1`–`X4` を再実行し、
   `ModelDerivedInput.values` が bit 単位で一致することを検証する（再導出検証。#283 の drift 検出に用いる）。
4. 同一入力の replay は同一の `cross_model_input_set_hash`・外生パス・系列を返す。

---

## 13. 説明・主張の制約（claim scope）

| `claim_scope` | 付与条件 | 述べてよいこと | 述べてはいけないこと |
|---|---|---|---|
| `:same_economy_model_derived` | `:same_economy` で受理 | 「PNE の（シナリオ条件付き）供給網シミュレーション結果を、同一経済の CCC へ派生需要として入れた場合の条件付き応答」 | 観測・実績・予測としての記述。covered share 以外の需要への言及 |
| `:hypothetical_fictional` | `:hypothetical_override` で受理 | 「架空（synthetic）の供給網入力を用いた仮想シナリオ」 | 実在の経済・部門・企業の途絶の影響としての記述 |

いずれの場合も次を必須記載とする（[llm_safety.md](../llm_safety.md) §2.9・§5.6）。

- PNE の値がモデル導出結果であり観測ではないこと（`result_role`）。
- 派生需要は target 変数の covered share に限った寄与であり、uncovered share（`1 − Σw`）は本入力の対象外である
  こと（「影響が無い」とは述べない）。
- weight は識別仮定であること（`PG-04`）。
- CCC が供給能力の外生入力を持たず、対応部門自身の供給制約を表現しないこと（`PG-01`）。
- 日本の PNE 結果を米国のモデルへ入れていないこと（入れられないこと）。

---

## 14. versioning

| version 定数（実装時） | 値 | 上げる条件 |
|---|---|---|
| `CROSS_MODEL_INPUT_CONTRACT_VERSION` | `cross-model-input/1.0.0` | 型・処理段・拒否/警告コード・claim scope・metadata 予約キーの変更 |
| `PNE_SECTOR_OUTPUT_PATH_ACCEPTED_SCHEMA_VERSIONS` | `("production-network-sector-output-path/v1",)` | 受理する上流 version の追加（PNE v2 等） |
| `CROSS_MODEL_MAPPING_SCHEMA_VERSION` | `dme.cross-model-mapping/1.0.0` | mapping artifact のキー・構造・weight basis・時間規則の変更 |
| `CROSS_MODEL_COMPATIBILITY_REPORT_SCHEMA_VERSION` | `dme.cross-model-compatibility-report/1.0.0` | report の構造変更 |
| `CROSS_MODEL_TARGET_PROFILE_VERSION` | `cross-model-target-profile/1.0.0` | target profile の追加・経済圏・受理概念の変更 |
| `CCC_CROSS_MODEL_MAPPING_VERSION` | `ccc-cross-model-mapping/1.0.0` | CCC registry の行の追加・削除・値の意味の変更 |
| `CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION` | `dme.cross-model-scenario/1.0.0` | 保存 JSON のキー・構造の変更 |
| `ACCEPTED_CROSS_ECONOMY_TRANSMISSION_CONTRACTS` | `()` | transmission 契約の受理（ADR 改訂必須） |

**契約**: 受理範囲を広げる変更（新しい `period_unit`・新しい transmission・新しい target model・部分四半期・
horizon 後の持続仮定）は、コード変更と同時に本書の改訂節と ADR 0024 の改訂として行う。設定値だけで受理範囲が
変わる経路を作らない。

---

## 15. テスト戦略（後続 Issue への要求）

| 区分 | 項目 | Issue |
|---|---|---|
| 受理 | vendor した PNE `representative.json` を受理し、`UpstreamModelArtifactRef` が source の全 hash を保持 | #281 |
| 受理 | PNE の `rejected/` 6 件（geography 欠落・classification 欠落・未対応 period unit・NaN・Infinity・損失比不整合）をすべて decode 時に拒否 | #281 |
| 受理 | 未知キー・未知 schema version・`status = unsupported`・error 警告 | #281 |
| geography | same economy 受理 / 不一致 + `:same_economy` 拒否 / override は synthetic のみ受理 / `:explicit_cross_economy` は `transmission_ref` があっても拒否（`geography_mismatch` と別コード） | #281 |
| geography | CCC target profile の経済圏を差し替える API が存在しないこと（テストのための弱体化の禁止） | #281・#283 |
| classification | version / level 違いの拒否、未知 `sector_id`、重複割当、undeclared unmapped | #281 |
| 部門集約 | many-to-one の 3 weight basis、`baseline_output` 欠落・単位不一致で非加重平均へ落ちないこと、`:declared_target_share` を再正規化しないこと | #281 |
| 時間 | quarter identity、month → quarter 平均、anchor 必須/不正/不整列、部分四半期、未回復 horizon 末、runup 配置、評価区間超過の切り捨て | #281・#282 |
| report | 複数の違反を 1 回の判定で全件列挙すること、report hash の決定性 | #281 |
| CCC mapping | registry と §7.3 表の 1:1 一致、`ext_demand_s2`/`_s3` の受理、他 5 変数と供給能力・総産出の拒否、`DD-6` 違反の拒否、`exogenous_variables(m)` 外へ適用しないこと | #282 |
| 合成 | 複数の上流入力 + 既存イベントの同時適用、固定順合成の結果、`upstream_event_same_target`、ID 衝突の拒否 | #282 |
| 非破壊 | `xs` が空の `run_cross_model_scenario` と `run_scenario` の bit 一致、`Sc0`–`Sc4` と event-driven デモの既存結果の不変 | #282 |
| 保存・replay | `cross_model_scenario.json` からの replay で同一 hash・系列、PNE bytes 無しで replay 可能、改ざんで `provenance_chain_broken`、既存 `load_scenario` が cross-model 成果物を読まないこと | #282・#283 |
| E2E | PNE #33 の実 producer 経路で生成した synthetic fixture + override mapping で `X0`–`X7` を完走 | #283 |
| E2E negative | official Japan 由来 metadata の artifact を US-CCC へ入れる 3 mode がそれぞれ §6.5 のコードで拒否されること（official data 本体は commit しない） | #283 |
| drift | vendor schema・fixture の `source_bytes_sha256` と PNE commit を `MANIFEST.json` で固定し、PNE 側の変更を検出 | #283 |

---

## 16. 実装作業の分解

| ID | Issue | 対象 | 依存 |
|---|---|---|---|
| `PN-1` | #281 | `X1`–`X3`：受理・compatibility・mapping・report | 本書・PNE #32 |
| `PN-2` | #282 | `X4`–`X7`（保存・replay の実装まで）：`ModelDerivedInput`・CCC adapter・`run_cross_model_scenario` | `PN-1`・PNE #33 |
| `PN-3` | #283 | cross-repository fixture・drift 検出・provenance / replay / negative E2E | `PN-1`・`PN-2`・PNE #33 |

### 16.1 `PN-1`（#281）

- **配置**: `src/scenarios/` 直下に `pne_sector_output_path.jl`（受理・`UpstreamModelArtifactRef`）・
  `cross_model_mapping.jl`（mapping artifact・target profile）・`cross_model_compatibility.jl`（`X2`・
  report・拒否/警告語彙・`X3`）を置き、`src/DME.jl` で `scenarios/scenario_serialization.jl` の後に include する
  （新規サブディレクトリを作らないため `docs/make.jl` の変更は不要）。`X3`（`apply_cross_model_mapping`）は
  report 型に依存するため `cross_model_compatibility.jl` に置いた（§19）。
- **vendor**: PNE の schema を `docs/contract/pne/`、`representative.json`・`rejected/`・`export_config.json` を
  `test/fixtures/pne/sector_output_path/v1/` へコピーし、PNE commit と各ファイルの SHA-256 を `MANIFEST.json`
  に記録する。
- **本書による #281 からの明確化**:
  1. `transmission mode = explicit_cross_economy` の fixture は「identity を検査したうえで
     `cross_economy_transmission_unavailable` で拒否される」ことを固定する（v1 は受理先なし、§6.4）。
  2. 受理する source 頻度は `quarter` と `month` のみ（§9.1）。
  3. `:hypothetical_override` は synthetic source に限る（§6.3）。
  4. unmapped source sector は mapping artifact に明示リストとして宣言させる（§8.4）。
  5. 部門集約の weight basis は 3 種、CCC が受理するのは `:declared_target_share` のみ（§8.3・§7.2）。

### 16.2 `PN-2`（#282）

- **配置**: `src/scenarios/adapters/capex_credit_cycle_cross_model_adapter.jl`（`CCC_CROSS_MODEL_MAPPING_RULES`・
  `map_model_derived_input`）・`src/scenarios/cross_model_runner.jl`（`ModelDerivedInput` 構築・
  `run_cross_model_scenario`・保存・replay）。`PN-1` のファイルの後に include する。
- **本書による #282 からの明確化**:
  1. CCC の適用先は `ext_demand_s2` / `ext_demand_s3` の派生中間需要チャネルのみ（§7.3・§7.4）。
     CCC 対応部門自身の供給制約は `unmapped_target_concept` で拒否し、新しい外生変数を追加しない（`PG-01`）。
  2. 実行入口は `run_cross_model_scenario` とし、`run_scenario` を変更しない（§10.2）。
  3. `AppliedModelInput` は型を変えずに再利用し、cross-model の拒否・警告は独自語彙で持つ（§10.3・§11）。
  4. `on_unmapped = :warn` は cross-model 拒否を緩めない（§10.5）。
  5. 保存は `cross_model_scenario.json` とし、`scenario.json` を書かない（§12.4）。

### 16.3 `PN-3`（#283）

- **本書による #283 からの明確化**:
  1. compatible positive E2E は、PNE #33 の実 producer 経路で生成した **synthetic** artifact を
     `:hypothetical_override` で CCC へ入れて完走させる（CCC と同一経済圏の PNE profile が存在しないため。`PG-02`）。
     fixture の geography を `ISO 3166-1 alpha-2 / US` に偽装しない。
  2. official Japan → US negative は §6.5 の 3 コードを golden とする。
  3. PNE artifact の identity は DME の `content_hash` と `source_bytes_sha256` で固定する（PNE の
     `hash_document` 値を DME で再計算しない。§5.3）。
  4. replay は PNE bytes 無しで成立し、PNE bytes を与えた場合にのみ再導出検証を行う（§12.4）。

---

## 17. 限界

1. v1 で PNE 由来入力を受け付けるのは CCC の派生中間需要チャネル（`ext_demand_s2`・`ext_demand_s3`）のみであり、
   供給網途絶の最も直接的な帰結である「CCC 対応部門自身の供給制約」は表現できない（`PG-01`）。
2. 現時点で CCC と同一経済圏の PNE real profile は無く、実データの positive path は存在しない（`PG-02`）。
   positive E2E は synthetic fixture による仮想シナリオに限られる。
3. `:declared_target_share` の weight と `customer_scope = :out_of_model` の宣言は識別仮定であり、DME は
   その妥当性を検証できない（`PG-04`・ADR 0018 決定 7）。
4. `DD-6` は宣言された producer set についてのみ成立し、宣言の完全性は検証できない（`PG-06`）。
5. PNE は上流への需要伝播・価格・金融条件をモデル化しない。PNE 由来入力はこれらを含まない。
6. month → quarter の集約は PNE の「各期間の baseline が同一」という仮定の下で厳密であり、季節性を含まない。
7. PNE horizon 末で未回復のパス・部分四半期・日次/週次/年次 source を v1 は受理しない（`PG-05`・`PG-10`・`PG-11`）。
8. DME は PNE dynamic artifact 以降の hash を再計算しない。provenance chain の後半は PNE が付与した値の保持に
   よって辿る（`PG-09`）。

---

## 18. 参照

- [ADR 0024: PNE sector-output-path の cross-model input 契約](../adr/0024-pne-sector-output-cross-model-input-contract.md)
- [マクロイベント変換契約](macro_event_contract.md) §2（4 層）・§4.1（適用先 7 変数）・§4.5（`unmapped_target`）・§5.2（固定順合成）
- [イベント・シナリオ実行層 統合設計](macro_event_runtime_integration.md) §5.5–§5.7・§6・§9
- [シナリオ時間軸の意味論](scenario_time_semantics.md)
- [部門別CAPEX・信用循環モデル 部門境界と変数定義](../models/capex_credit_cycle_sectors_variables.md) §3.2–§3.3（`ext_demand_s` の定義）
- [部門別CAPEX・信用循環モデル 動学方程式と数値計算契約](../models/capex_credit_cycle_equations.md)（`ycap_s` の内生性）
- [クロスモデル推論層の設計](cross_model_reasoning.md)（概念対応の明示・同名変数の非同一視）
- PNE: [sector output path contract](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/docs/sector-output-path-contract.md)・[ADR 14](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/docs/decisions/0014-macro-boundary-is-native-sector-output-not-dynamic-state.md)

---

## 19. 実装への反映（#281 / `PN-1`）

#281 は `X1`–`X3` を本書に従って実装した。実装時に本書の記述を具体化・明確化した点を記録する
（いずれも受理範囲を広げない）。

| # | 事項 | 実装 |
|---|---|---|
| 1 | ファイル配置 | `X3` の `apply_cross_model_mapping` は report 型（`CrossModelCompatibilityReport`）に依存するため、§16.1 の当初案（`cross_model_mapping.jl`）ではなく `cross_model_compatibility.jl` に置いた |
| 2 | report hash の対象 | `compatibility_report_hash` は `upstream.source_bytes_sha256`（監査属性、§3.3）を除いて計算する。同じ内容を別のバイト列で受け取っても同じ hash になる（§12.2 の表を改訂） |
| 3 | 非有限の weight | JSON で表せず hash も計算できないため、`CrossModelGroupMember` の構築時に拒否する（層(1)）。`invalid_weights` は欠落・非正・`Σw > 1`・`weight_provenance` 欠落を扱う |
| 4 | geography の未判定 | target profile が無い（`unsupported_target_model`）場合、geography は判定できないため `geography_status = :not_evaluated` とする |
| 5 | 期間単位の不一致 | PNE artifact の `period_unit` が mapping の `expected_source_period_unit` と異なる場合も `unsupported_source_period_unit` で拒否する（新しいコードを追加しない） |
| 6 | registry version の不一致 | mapping の `target_model_mapping_version` が target profile の version と異なる場合も `unsupported_target_model` で拒否する |
| 7 | `X3` の前提 | `apply_cross_model_mapping` は渡された report を artifact・mapping から再計算した report と hash で照合し、不一致は `provenance_chain_broken`、`decision = :rejected` は `cross_model_mapping_rejected` の `ArgumentError` とする（`UM-4`） |
| 8 | decode の失敗コード | PNE artifact は `PNE_DECODE_ERROR_CODES`（`unsupported_upstream_schema_version`・`upstream_schema_violation`・`upstream_semantic_invariant_violation`）、mapping artifact は `invalid_cross_model_mapping`・`unsupported_cross_model_mapping_schema_version` でメッセージを始める |
| 9 | `DD-5` の宣言 | `target_concept = :derived_out_of_model_demand` の群は `customer_scope = "out_of_model"` と 1 件以上の `identifying_assumptions` を decode 時に必須とする（層(1)） |
| 10 | vendor | PNE の schema を `docs/contract/pne/`、fixture を `test/fixtures/pne/sector_output_path/v1/` に置き、`MANIFEST.json` の SHA-256 とファイルの一致をテストで検査する。DME 側の mapping fixture・golden は `test/fixtures/pne/mappings/`・`golden/`（`regenerate.jl` で再生成） |
