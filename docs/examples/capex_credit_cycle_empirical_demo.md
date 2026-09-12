# 部門別CAPEX・信用循環モデル 実証統合デモ

[examples/capex_credit_cycle_empirical_demo.jl](../../examples/capex_credit_cycle_empirical_demo.jl) は、部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`）の実証化層（#241–#250）を、**series catalog → raw observation → measurement/dataset → 定常水準較正・識別診断・限定推定 → historical episode 選定 → 履歴再生 → dimension別 validation → robustness/sensitivity** の7段にわたって公開APIのみで完走する統合デモです。外部API・ネットワークアクセス・API キーを一切使わず、完全に決定的です。

> 関連 Issue: #251（`P-11`。設計は [実証統合設計](../architecture/capex_credit_cycle_empirical_integration.md) が正本） / 依存: #248（`P-8`）・#249（`P-9`）・#250（`P-10`）

## 重要: 入力データは合成（synthetic）である

本デモの入力データは**すべて合成**であり、実際の米国経済データではありません。`capex_credit_cycle_default_targets()` の定常状態を起点に `capex_run` を実行し、`ext_demand_s2`/`ext_demand_s3` を一時的に収縮させる外生パス（+ 識別診断用のゼロ平均な政策金利振動）を与えて、内部整合な「観測」時系列を生成しています。実系列の取得・ETL実装は対象外です（[実証統合設計](../architecture/capex_credit_cycle_empirical_integration.md)の対象外節）。数値の水準そのものに経済的意味はなく、**各段の入出力契約（配線）を実演すること**が目的です。

## 全体フロー

| Step | 内容 | 主な API |
|---|---|---|
| 0 | 合成 series catalog（`CapexSeriesSpec` の配列）を構築する | `CapexSeriesSpec` |
| 1 | catalog の各キーについて `CapexRawObservation` を合成し、`CapexRawDataset` を構築する（fixture モード） | `CapexRawObservation` / `CapexRawDataset` |
| 2–3 | 共通四半期軸へ整列し `CapexEmpiricalDataset` を構築する | `build_capex_empirical_dataset` |
| 4a | baseline 期間平均から定常水準ターゲットを構築し逆較正する | `calibrate_capex_credit_cycle` |
| 4b | `EB-1`–`EB-7` の推定可否を診断する | `diagnose_capex_identification` |
| 4c | 識別可能なブロックのみ限定推定し、`literature_default`/`calibrated`/`estimated` の3種の parameter set を構築する | `estimate_capex_block` / `capex_parameter_set` |
| — | 本デモ専用の合成 episode を NC-1–NC-7 で評価し、実 `H1`–`H6` registry に対しても honest に評価する | `assess_capex_episodes` |
| 5 | 3種の parameter set それぞれで episode を再生する | `capex_replay_model` / `capex_historical_replay` |
| 6 | `calibrated` run を dimension 別に検証する | `validate_capex_empirical` |
| 7 | 7 sensitivity axis の robustness を評価する | `capex_empirical_sensitivity_suite` |
| — | 全段の出力を1つの canonical artifact へ束ね、identity chain・人間可読レポートを保存する | `capex_empirical_artifact_to_dict` / `save_capex_empirical_artifact` / `capex_empirical_report` |

パイプライン全体を2回実行して identity chain の一致（決定性）を確認し、保存済み artifact を再読み込みして同一の identity が再構築できることも確認します（[実証統合設計 §12.7](../architecture/capex_credit_cycle_empirical_integration.md) 項目59–62）。

## 実行方法

```bash
# 唯一の経路: API キー不要・ネットワークアクセスなし・完全に決定的
julia --project=. examples/capex_credit_cycle_empirical_demo.jl
```

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `CCC_EMPIRICAL_DEMO_OUTDIR` | `artifacts/capex_credit_cycle_empirical_demo` | 成果物の出力先。 |

live provider 接続（`DME_DATA_MODE=rest_api`）は本デモの対象外です。本デモは fixture モード（手組みの `CapexRawObservation`）のみを使い、`DataProviderClient`・`FredClient`・`EStatClient` を生成しません。

## 生成される成果物

`CCC_EMPIRICAL_DEMO_OUTDIR`（既定 `artifacts/capex_credit_cycle_empirical_demo/`）配下に以下を保存します。`artifacts/` は `.gitignore` 済みでリポジトリには含めません（デモ実行時にローカル生成）。

| ファイル | 内容 |
|---|---|
| `artifact.json` | identity chain（`catalog_version`/`dataset_hash`/`targets_hash`/`parameter_set_hash`/`episode_hash`/`event_set_hash`/`replay_hash`）と各ファイルへの索引。 |
| `catalog.json` | series catalog snapshot（本デモの合成 catalog。`save_capex_series_catalog` と同じ形式）。 |
| `raw_observation_manifest.json` | raw observation manifest（provider の値・provider metadata。#242）。 |
| `measurement_manifest.json` | measured dataset manifest（観測方程式適用後の値・sample window・quality flags。#243）。 |
| `calibration.json` | 定常水準ターゲット・逆較正モデル・`SS` 検証・パラメータ6区分（#244）。 |
| `identification.json` | `EB-1`–`EB-7` の識別診断（#245）。 |
| `parameter_set_literature_default.json` / `parameter_set_calibrated.json` / `parameter_set_estimated.json` | parameter artifact 3種（#246）。**literature/default と calibrated/estimated を区別して並置する**。 |
| `episode.json` | 本デモ専用の合成 episode spec と NC-1–NC-7 assessment（#247）。 |
| `replay_literature_default.json` / `replay_calibrated.json` / `replay_estimated.json` | 履歴再生の result summary 3種（#248）。 |
| `validation.json` | `calibrated` run の dimension別 validation report（#249）。 |
| `robustness.json` | 7 sensitivity axis の robustness report（#250）。 |
| `report.md` | 人間可読レポート（identity chain・episode assessment・validation/robustness 要約・caveats）。 |
| `determinism_check.json` | 2回実行の identity chain 一致確認（[実証統合設計 §12.7](../architecture/capex_credit_cycle_empirical_integration.md) 項目60）。 |

## 実行結果

`run_capex_credit_cycle_empirical_demo` は次の確認をすべて行い、真偽値を返り値に含めます（[test/test_capex_credit_cycle_empirical_demo.jl](../../test/test_capex_credit_cycle_empirical_demo.jl) がCIで検証）。

- `determinism_ok`: パイプラインを2回実行して `dataset_hash`/`targets_hash`/`parameter_set_hash`/`episode_hash`/`replay_hash` が一致する。
- `reload_ok`: 保存済み `artifact.json`（+ 分離ファイル）から `load_capex_empirical_artifact` で同一の identity chain を再構築できる。
- `accounting_ok`: `calibrated` run の会計恒等式検証12項目がすべて `acc_pass` になる。
- `episode_status`: 本デモ専用の合成 episode の NC-1–NC-7 判定（実データに対する `H1` の判定とは無関係）。
- `registry_selected`: 実 `H1`–`H6` registry（`CAPEX_CC_EPISODE_SPECS`）のうち本デモの合成データで `:selected` となった候補（選定ロジック自体は [test/test_capex_credit_cycle_history.jl](../../test/test_capex_credit_cycle_history.jl) で別途検証済み。本デモの合成データが実候補のいずれかを選定することは想定していない）。

### なぜ本デモの合成 episode は `:selected` にならないのか

`assess_capex_episodes` の `NC-2`（需要・CAPEX・信用・雇用の時間順序、[実証戦略 §9.1](../models/capex_credit_cycle_empirical_strategy.md)）は `order_s2`・`capex_exec_s1`・`spread`・`emp_tot` の4系列すべてが深さ閾値を超えることを要求します。本デモの合成ショックは前3系列を大きく動かしますが、`emp_tot` はモデル上ごく小さい部門別雇用（`emp_s1`+`emp_s2`+`emp_s3` の合計）にしか反応せず、`dl` 閾値（-0.5%）に対してわずかに届きません。これは実装のバグではなく、**本デモの合成ショックの設計上の限界**として `episode.json`／`report.md` に構造化して記録します（fit を見て事後的に基準を緩めることはしません、実証戦略 §9.2 契約1）。

## 結果の限界・禁止される解釈

[実証統合設計 §10.4・§11.4](../architecture/capex_credit_cycle_empirical_integration.md)・[llm_safety.md](../llm_safety.md) を適用します。

1. point-in-time replay ではなく、現在利用可能な（本デモでは合成の）データによる履歴再生である。
2. fit は因果妥当性・景気後退確率・投資助言ではない（ADR 0012 決定24）。
3. `P`/`allocation` 系列と direct 観測を `evidence_tier` で区別する（本デモは全系列を `:direct` として簡略化しており、実データの観測可能性分類を代表しない）。
4. 弱識別（`W1`–`W4`）パラメータは点推定せず、範囲・複数仕様・降格として扱う。
5. 企業開示を較正入力に用いていない（本デモはそもそも企業データを使わない）。
6. `:as_of` は実装していない。「その時点で判断できた」「当時利用可能だった情報で再現した」とは述べない（`Z-21`）。
7. `SH-EXP`（event magnitude）の走査結果は較正値ではない。
8. 表現できないイベント・model boundary を近似で寄せない。本デモは事象を持たない baseline 型の episode のみを使う。
9. `Digital Shadow` / `Digital Twin` を名乗らない（[ADR 0014](../adr/0014-digital-twin-naming-conditions.md)）。
10. 入力データはすべて合成であり、実在企業・実在イベント・実数値を参照しない。
11. 本出力は投資判断・政策立案の根拠として使用することを意図していない。

## 関連ドキュメント

- [実証統合設計](../architecture/capex_credit_cycle_empirical_integration.md)（本デモの正本仕様、§3.1・§4.3・§10.4・§11・§12.7）
- [部門別CAPEX・信用循環モデル 観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md)
- [部門別CAPEX・信用循環モデル](../models/capex_credit_cycle.md)（本デモが実演するモデルの解説）
- [部門別CAPEX・信用循環モデル 統合デモ](capex_credit_cycle_demo.md)（Phase 1 API、`Sc0`–`Sc4` の理論シナリオ版デモ）
- [日付付き複数イベントScenario統合デモ](event_driven_capex_scenario_demo.md)（イベント駆動シナリオ版デモ）
- [ADR 0012: 部門別CAPEX・信用循環モデルの実証化契約](../adr/0012-capex-credit-cycle-empirical-contract.md)
- [ADR 0018: 部門別CAPEX・信用循環モデルの実証実装契約](../adr/0018-capex-credit-cycle-empirical-runtime-contract.md)
- [ADR 0014: Digital Twin / Digital Shadow の名称使用条件](../adr/0014-digital-twin-naming-conditions.md)
- [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)
