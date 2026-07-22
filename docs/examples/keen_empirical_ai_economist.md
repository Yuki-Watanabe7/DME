# Keen 実証 AIエコノミスト統合デモ

[examples/keen_empirical_ai_economist.jl](../../examples/keen_empirical_ai_economist.jl) は、Keen モデルの実証分析を「AIエコノミスト」として一連のフローで実演する統合デモです。**データ取得から実証分析、根拠付き LLM 説明、クロスモデル比較、成果物保存までを再現可能に完走**します。API キーなしの offline 経路（fixture + deterministic 生成）が既定・正であり、任意で実データ・実 LLM へ切り替えられます。

## 全体フロー

| Step | 内容 | 主な API |
|---|---|---|
| 1 | offline fixture / provider から実証系列を読み込み、測定変換・欠損処理・期間整合を行って `KeenEmpiricalDataset` を構築 | [`build_keen_empirical_dataset`](../data/fred.md) |
| 2 | 限定キャリブレーション → in-sample / out-of-sample 検証 → observed proxy regime 診断 → 感応度分析 | `keen_default_calibration_config` / `validate_keen` |
| 3 | 拡張 `AnalysisContext` へ Keen 実証成果物と methodology metadata を格納（`keen_empirical`） | [`KeenEmpiricalContext`](../architecture/analysis_context.md) |
| 4 | 根拠付き構造化説明を生成（認識論的性質を分離した必須 section・source 参照・警告・免責） | [`explain_keen_empirical_result`](../adr/0005-keen-ai-explanation-contract.md) |
| 5 | 既存モデル（RBC / IS-LM）とのクロスモデル比較を生成（同名変数の非同一視・比較不能の非統合） | [`build_cross_model_comparison_context`](../architecture/cross_model_reasoning.md) / `explain_cross_model_comparison` |
| 6 | 実データ・モデル軌跡・regime・感応度・診断の可視化を保存 | `plot_keen_empirical_trajectories` ほか |
| 7 | 数値・図表・context・説明・provenance を run 単位で保存 | `save_keen_empirical_report` / `to_json` |

## 実行方法

```bash
# offline（既定・正）: fixture データ + MockLLMProvider、API キー不要・決定的
julia --project=. examples/keen_empirical_ai_economist.jl
```

### 実データ・実 LLM への切り替え

同一の公開契約のまま、環境変数で取得モードと LLM provider を切り替えます。

```bash
# 実データ（FRED）+ MockLLM
export DME_DATA_MODE=live
export FRED_API_KEY=...            # https://fred.stlouisfed.org/docs/api/api_key.html
julia --project=. examples/keen_empirical_ai_economist.jl

# 実データ + 実 LLM（OpenAI）
export DME_DATA_MODE=live
export FRED_API_KEY=...
export OPENAI_API_KEY=sk-...       # https://platform.openai.com/api-keys
julia --project=. examples/keen_empirical_ai_economist.jl
```

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `DME_DATA_MODE` | `fixture` | `fixture`（固定 JSON・決定的）/ `live`（FRED API）/ `rest_api`（economic-data-provider REST）。source unavailable 時に fixture へ暗黙 fallback せず、失敗理由を表示して停止する。 |
| `FRED_API_KEY` | 未設定 | `live` モードで必要。 |
| `OPENAI_API_KEY` | 未設定 | 設定時のみ `OpenAIProvider`。未設定なら `MockLLMProvider`。 |
| `KEEN_AI_DEMO_OUTDIR` | `artifacts/keen_empirical_ai_economist` | 成果物の出力先。 |

> **provider 経路の扱い**: 保存する説明成果物は決定的な `deterministic` 生成を正とします。`provider` を接続した場合は応答を契約検証（parse）し、通過した場合のみ採用（`parsed`）、未通過は安全側 fallback を記録します（数値・保存物は不変）。汎用 mock 応答は Keen 契約を満たさないため `fallback` となり、これは安全機構が働いていることの実演です。

## 生成される成果物

`KEEN_AI_DEMO_OUTDIR`（既定 `artifacts/keen_empirical_ai_economist/`）配下に以下を保存します。`artifacts/` は `.gitignore` 済みでリポジトリには含めません（デモ実行時にローカル生成）。

| ファイル | 内容 |
|---|---|
| `run_manifest.json` | **再現性・provenance**。データ系列 ID・取得元・観測期間・取得/fixture モード、変換・集計方法、推定設定（seed・n_starts・推定対象）、methodology / contract / prompt version、LLM provider/model、実行日時、警告一覧。 |
| `keen_empirical_report.json` | dataset provenance + validation の機械可読レポート。 |
| `keen_validation.json` | 検証・感応度分析の詳細。 |
| `keen_calibration_config.json` | 推定設定（固定/推定パラメータ・bounds・weight）。 |
| `keen_ai_explanation.json` | 根拠付き構造化説明。section・claim（認識論的性質 + source id）・source references・警告・免責。 |
| `cross_model_reasoning.json` | クロスモデル比較。概念対応・比較不能（`insufficient_comparability`）の明示。 |
| `report.md` | 人が読むサマリー。数値レポートと LLM 説明を **source id で相互参照可能**に統合。 |
| `keen_trajectories.png` 他 | 実データ・モデル軌跡・regime 比較・感応度・calibrated 診断の図。 |

### 再現性・provenance

- **決定性**: fixture + deterministic 生成は、固定データ・固定設定・固定 seed で意味的に同一の数値・説明成果物を生成します（CI smoke test [test/test_keen_empirical_ai_economist_demo.jl](../../test/test_keen_empirical_ai_economist_demo.jl) が検証）。
- **provenance**: `run_manifest.json` に code revision（git HEAD）・prompt version・LLM provider/model・実行日時・警告一覧を記録します。**API キー等の秘密情報は成果物に一切含めません**（smoke test が検証）。
- **失敗の非隠蔽**: 推定未収束・データ不足・発散でも、途中成果物と診断・警告を保存し、誤って成功扱いしません（NaN は 0 化せず JSON では `null`）。

## 結果の限界・禁止される解釈

- 観測系列は理論変数（ω・λ・d）の近似 proxy であり厳密に同一ではない。
- calibrated parameter は採用期間・proxy・weight・bounds に依存する。
- observed regime も集計 proxy 診断であり企業別実測分類ではない。
- out-of-sample fit は危機予測能力を意味しない。
- クロスモデル比較の同名変数は定義が一致するとは限らず、比較不能な概念は統合しない。
- 本デモは投資助言・政策判断の自動化を目的としない。

## 関連ドキュメント

- [Keen モデル 実証化戦略](../models/keen_empirical_strategy.md)
- [AnalysisContext 設計](../architecture/analysis_context.md) / [クロスモデル推論層の設計](../architecture/cross_model_reasoning.md)
- [ADR 0005: Keen 実証結果の AI 説明契約](../adr/0005-keen-ai-explanation-contract.md) / [ADR 0006: クロスモデル推論契約](../adr/0006-cross-model-reasoning-contract.md)
- [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)
- [Keen 実証統合デモ](../../examples/keen_empirical_demo.jl)（実証分析のみ・LLM 層なしの版）
