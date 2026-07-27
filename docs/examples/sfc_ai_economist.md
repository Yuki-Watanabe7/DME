# SFC対応 AIエコノミスト統合デモ

[examples/sfc_ai_economist_demo.jl](../../examples/sfc_ai_economist_demo.jl) は、最小 SIM 型 SFC モデルを「AIエコノミスト」として一連のフローで実演する統合デモです。**baseline / 財政ショックシナリオの構築から会計恒等式検証、モデル能力・概念定義 metadata、比較 API v2、Keen–SFC 概念対応・比較レポート、根拠付き LLM 説明、成果物保存までを再現可能に完走**します。外部データ取得や乱数を一切使わないため、API キー不要・完全に決定的です。

> 関連 Issue: #152

## 全体フロー

| Step | 内容 | 主な API |
|---|---|---|
| 1 | baseline（`H0=0.0` から出発）と財政支出の恒久的増加ショックの 2 シナリオを構築 | `simulate` / `impulse_response`（[`SIMModel`](../models/sim_sfc.md)） |
| 2 | 部門別貸借対照表・取引フロー・valuation adjustment を全期構成し、会計恒等式を検証 | [`sfc_result`](../models/sim_sfc.md) / [`validate_sfc_accounting`](../api.md#sfc-会計恒等式検証エンジンvalidate_sfc_accounting) |
| 3 | SIM・Keen の能力プロファイル・概念定義 metadata を出力 | [`model_capabilities`](../model_capabilities.md) |
| 4 | デモ用に生成した決定的な合成「実データ」proxy に比較 API v2 を適用（日付整列・proxy mapping・比較可能性評価） | [`compare_results_v2`](../architecture/cross_model_reasoning.md) |
| 5 | Keen–SFC の概念対応・非対応・構造差・数値比較可否をまとめたレポートを生成 | [`compare_keen_sfc`](../analysis/keen_sfc_comparison.md) |
| 6 | ADR 0006 の LLM provider 抽象・source registry・決定的 fallback を用いた根拠付き構造化説明を生成 | [`explain_keen_sfc_comparison`](../analysis/keen_sfc_comparison.md) |
| 7 | baseline / 財政ショックの主要系列と家計貨幣資産の比較図を保存 | `plot_result` / `plot_comparison` |
| 8 | 会計表・検証結果・能力 metadata・比較結果・説明・provenance を run 単位で保存 | `save_sfc_result` / `to_json` |

## 実行方法

```bash
# offline（既定・唯一の経路）: API キー不要・完全に決定的（RNG を使わない）
julia --project=. examples/sfc_ai_economist_demo.jl
```

このデモは実データ接続を持ちません（SIM 型 SFC モデルは実データ接続の設計を持たないため、比較 API v2 の実演にはデモ内で決定的に生成した合成 proxy を用います）。切り替えが必要なのは LLM provider のみです。

```bash
# 実 LLM（OpenAI）で provider 往復を実演する場合
export OPENAI_API_KEY=sk-...       # https://platform.openai.com/api-keys
julia --project=. examples/sfc_ai_economist_demo.jl
```

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `OPENAI_API_KEY` | 未設定 | 設定時のみ `OpenAIProvider`。未設定なら `MockLLMProvider`。 |
| `SFC_AI_DEMO_OUTDIR` | `artifacts/sfc_ai_economist` | 成果物の出力先。 |

> **provider 経路の扱い**: 保存する説明成果物は決定的な `deterministic` 生成を正とします。`provider` を接続した場合は応答を契約検証（schema・source・安全性）し、通過した場合のみ採用（`parsed`）、未通過は安全側 fallback を記録します（数値・保存物は不変）。汎用 mock 応答はクロスモデル推論の契約を満たさないため `fallback` となり、これは安全機構が働いていることの実演です。

## 生成される成果物

`SFC_AI_DEMO_OUTDIR`（既定 `artifacts/sfc_ai_economist/`）配下に以下を保存します。`artifacts/` は `.gitignore` 済みでリポジトリには含めません（デモ実行時にローカル生成）。

| ファイル | 内容 |
|---|---|
| `sfc_result_baseline.json` | baseline の部門別貸借対照表・取引フロー・valuation adjustment・methodology を全期分含む `SFCResult`（[`save_sfc_result`](../models/sim_sfc.md) で保存・`load_sfc_result` で復元可能）。 |
| `sfc_result_fiscal_shock.json` | 財政ショックシナリオの同上。 |
| `accounting_checks.json` | 両シナリオの [`AccountingCheckReport`](../api.md#sfc-会計恒等式検証エンジンvalidate_sfc_accounting)（全 check・pass 件数・最大残差・invalid 期）。 |
| `model_capabilities.json` | SIM・Keen の能力プロファイル metadata（[#149](../model_capabilities.md)）。 |
| `comparison_v2.json` | 合成「実データ」proxy との比較 API v2 結果（assessment・alignment・metrics・warnings）。 |
| `keen_sfc_comparison.json` | Keen–SFC 概念対応・非対応・構造差・数値比較可否の構造化レポート（[#151](../analysis/keen_sfc_comparison.md)）。 |
| `keen_sfc_explanation.json` | 根拠付き構造化説明。section・claim（認識論的性質 + source id）・source references・警告・免責。 |
| `run_manifest.json` | **再現性・provenance**。シナリオパラメータ、会計検証の pass/fail、各層の契約 version、LLM provider/model、実行日時、警告一覧。 |
| `report.md` | 人が読むサマリー。会計恒等式の成立状況、財政赤字と部門別金融収支の対応、比較 API v2 の結果、Keen–SFC の説明を **source id で相互参照可能**に統合。 |
| `sfc_baseline_trajectories.png` / `sfc_fiscal_shock_trajectories.png` / `sfc_household_wealth_comparison.png` | baseline・財政ショックの主要系列（Y, C, H）と、家計貨幣資産 H の baseline vs 財政ショック比較図。 |

### 再現性・provenance

- **決定性**: 乱数を一切使わず、比較 API v2 用の合成データも closed-form（sin/cos）で生成するため、同一パラメータで意味的に同一の数値・説明成果物を生成します（CI smoke test [test/test_sfc_ai_economist_demo.jl](../../test/test_sfc_ai_economist_demo.jl) が検証）。
- **provenance**: `run_manifest.json` に code revision（git HEAD）・各層の契約 version・LLM provider/model・実行日時・警告一覧を記録します。**API キー等の秘密情報は成果物に一切含めません**（smoke test が検証）。
- **非有限値の扱い**: 会計検証・比較 API v2 の残差・指標に非有限値（NaN/Inf）が生じても 0 化・削除せず、文字列タグ（`"NaN"`/`"Inf"`/`"-Inf"`）へ符号化して保存します（`src/sfc/serialization.jl` の規約と同じ）。
- **失敗の非隠蔽**: 会計恒等式に違反がある fixture を渡した場合、`validate_sfc_accounting` が `acc_fail`/`acc_invalid` を返し、`compare_keen_sfc` の `accounting_report` 経由で `SFC_ACCOUNTING_VIOLATION` warning として構造化される（正常扱いしない）。

## 結果の限界・禁止される解釈

- SIM は金融不安定性・企業債務・分配動学・危機regime を持たない大域安定な需要決定モデルである。
- 比較 API v2 に用いる「実データ」は本デモ用に生成した決定的な合成 proxy であり、観測データではない。
- Keen 側の産出水準 `Y` は既定 `simulate` 出力（ω, λ, d）に含まれないため、捏造せず比較不能（`skipped_comparisons`）として扱う。
- Keen–SFC の比較不能概念（民間債務・資金調達区分・賃金/利潤シェア・雇用率・会計閉鎖等）には数値 metric を生成しない。
- SIM の会計恒等式が保証するのは内的整合性であって現実妥当性ではない。
- 本デモは投資助言・危機確率・政策最適性の自動化を目的としない。

## 関連ドキュメント

- [最小 SIM 型 SFC モデル](../models/sim_sfc.md) / [Keen モデル](../models/keen.md)
- [Keen–SFC 概念対応・比較レポート](../analysis/keen_sfc_comparison.md) / [モデル能力・概念定義 metadata](../model_capabilities.md)
- [クロスモデル推論層の設計](../architecture/cross_model_reasoning.md) / [ADR 0006: クロスモデル推論契約](../adr/0006-cross-model-reasoning-contract.md)
- [ADR 0007: SFC 統合契約](../adr/0007-sfc-integration-contract.md)
- [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)
- [Keen 実証 AIエコノミスト統合デモ](keen_empirical_ai_economist.md)（同種の統合デモ・実データ接続あり版）
