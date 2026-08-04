# 部門別CAPEX・信用循環モデル 統合デモ

[examples/capex_credit_cycle_demo.jl](../../examples/capex_credit_cycle_demo.jl) は、部門別CAPEX・信用循環モデルの `Sc0`（baseline）〜`Sc4`（需要期待下方修正 + CAPEX削減 + 信用ショック + 金融緩和）を比較する統合デモです。**シナリオ実行 → 会計恒等式検証（12項目）→ 診断（ラベル・資金繰り・ループ利得・非線形性近傍・反実仮想寄与）→ 閾値感応度 → 判定問題Q2–Q4の回答 → 比較API v2（mechanismモード）→ 可視化 → 成果物のrun単位保存**までを再現可能に完走します。外部データ取得・LLM呼び出し・乱数を一切使わないため、API キー不要・ネットワークアクセスなし・完全に決定的です。

> 関連 Issue: #186（`I-8`。設計上の判断は #163〜#171 で確定済み）

## 全体フロー

| Step | 内容 | 主な API |
|---|---|---|
| 1 | 例示定常水準から逆較正でモデルを構築し、定常条件（SS-1–SS-17）を確認する | `capex_credit_cycle_model` / `capex_credit_cycle_default_targets` / `capex_steady_state_report` |
| 2 | `Sc0`–`Sc4`を実行し、会計恒等式12項目を検証、診断（ラベル・資金繰り・ループ利得・非線形性近傍・`A`・`share_C`）と閾値±50%感応度を計算する | `capex_scenario` / `capex_exogenous_paths` / `capex_run` / `validate_capex_accounting` / `capex_diagnostics` / `capex_label_sensitivity` |
| 3 | 判定問題 Q2（`A`, Sc3）・Q3（`share_C`, Sc2/Sc3、主方式+加法分解+残差比）・Q4（Sc3 vs Sc4 の波及遮断比較）の回答を構成する | `diag.amplification` / `diag.share_c` / `diag.share_c_additive` / `diag.peaks` |
| 4 | `Sc0` vs `Sc3` を比較API v2の `mechanism` モードで比較する（同一モデル内のシナリオ比較。能力metadataの構造化差分を返す） | `compare_results_v2`（[クロスモデル推論層](../architecture/cross_model_reasoning.md)） |
| 5 | `Sc3`の部門別系列・シナリオ比較（`dY`/`dI`/`dC`）・診断ラベル帯・`funding_pressure`帯を描画する | `plot_capex_sector_series` / `plot_capex_scenario_comparison` / `plot_capex_diagnostic_label` / `plot_capex_funding_pressure` |
| 6 | シナリオ別・判定問題・比較結果・provenanceをrun単位で保存する | `to_json` / `JSON3.write` |

## 実行方法

```bash
# 唯一の経路: API キー不要・ネットワークアクセスなし・完全に決定的（RNG を使わない）
julia --project=. examples/capex_credit_cycle_demo.jl
```

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `CAPEX_CC_DEMO_OUTDIR` | `artifacts/capex_credit_cycle_demo` | 成果物の出力先。 |

このデモは実データ接続・LLM呼び出しを持ちません（初期MVPは実データ較正・LLM根拠付き説明の対象外。[分析契約](../models/capex_credit_cycle_analysis_contract.md) 対象外節・[観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md)を参照）。切り替え可能な設定は出力先のみです。

## 生成される成果物

`CAPEX_CC_DEMO_OUTDIR`（既定 `artifacts/capex_credit_cycle_demo/`）配下に以下を保存します。`artifacts/` は `.gitignore` 済みでリポジトリには含めません（デモ実行時にローカル生成）。

