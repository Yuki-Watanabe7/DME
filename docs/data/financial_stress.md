# 金融ストレス観測（credit-tier / secured-funding / long-rate）利用ガイド

> 関連 Issue: #260（Part B）
> 前提: [ADR 0019](../adr/0019-long-rate-funding-shock-contract.md)（Part A、長期金利・funding-cost shockの分離契約）
> 上流: economic-data-provider（EDP）#189・[EDP ADR 028](https://github.com/Yuki-Watanabe7/economic-data-provider/blob/main/docs/adr/028-us-financial-stress-series-catalog.md)（vendor: 系列選定の一次情報。DMEはvendorコピーを持たない）

---

## 1. 対象外であることの明記

**本ガイドが扱う8系列とその差分・変化は観測事実（raw series とその単純な算術）である。**
以下のいずれでもない。

- 「Minsky moment / financial instabilityが進行している」等の判定
- 危機確率・景気後退確率の推定
- 投資判断・売買シグナル
- DME側モデル方程式の代替・変更

判定・解釈は本ガイドの対象外（Issue #260 Part D の対象）であり、EDPガイドの同じ規律
（`economic-data-provider` の [financial-stress 利用ガイド](https://github.com/Yuki-Watanabe7/economic-data-provider/blob/main/docs/guides/financial-stress.md) §1）を踏襲する。

---

## 2. 概要

`DME.build_financial_stress_raw_dataset` で、米国の credit-tier stress・secured funding
stress・長期金利を表す8系列を EDP（economic-data-provider）経由で取得できます。API キー
なしでも `:fixture` モード（既定）で完走します。

| # | key | series_id | role |
|---|---|---|---|
| 1 | `:ccc_oas` | `BAMLH0A3HYC` | `credit_stress_ccc_oas`（最弱信用層のOAS） |
| 2 | `:broad_hy_oas` | `BAMLH0A0HYM2` | `credit_stress_broad_hy_oas`（広範HY、比較baseline） |
| 3 | `:sofr` | `SOFR` | `secured_funding_rate` |
| 4 | `:tgcr` | `TGCRRATE` | `repo_general_collateral_rate` |
| 5 | `:iorb` | `IORB` | `policy_anchor_rate`（SOFR/TGCRの日次政策アンカー） |
| 6 | `:long_nominal_yield` | `DGS10` | `long_nominal_yield`（10年国債利回り） |
| 7 | `:long_real_yield` | `DFII10` | `long_real_yield`（10年TIPS利回り） |
| 8 | `:inflation_compensation` | `T10YIE` | `inflation_compensation`（10年breakeven inflation） |

系列1–5はEDPが `financial_stress` role付きで登録済み（EDP #189）。系列6–8はEDPの汎用
FRED passthrough（`GET /v1/series/{series_id}`）でそのまま取得する（DME側で role を
独自命名する。[catalog](../../src/data/financial_stress_catalog.jl) 参照）。

いずれも日次系列であり、DME の `DataFrequency`（`Annual`/`Quarterly`/`Monthly` のみ）には
対応する値が無いため、`DataSeries` を使わず独立した `FinancialStressSeries` 型で保持する
（日次を月次・四半期へ暗黙に丸めないという契約を守るため）。CCCモデルの既存の較正入力
（`spread_hy` 等、`capex_credit_cycle_catalog.jl`）とは独立した診断層であり、CCCの
較正・逆較正には影響しない。

---

## 3. クイックスタート

### fixture モード（既定・API キー不要）

```julia
using DME

raw = build_financial_stress_raw_dataset()
raw.observations[:ccc_oas].status              # => :ok
ccc_oas = raw.observations[:ccc_oas].series
value_on_date(ccc_oas, "2026-08-28")            # => 9.7 (fixtureの例示値)
value_on_date(ccc_oas, "2026-08-27")            # => missing（fixtureのnull。0や補完値にしない）
value_on_date(ccc_oas, "2020-01-01")            # => missing（不在日）
```

### live モード（実 EDP API）

```bash
export DATA_PROVIDER_BASE_URL=https://your-edp-host
export DME_DATA_MODE=live
```

```julia
using DME
raw = build_financial_stress_raw_dataset()   # 環境変数から自動的に live モード
```

### 部分集合のみ取得する

```julia
raw = build_financial_stress_raw_dataset(; keys = [:sofr, :tgcr, :iorb])
```

---

## 4. 派生指標（同日差分・変化）

EDPは系列間の差分を計算しない（[EDP financial-stress ガイド](https://github.com/Yuki-Watanabe7/economic-data-provider/blob/main/docs/guides/financial-stress.md) §4）。DME側の
`src/analysis/financial_stress_diagnostics.jl` が「同日の値を使う」原則の下で計算する。
片方が欠測の日は結果から除外し、0や前後の値へ補完しない。

```julia
raw = build_financial_stress_raw_dataset()

# 最弱信用層 - 広範HY（bp、同日整列）
spread = ccc_minus_broad_hy_oas_bp(raw)
spread.n_common          # 整列できた日数
spread.n_a_only_missing  # ccc_oas側だけ欠測だった日数
latest_aligned(spread)   # => (date, value_bp) または nothing（0件なら）

# secured funding の政策アンカーからの乖離
sofr_minus_iorb_bp(raw)
tgcr_minus_iorb_bp(raw)
sofr_minus_tgcr_bp(raw)

# 任意の2日付間の変化（bp）
nominal = raw.observations[:long_nominal_yield].series
yield_shift_bps(nominal, "2026-08-25", "2026-09-04")

# 長期金利・funding-cost shockの4構成要素をまとめて計算する
# （Issue #260 Part A の FundingShockComponents のキーワード引数と1:1対応する設計）
c = long_rate_shift_components(raw, "2026-08-25", "2026-09-04")
c.long_nominal_yield_shift_bps
c.long_real_yield_shift_bps
c.inflation_compensation_shift_bps
c.secured_funding_spread_shift_bps
```

`long_rate_shift_components` は基準日（`from_date`/`to_date`）を選ばない。基準日の選定
（2026-09の live holdoutでどの日付を使うか）は Issue #260 Part D の責務である。

---

## 5. 欠測・失敗の扱い

`build_financial_stress_raw_dataset` は失敗を `status` で区別し、0や空データへ暗黙変換
しない。

| `status` | 意味 |
|---|---|
| `:ok` | 取得成功。`series` が非 `nothing`。 |
| `:missing_series` | provider が当該IDを返さない（fixture不在・HTTP 404・空系列）。 |
| `:provider_error` | provider がエラーを返した（HTTP 404以外）。 |
| `:invalid_response` | レスポンスが契約と不整合（不正JSON・id不一致・frequency不一致等）。 |

`status != :ok` のとき `series === nothing`。欠測日は `value_on_date` が `missing` を返す
（forward-fill・補間をしない）。

---

## 6. 関連

- [ADR 0019](../adr/0019-long-rate-funding-shock-contract.md) — Part A（shock semanticsの分離）
- [マクロイベント変換契約 §14](../architecture/macro_event_contract.md) — `:LongRateFundingShock` の契約
- [経済データ接続（EDP）汎用クライアント](../../src/data/data_provider.jl) — 本ガイドが再利用する `DataProviderClient`
- economic-data-provider [ADR 028](https://github.com/Yuki-Watanabe7/economic-data-provider/blob/main/docs/adr/028-us-financial-stress-series-catalog.md)・[financial-stress 利用ガイド](https://github.com/Yuki-Watanabe7/economic-data-provider/blob/main/docs/guides/financial-stress.md)（vendor: 系列選定の一次情報）
