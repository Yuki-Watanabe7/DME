# 2026-09 Financial-Instability Live Holdout デモ

[examples/financial_instability_holdout_demo.jl](../../examples/financial_instability_holdout_demo.jl) は、Issue #260 の Part A（shock semantics）・Part B（EDP financial-stress観測のconsumer化）・Part D（構造化診断）を接続し、`FinancialStressRawDataset` から `FinancialInstabilityAssessment`（`trigger_state`/`weak_credit_state`/`funding_state`/`broad_conditions_state`/`model_amplification_state`/`minsky_diagnostic_state`の6次元 + rule-based `overall_status`）を構築し、JSON artifact + 人が読むreportを保存するまでの経路を実演します。fixtureモードでは外部API・ネットワークアクセスなし・完全に決定的です。

> 関連 Issue: #260（Part D）
> 決定記録: [ADR 0019](../adr/0019-long-rate-funding-shock-contract.md)（Part A）
> 前提: [金融ストレス観測 利用ガイド](../data/financial_stress.md)（Part B）

## 対象外であることの明記

**本デモの出力（`overall_status` を含む）は観測事実に対する versioned rule-based な構造化診断であり、以下のいずれでもありません。**

- 「Minsky moment / financial instabilityが進行している」という判定
- 危機確率・景気後退確率の推定
- 投資判断・売買シグナル

さらに、本デモの入力データは**全て fictional（架空）**です（`test/fixtures/data/financial_stress/`・`test/fixtures/fred/NFCI.json`・`DRTSCILM.json`）。実在の2026-09の金利水準・信用スプレッド・funding conditionを表すものではありません。

## 全体フロー

| Step | 内容 | 主な API |
|---|---|---|
| 1 | Part Bの8系列を `DataProviderClient`（fixtureモード既定）経由で取得する | `build_financial_stress_raw_dataset` |
| 2 | NFCI・SLOOSを `FredClient`（fixtureモード既定）経由で取得する | `fetch_fred_series` |
| 3 | 6 dimensionと `overall_status` を構築する | `assess_financial_instability` |
| 4 | JSON artifact（`identity_hash` 付き）とMarkdown reportを保存する | `save_financial_instability_assessment` |

## overall_status のルール

`overall_status` は `trigger_state`（長期金利repricing）単独では `:watch`/`:confirmed` になりません。

1. `trigger_state.label` が `:not_supported`/`:insufficient_data` → `overall_status = :not_supported`（全dimensionが`:insufficient_data`のときのみ`overall_status = :insufficient_data`）。
2. `trigger_state.label` が `:watch`/`:confirmed` のとき、`weak_credit_state`・`funding_state`・`broad_conditions_state` のうち `:watch` 以上の件数を数える。
   - 2件以上 → `:confirmed`
   - 1件 → `:watch`
   - 0件 → `:not_supported`（長期金利は動いたが他に証拠が無い）

`model_amplification_state`・`minsky_diagnostic_state` は overall_status の算出に使いません（既存capabilityへの静的citationであり、本デモの入力データに対する新規のモデル実行・較正ではないため）。

## 6 dimension

| dimension | 内容 | データ源 |
|---|---|---|
| `trigger_state` | 長期名目/実質金利・inflation compensationの `from_date→to_date` 変化（bp） | Part B（`long_rate_shift_components`） |
| `weak_credit_state` | CCC以下OASの水準・広範HYとの乖離拡大 | Part B（`ccc_minus_broad_hy_oas_bp`） |
| `funding_state` | SOFR/TGCRの政策アンカー（IORB）対比乖離（最新水準） | Part B（`sofr_minus_iorb_bp`・`tgcr_minus_iorb_bp`） |
| `broad_conditions_state` | NFCI・SLOOSの最新値 | 既存のDME FRED接続 |
| `model_amplification_state` | CCC historical validation（Issue #247–#251）が確認した credit amplification能力への静的citation | ドキュメント参照のみ |
| `minsky_diagnostic_state` | Keen/Minsky系Hedge/Speculative/Ponzi診断機構への静的citation | ドキュメント参照のみ |

## 実行方法

```bash
julia --project=. examples/financial_instability_holdout_demo.jl
```

出力先は既定で `artifacts/financial_instability_holdout_demo/`（`FIH_DEMO_OUTDIR` で上書き可）。

```julia
using DME
out = run_financial_instability_holdout_demo(; outdir = "/path/to/dir")
out.assessment.overall_status
```

対象期間（`from_date`/`to_date`）を指定できます。

```julia
out = run_financial_instability_holdout_demo(;
    outdir = "/path/to/dir", from_date = "2026-08-25", to_date = "2026-09-04",
)
```

## 実際の2026-09 live holdoutを実行する場合

`DME_DATA_MODE=live` に加え、`DATA_PROVIDER_BASE_URL`（EDP）・`FRED_API_KEY`（NFCI/SLOOS）を設定し、`from_date`/`to_date` を実際の対象期間に置き換えます。

```bash
export DME_DATA_MODE=live
export DATA_PROVIDER_BASE_URL=https://your-edp-host
export FRED_API_KEY=your_api_key_here
```

**この場合も、2026-09の観測をパラメータ較正・閾値較正に使用しないこと**（Issue #260 対象外事項）。`FinancialInstabilityThresholds` の既定値は暫定既定値であり、較正は別issueで行います。

## 成果物

- `assessment.json`（`financial_instability_assessment_to_dict`。`identity_hash` は `as_of_generated`（実行時刻）を除いた内容のsha256で、同じ入力から常に同じ値になります）
- `report.md`（人が読むサマリー）

## 関連

- [金融ストレス観測 利用ガイド](../data/financial_stress.md) — Part Bの8系列・派生指標
- [ADR 0019](../adr/0019-long-rate-funding-shock-contract.md) — Part Aの shock semantics 分離契約