| ファイル | 内容 |
|---|---|
| `capex_scenario_Sc0.json` .. `capex_scenario_Sc4.json` | シナリオ別の基礎系列（`capex_exec_s1`・`invest_s2`/`_s3`・`order_s2`/`_s3`・`util_s2`/`_s3`・`inv_ratio_s2`/`_s3`・`spread`・`debt_s1`–`_s3`・`emp_tot`・`hh_income`・`cons`・`y_tot`）・baseline比乖離・診断ラベル・`G1`–`G4`充足状況・`breadth`・資金繰り診断（部門別`funding_pressure_s`と滞在比率）・ループ診断（`active(R1a)`–`active(R4)`・`gain(loop)`・`ρ_t`系列と最大値・`g_short`）・会計検証要約（12項目×28期の`acc_pass`件数・違反有無・`max_abs_residual`）・閾値±50%感応度。 |
| `capex_judgment_questions.json` | Q2の増幅度`A`（Sc3）・Q3の消費経路寄与`share_C`（Sc2/Sc3、主方式・加法分解・残差比）・Q4のSc3 vs Sc4比較（`peak(dY)`・回復時点）。 |
| `capex_comparison_v2.json` | `compare_results_v2`の`mechanism`モード比較結果（Sc0 vs Sc3、能力metadataの構造化差分。同一モデルのため差分は生じない）。 |
| `capex_run_manifest.json` | **再現性・provenance**。シナリオ別終了状態・会計検証pass状況・契約version（8種+診断閾値セット）・Sc3を代表とする`metadata`予約キー20個の全内容・全シナリオの警告一覧・注意事項7件。 |
| `report.md` | 人が読むサマリー。シナリオ別診断ラベル・会計検証・判定問題Q2–Q4の回答・資金繰り診断・保存成果物一覧・注意事項。 |
| `capex_sector_series_Sc3.png` | Sc3の部門別系列（受注・稼働率・在庫比率・CAPEX・債務、5パネル）。 |
| `capex_scenario_comparison.png` | `Sc0`–`Sc4`の`dY`（総産出相対乖離）・`dI`（CAPEX合計絶対乖離）・`dC`（消費相対乖離）比較。 |
| `capex_diagnostic_label_Sc3.png` | Sc3の診断ラベル帯と`G1`–`G4`超過帯。 |
| `capex_funding_pressure_Sc3.png` | Sc3の部門別`funding_pressure_s`帯（`S1`–`S3`）。 |

### 再現性・provenance

- **決定性**: 乱数を一切使わず、シナリオ・診断・判定問題・比較API v2の成果物は同一パラメータで完全に一致します（CI smoke test [test/test_capex_credit_cycle_demo.jl](../../test/test_capex_credit_cycle_demo.jl) が検証）。`capex_run_manifest.json` の `run_timestamp`/`code_revision` のみ実行ごとに変わります。
- **provenance**: `capex_run_manifest.json` に code revision（git HEAD）・全8契約version・診断閾値セット・実行日時・シナリオ別警告一覧を記録します。**API キー等の秘密情報は成果物に一切含めません**（smoke test が検証）。
- **非有限値の扱い**: 系列・診断量に非有限値（NaN/Inf）が生じても 0 化・削除せず、文字列タグ（`"NaN"`/`"Inf"`/`"-Inf"`）へ符号化して保存します（`src/sfc/serialization.jl` の規約と同じ）。
- **会計の失敗を隠さない**: 全シナリオで会計恒等式12項目が`acc_pass`であることをデモ・smoke testの双方で確認します。`acc_fail`が生じても診断ラベルを自動的に`indeterminate`へ変更せず、違反として併記する契約です。

## 結果の限界・禁止される解釈

1. パラメータは例示値であり実データによる較正を経ていない。系列の水準の絶対値に意味はなく、baseline比乖離の符号・順序・大小関係のみが解釈対象である。
2. 診断ラベル `broad_downturn` はモデル内の診断であり、景気後退の予測・確率ではない。
3. `A` と `share_C` は同一実装内の反実仮想寄与であり因果推定ではない。
4. `funding_pressure_s` は倒産・信用イベントの予測ではない（デフォルトを内生化していない）。
5. 会計は残差部門 `SX` を置いて閉じており、経済全体で閉じていない（`accounting_closure = :partial`）。SFC検証済みと同じ意味ではない。
6. `cost_capital_s`・`ai_exp`・`target_cap_s1`・`cancel_s1` は潜在変数であり、単独の水準を提示しない。
7. 本出力は投資判断・政策立案の根拠として使用することを意図していない。

## 関連ドキュメント

- [部門別CAPEX・信用循環モデル](../models/capex_credit_cycle.md)（本デモが実演するモデルの解説）
- [部門別CAPEX・信用循環モデル 分析契約](../models/capex_credit_cycle_analysis_contract.md)（判定問題Q1–Q5・比較シナリオSc0–Sc4）
- [部門別CAPEX・信用循環モデル 統合設計](../architecture/capex_credit_cycle_integration.md) §8（本デモの正本仕様）
- [ADR 0013: 部門別CAPEX・信用循環モデルの統合実装契約](../adr/0013-capex-credit-cycle-integration-contract.md)
- [ADR 0014: Digital Twin / Digital Shadow の名称使用条件](../adr/0014-digital-twin-naming-conditions.md)
- [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)
- [SFC対応 AIエコノミスト統合デモ](sfc_ai_economist.md)（同種の統合デモ・会計恒等式検証あり版）
