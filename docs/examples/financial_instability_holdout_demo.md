# 2026-09 Financial-Instability Live Holdout デモ

[examples/financial_instability_holdout_demo.jl](../../examples/financial_instability_holdout_demo.jl) は、Issue #260 の Part A（shock semantics）・Part B（EDP financial-stress観測のconsumer化）・Part D（構造化診断）を接続し、`FinancialStressRawDataset` から `FinancialInstabilityAssessment`（`trigger_state`/`weak_credit_state`/`funding_state`/`broad_conditions_state`/`model_amplification_state`/`minsky_diagnostic_state`の6次元 + rule-based `overall_status`）を構築し、JSON artifact + 人が読むreport + run manifest（freeze対象の記録、Issue #271 Part A）を保存するまでの経路を実演します。fixtureモード（既定）では外部API・ネットワークアクセスなし・完全に決定的です。

同じファイルは、Issue #271 Part A（2026-09 pre-FOMC canonical live snapshot）が求める実データでの1回限りの実行（`run_financial_instability_holdout_live_snapshot`）と、Part B・C・D（post-FOMC再実行・pre/post比較・finance-checker handoff artifact、`run_financial_instability_post_fomc_comparison`）も提供します。詳細は§「実際の2026-09 live holdoutを実行する場合」・§「pre/post-FOMC比較とfinance-checker handoff」を参照してください。

> 関連 Issue: #260（Part D）・#271（Part A: pre-FOMC live snapshot・Part B: post-FOMC再実行・Part C: pre/post比較・Part D: finance-checker handoff）
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

出力先は既定で `artifacts/financial_instability_holdout_demo/`（`FIH_DEMO_OUTDIR` で上書き可）。`DME_DATA_MODE=live` を設定して直接実行すると、下記の `run_financial_instability_holdout_live_snapshot` へ自動的に切り替わります。

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

## 観測ウィンドウ選定ルール（Issue #271 Part A）

`trigger_state`/`weak_credit_state` の変化幅は `from_date→to_date` の2時点比較です。Issue #271 は「現在の市場水準を見てから選ばない」ことを求めるため、`select_observation_window` が機械的に選定します。

- `to_date` = `window_key`系列（既定 `:long_nominal_yield`、DGS10）で `to_date_cutoff`（既定 `nothing` = 上限なし）以前の非欠測の最新観測日。
- `from_date` = 同系列で `to_date - lookback_days` 暦日以前の非欠測の最新観測日。
- `lookback_days` の既定は `FIH_DEFAULT_LOOKBACK_DAYS = 28`（直近4週間）。事前に固定した値であり、いずれかの日付が見つからない場合は `ArgumentError`（forward-fillしない）。

`from_date`/`to_date` を両方省略（`nothing`）すると自動選定されます。片方だけの省略はエラーです。

## 実際の2026-09 live holdoutを実行する場合（Issue #271 Part A: pre-FOMC canonical snapshot）

`DME_DATA_MODE=live` に加え、`DATA_PROVIDER_BASE_URL`（EDP）・`FRED_API_KEY`（NFCI/SLOOS・EDP側FREDパススルー）を設定します。

```bash
export DME_DATA_MODE=live
export DATA_PROVIDER_BASE_URL=http://localhost:8000
export FRED_API_KEY=your_api_key_here
```

```julia
using DME
include("examples/financial_instability_holdout_demo.jl")
out = run_financial_instability_holdout_live_snapshot(; outdir = "/path/to/dir")
```

`run_financial_instability_holdout_live_snapshot` は `DME_DATA_MODE=live` でなければ `ArgumentError` を投げます（fixtureベースのartifactが誤って canonical として扱われることを防ぐため）。`from_date`/`to_date` は上記の選定ルールで自動決定されます。

**この場合も、2026-09の観測をパラメータ較正・閾値較正に使用しないこと**（Issue #260/#271 対象外事項）。`FinancialInstabilityThresholds` の既定値は暫定既定値であり、較正は別issueで行います。

## 成果物（Part A・B: snapshot）

