# Keen–SFC 比較の LLM 応答 fixture

Issue #151（Keen–SFC 概念対応・非対応と比較レポート）の LLM 回帰・安全性評価で使う固定応答。
すべて `CROSS_MODEL_OUTPUT_CONTRACT_VERSION`（`cross-model-output/1.0.0`）に従う JSON で、
`test/test_keen_sfc_comparison.jl` から `KSFCFixtureProvider` 経由で再生される。外部通信はしない。

| ディレクトリ | 役割 |
|---|---|
| `forbidden/` | **schema・source 検証は通る**が、Keen–SFC 固有の禁止解釈を含む応答。安全性評価器（`ksfc_safety_violations`）が検出できることを回帰で保証する。 |

## forbidden fixture 一覧

| ファイル | 禁止解釈 | 期待する検出 rule |
|---|---|---|
| `government_liability_as_private_debt.json` | SIM の政府貨幣 `H`（政府負債）を Keen の民間債務 `d` と同一視する | `:debt_concepts_conflated` |
| `sim_financial_instability.json` | SIM 出力から資金調達区分・危機regime など SIM に存在しない金融不安定性指標を生成する | `:sim_financial_instability` |
| `incompatible_as_equivalent.json` | 比較不能（incompatible）な概念を equivalent／同一指標として統合する | `:incompatible_as_equivalent` |

## 追加・再生成手順

1. `explain_keen_sfc_comparison(compare_keen_sfc())` の決定的出力を `to_json` して雛形にする。
2. 検査したい section の claim だけを差し替える。`source_ids` は
   `build_keen_sfc_comparison_context()` の `sources` に存在する ID のみを使う
   （例 `mapping.keen.sim.private_debt`, `concept.keen.private_debt_credit`,
   `limitation.cross_model_contract`）。
3. `epistemic_status` と source の category の対応（`metadata`↔`model_concept` /
   `mapping`↔`concept_mapping` / `empirical`↔`empirical_evidence`）を守る。守らないと
   production parser が先に拒否してしまい、安全性評価器の回帰にならない。
4. `test/test_keen_sfc_comparison.jl` の期待 rule 表へ 1 行足す。

詳細は [Keen–SFC 概念対応・比較レポート](../../../../docs/analysis/keen_sfc_comparison.md) を参照。
