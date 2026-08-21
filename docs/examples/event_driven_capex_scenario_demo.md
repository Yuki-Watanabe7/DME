# 日付付き複数イベントScenario 統合デモ

[examples/event_driven_capex_scenario_demo.jl](../../examples/event_driven_capex_scenario_demo.jl) は、部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`）に対し、暦日付きイベント（`ObservedEvent`/`InterpretedSignal`/`ScenarioAssumption`）から `run_scenario` を通じて決定的に `SimulationResult` を得るまでの経路を実演する統合デモです。**8ケースの実行 → `Sc0`–`Sc4`（理論シナリオ）との数値互換性確認 → 9イベント型カバレッジ確認 → 決定性・replay確認 → 成果物のケース単位保存**までを再現可能に完走します。外部データ取得・LLM呼び出し・乱数を一切使わないため、API キー不要・ネットワークアクセスなし・完全に決定的です。

> 関連 Issue: #205（`E-9`。設計は #196・[イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md) が正本）

## Phase 1 API との使い分け

このパッケージには、シナリオを表現する経路が2つ並置されています（[統合設計 §8.1](../architecture/macro_event_runtime_integration.md#81-決定)、非推奨化しない決定）。

| 経路 | 型・API | 表現する対象 | 使う場面 |
|---|---|---|---|
| Phase 1（理論シナリオ） | `CapexShockSpec` / `CapexScenario` / `capex_scenario(id)` / `capex_exogenous_paths` | 暦日・出所・解釈シグナルを持たない、分析者が定義した抽象的なショック仕様（`Sc0`–`Sc4`） | 「もしCAPEXが8%下方修正されたら」のような理論的な感応度分析 |
| Phase 2（イベント駆動） | `ObservedEvent`/`InterpretedSignal`/`ScenarioAssumption` の4層・`Scenario`・`run_scenario` | 観測事実（暦日・出所・確信度）に由来する仮定と、その適用の監査可能な記録 | 「1月18日に報じられた需要見通し下方修正を四半期へ割り当てて適用したら」のような、日付付きの複数イベントを追跡可能な形で扱う分析 |

本デモは後者（Phase 2）を実演します。`capex_scenario_assumptions(id)` は前者を後者へ変換するアダプタであり、両経路が同一の外生パスを生成することを [Step 3（後述）](#実行結果) で数値的に確認します。

## 全体フロー

| Step | 内容 | 主な API |
|---|---|---|
| 1 | 部門別CAPEX・信用循環モデルを構築する | `capex_credit_cycle_model` / `capex_credit_cycle_default_targets` |
| 2 | 8ケース（下表）の `ScenarioAssumption` 集合を構築し、`run_scenario` で実行、成果物7種を `<outdir>/<case_id>/` へ保存する | `scenario_assumption` / `Scenario` / `run_scenario` / `scenario_comparison` / `save_scenario_artifact` |
| 3 | `capex_scenario_assumptions(id)` 経由の `run_scenario` の `exog`/`SimulationResult` が `capex_exogenous_paths`/`simulate` の経路と**完全一致**（許容誤差0）することを `Sc0`–`Sc4` 全件で確認する | `capex_scenario_assumptions` / `capex_exogenous_paths` / `run_scenario` |
| 4 | 9イベント型（`MACRO_EVENT_TYPES`）それぞれが、mapping可能（E2E経路を通る）または mapping不能理由が固定される（`unmapped_target`）のいずれかで登場することを確認する | `run.applied_inputs` / `run.rejections` |
| 5 | 全ケースを2回実行し、成果物ファイルが完全一致すること（決定性）を確認する | `run_scenario`（2回） |
| 6 | 保存済み `scenario.json` から `replay_scenario` を実行し、同一結果を再現することを確認する | `replay_scenario` |
| 7 | デモ全体の provenance・確認結果・注意事項をまとめて保存する | `canonical_json_bytes` |

## 8ケース

| ケース | 内容 | 登場するイベント型 | 期待status |
|---|---|---|---|
| `baseline` | eventなし（正当なbaseline） | — | `:completed` |
| `demand_outlook_down` | AI需要見通しの下方修正 | `:DemandOutlookRevision` | `:completed` |
| `capex_cut_order_cancel` | 上記 + CAPEXガイダンス削減・受注キャンセル | `:CapexGuidanceRevision`・`:OrderCancellation` | `:completed` |
| `credit_tightening` | 上記 + credit spread拡大・lending standard引締め | `:CreditSpreadShock`・`:LendingStandardChange` | `:completed`（`on_unmapped=:warn`） |
| `policy_easing` | 上記 + policy rate緩和・価格/利益率ショック・格付イベント | `:PolicyRateChange`・`:PriceOrMarginShock`・`:RefinancingOrRatingEvent` | `:completed`（`on_unmapped=:warn`） |
| `simultaneous_composition` | 同一四半期の複数イベントの決定論的合成（offsetting含む） | `:CreditSpreadShock`・`:DemandOutlookRevision` | `:completed` |
| `negative_unmapped` | unmapped eventを含む negative fixture | `:PriceOrMarginShock`（S2）・`:RefinancingOrRatingEvent`（`maturity_wall`）・`:EmploymentPlanRevision` | `:rejected_mapping`（既定 `on_unmapped=:reject`） |
| `negative_invalid` | 構造的に invalid（`duplicate_event_id`） | — | `:rejected_validation` |

`credit_tightening`・`policy_easing` は `:LendingStandardChange`（貸出態度の変化、`unmapped_target`・`D2`）を含むため `on_unmapped=:warn` で実行します。既定の `on_unmapped=:reject`（fail closed）では `:rejected_mapping` になります。`negative_unmapped` は既定のまま実行し、`:PriceOrMarginShock`（S2、`D1`）・`:RefinancingOrRatingEvent`（`maturity_wall`理由、`D3`）・`:EmploymentPlanRevision`（`D4`）の3件がいずれも `unmapped_target` として拒否され、モデルを実行せずに完全に停止することを確認します。

9イベント型のうち mapping可能な6型（`:DemandOutlookRevision`・`:CapexGuidanceRevision`・`:OrderCancellation`・`:CreditSpreadShock`・`:RefinancingOrRatingEvent`（既定reason）・`:PolicyRateChange`）と、mapping不能理由が固定される3型（`:PriceOrMarginShock`(S2)・`:LendingStandardChange`・`:EmploymentPlanRevision`）がすべて登場します（統合設計 §10.6 項目2）。

## 実行方法

```bash
# 唯一の経路: API キー不要・ネットワークアクセスなし・完全に決定的（RNG を使わない）
julia --project=. examples/event_driven_capex_scenario_demo.jl
```

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `EDCS_DEMO_OUTDIR` | `artifacts/event_driven_capex_scenario_demo` | 成果物の出力先。 |

## 生成される成果物

`EDCS_DEMO_OUTDIR`（既定 `artifacts/event_driven_capex_scenario_demo/`）配下に以下を保存します。`artifacts/` は `.gitignore` 済みでリポジトリには含めません（デモ実行時にローカル生成）。

| ファイル | 内容 |
|---|---|
| `<case_id>/scenario.json` | `Scenario`（`ScenarioAssumption` 集合を含む）。**replayの唯一の入力**（統合設計 §9.5）。 |
| `<case_id>/observed_events.json` | `ObservedEvent`/`InterpretedSignal`（`L1`/`L2`）の原本。監査用であり replay には用いない。`demand_outlook_down` ケースのみ非空（観測→仮定への遡及を実演）。 |
| `<case_id>/event_log.json` | イベント実行ログ14項目（original event ID・mapping・適用前後値・警告・拒否理由等）。 |
| `<case_id>/manifest.json` | 再現契約（`params_hash`/`initial_state_id`/`solver_settings_hash`/`event_set_hash`）・status・警告/拒否件数。 |
| `<case_id>/result_summary.json` | `SimulationResult.metadata`（イベント層予約キーを含む）と主要系列。 |
| `<case_id>/comparison.json` | `scenario_comparison`（baselineとの比較診断）。`baseline`ケース自身と `:rejected_*` ケースでは省略。 |
| `<case_id>/report.md` | ケース単位の人が読むサマリー。 |
| `sc0_sc4_parity.json` | `Sc0`–`Sc4` 数値互換性確認の結果（許容誤差0）。 |
| `event_type_coverage.json` | 9イベント型それぞれの mapping可否・登場ケース。 |
| `demo_manifest.json` | デモ全体のprovenance・決定性/replay確認結果・注意事項8件。 |
| `report.md` | デモ全体の人が読むサマリー。 |

## 実行結果

`run_event_driven_capex_scenario_demo` は次の確認をすべて行い、真偽値を返り値に含めます（[test/test_event_driven_scenario_demo.jl](../../test/test_event_driven_scenario_demo.jl) がCIで検証）。

- `all_status_ok`: 全8ケースが期待どおりの `status` で完走/拒否される。
- `sc0_sc4_parity.all_pass`: `Sc0`–`Sc4` の `exog`・`SimulationResult.variables` が Phase 1 経路と完全一致する。
- `event_type_coverage["all_covered"]`: 9イベント型すべてが mapping可能またはmapping不能理由固定で登場する。
- `determinism_ok`: 全ケースを2回実行して全成果物ファイルが完全一致する。
- `replay_ok`: `policy_easing` ケースの保存済み `scenario.json` から `replay_scenario` を実行し、同一の `exog`・`SimulationResult.variables`・警告順序を再現する。

### 再現性・provenance

- **決定性**: 乱数を一切使わず、全ケースの成果物は同一パラメータで完全に一致します（CI smoke test [test/test_event_driven_scenario_demo.jl](../../test/test_event_driven_scenario_demo.jl) が検証）。
- **provenance**: `demo_manifest.json` に code revision（git HEAD）・4契約version（`event_runtime_version`/`event_contract_version`/`time_semantics_version`/`event_mapping_version`）・実行日時・ケース別警告/拒否コードを記録します。**API キー等の秘密情報は成果物に一切含めません**（smoke test が検証）。
- **golden fixture**: [test/fixtures/scenarios/event_driven_capex/](../../test/fixtures/scenarios/event_driven_capex/) に `baseline.json`・`positive_multi_event.json`（`policy_easing` 相当）・`negative_unmapped.json` を保存しています（`source.kind == "golden"`。`test/fixtures/events/` の `"illustrative"` 参考資料とは異なり、テストがプログラム的に読み込みます、`Y-25`）。デモ本体の変更で fixture が陳腐化しないよう、`test/fixtures/scenarios/event_driven_capex/regenerate.jl` はデモのケース構築関数を再利用して fixture を再生成します。

## 結果の限界・禁止される解釈

[統合設計 §12.3（LLM説明層への必須記載事項）](../architecture/macro_event_runtime_integration.md#123-llm-説明層への必須記載事項)を、[LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)と併せて適用します。

1. どのイベントが観測に基づき、どのイベントが仮定かを `magnitude_source` に基づいて区別する（`:observed`/`:disclosed`/`:derived` と `:assumed_default`/`:external_belief` を混同しない）。
2. `:assumed_default` の仮定を含む場合、magnitude ±50%の感応度（`scenario_magnitude_sensitivity`）の結果を併記する。
3. `unmapped_target`/`unsupported_model` は「影響が無い」ことを意味しない。モデルが構造上その事象を表現しないことを示す（近い変数への代理適用は行わない）。
4. `offsetting_events` により相殺が生じた場合、net値だけでなく両側の粗値を確認できるようにする。
5. `timing_sensitive` が記録された場合、±1期ずらしの結果（`scenario_timing_sensitivity`）を併記する。
6. `timing_basis_period`（理論シナリオ、`Sc0`–`Sc4`）の結果を、暦日付きの主張として提示しない。
7. `:as_of` を実装していないため、「その時点で判断できた」「当時のデータで予測できた」とは述べない。`known_at` は監査属性であり as-of 判定には用いない。
8. `status = :terminated` の結果を完走した結果として提示しない。有効区間と打ち切り理由を明示する。

加えて:

9. パラメータ・イベントmagnitudeは fictional な例示値であり、実在企業・実在イベントを参照しない。実データによる較正を経ていない。
10. `propagation_order` はモデル内の系列順序であり、統計的因果効果ではない（`causal`/`contribution` と呼ばない）。
11. 本出力は投資判断・政策立案の根拠として使用することを意図していない。

## 関連ドキュメント

- [イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md)（本デモの正本仕様、§9.5・§10.6・§11 `E-9` 行）
- [マクロイベント変換契約](../architecture/macro_event_contract.md)（9イベント型・適用先7変数・mapping表）
- [シナリオ時間軸の意味論](../architecture/scenario_time_semantics.md)（暦日→四半期の割当規則・時間形状6種）
- [部門別CAPEX・信用循環モデル](../models/capex_credit_cycle.md)（本デモが実演するモデルの解説）
- [部門別CAPEX・信用循環モデル 統合デモ](capex_credit_cycle_demo.md)（Phase 1 API、`Sc0`–`Sc4` の理論シナリオ版デモ）
- [ADR 0010: マクロイベント変換・シナリオ時間軸契約](../adr/0010-macro-event-scenario-contract.md)
- [ADR 0015: イベント・シナリオ実行層の統合実装契約](../adr/0015-macro-event-runtime-contract.md)
- [ADR 0014: Digital Twin / Digital Shadow の名称使用条件](../adr/0014-digital-twin-naming-conditions.md)
- [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)