- `assessment.json`（`financial_instability_assessment_to_dict`。`identity_hash` は `as_of_generated`（実行時刻）を除いた内容のsha256で、同じ入力から常に同じ値になります）
- `report.md`（人が読むサマリー。liveモードでは観測系列provenanceの要約表を含む）
- `run_manifest.json`（Issue #271 Part A の freeze 対象: `dme_code_revision`・`rule_version`・`financial_stress_catalog_version`・`edp_identity`（liveモードで `/health` からベストエフォート取得）・`observation_window`（選定ルール・実際の from_date/to_date）・`series_provenance`（EDP8系列 + NFCI + SLOOSそれぞれの `status`/`mode`/`retrieved_at`/最新observation日）・`assessment_identity_hash`）

`artifacts/` は `.gitignore` 対象のためコミットされません。pre-FOMC（Part A）と post-FOMC（Part B）の比較を行う際は `assessment.json`/`run_manifest.json` を保存しておいてください（版情報が全て記録されているため、ファイル自体がfreezeの記録になります）。

## pre/post-FOMC比較とfinance-checker handoff（Issue #271 Part B・Part C・Part D）

`run_financial_instability_post_fomc_comparison(; pre_dir, outdir, lookback_days = FIH_DEFAULT_LOOKBACK_DAYS)` が Part B（post-FOMC再実行）・Part C（pre/post比較）・Part D（finance-checker handoff artifact）をまとめて実行します。`pre_dir` には Part A（または前回の Part B）が保存したディレクトリ（`assessment.json`/`run_manifest.json` を含む）を渡します。新規のEDP/FRED fetchは post 側のみで行い、pre 側は保存済みファイルを読むだけです（`DME_DATA_MODE=live`・`DATA_PROVIDER_BASE_URL`・`FRED_API_KEY` の設定は §「実際の2026-09 live holdoutを実行する場合」と同じ）。

```julia
using DME
include("examples/financial_instability_holdout_demo.jl")
out = run_financial_instability_post_fomc_comparison(;
    pre_dir = "/path/to/pre_fomc_dir", outdir = "/path/to/post_fomc_dir",
)
out.comparison.conclusion   # :hypothesis_strengthened / :hypothesis_weakened /
                             # :no_material_change / :insufficient_comparable_data
```

pre-FOMCと同じ `lookback_days`（既定値のまま）を使うため、observation window の選定ルール自体は変更しません（Post-FOMC受け入れ条件「pre-FOMCからparameter/threshold/episode/proxy ruleを変更していない」）。`run_financial_instability_holdout_live_snapshot` と同様、`DME_DATA_MODE=live` でなければ `ArgumentError` になります。

### `conclusion` のルール（Issue #271 Part C）

単一の危機確率・景気後退確率スコアではなく、`overall_status` の遷移から導く4値のいずれかです。

1. `rule_version`・`assessment_version`・`financial_stress_catalog_version`・`thresholds` のいずれかが pre/post で一致しない → `:insufficient_comparable_data`（同じruleで比較するという前提が崩れているため。`dme_code_revision` の不一致はこの判定に含めません — バグフィックスなど計算結果に影響しない差もあるため、`version_consistency` に別掲するのみです）。
2. pre または post の `overall_status` が `:insufficient_data` → `:insufficient_comparable_data`。
3. それ以外は `overall_status` の rank（`FINANCIAL_INSTABILITY_STATUSES` の順）を比較し、上がれば `:hypothesis_strengthened`、下がれば `:hypothesis_weakened`、同じなら `:no_material_change`。

dimension別のlabel遷移（例: `overall_status` は変わらないが `weak_credit_state` だけ悪化した、等）は `conclusion` に反映されない場合でも `comparison.dimensions`（各dimensionの `pre_label`/`post_label`/`label_changed`/`values`）に必ず残ります。

### 成果物（Part C・D）

- `comparison.json`（`financial_instability_comparison_to_dict`。dimension別の数値差分・label遷移・`version_consistency`・`conclusion`/`conclusion_reason`）
- `handoff.json`（`financial_instability_handoff_to_dict`。pre/postのassessmentを埋め込み、`classification`（`observed_facts`/`dme_rule_based_interpretation`/`unverified_economic_interpretation` の3区分）・`unavailable_evidence`（status≠okの系列）・historical-validation citationを含む。belief・Evidence・Hypothesisの登録・更新は行いません）
- `comparison_report.md`（人が読むpre/post比較サマリー）

## 関連

- [金融ストレス観測 利用ガイド](../data/financial_stress.md) — Part Bの8系列・派生指標
- [ADR 0019](../adr/0019-long-rate-funding-shock-contract.md) — Part Aの shock semantics 分離契約
