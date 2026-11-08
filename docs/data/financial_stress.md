# 金融ストレス観測（credit-tier / secured-funding / long-rate）利用ガイド

> 関連 Issue: #260（Part B）・#312（credit-tier 系列の置き換え）
> 前提: [ADR 0019](../adr/0019-long-rate-funding-shock-contract.md)（Part A、長期金利・funding-cost shockの分離契約）・[ADR 0029](../adr/0029-ice-bofa-distribution-stop-and-replacement-indicators.md)（ICE BofA 2系列の提供停止への追従と代替指標）
> 上流: economic-data-provider（EDP）#189・[EDP ADR 028](https://github.com/Yuki-Watanabe7/economic-data-provider/blob/main/docs/adr/028-us-financial-stress-series-catalog.md)・EDP ADR 072（契約6.0.0、ICE BofA 2系列の提供停止）（vendor: 系列選定・提供停止の一次情報。DMEはvendorコピーを持たない）

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
| 1 | `:cp_a2p2_nonfinancial_30d` | `RIFSPPNA2P2D30NB` | `credit_tier_lower_cp_rate`（30日物 A2/P2 非金融CP金利。下位格付け階層） |
| 2 | `:cp_aa_nonfinancial_30d` | `RIFSPPNAAD30NB` | `credit_tier_upper_cp_rate`（30日物 AA 非金融CP金利。比較baseline） |
| 3 | `:sofr` | `SOFR` | `secured_funding_rate` |
| 4 | `:tgcr` | `TGCRRATE` | `repo_general_collateral_rate` |
| 5 | `:iorb` | `IORB` | `policy_anchor_rate`（SOFR/TGCRの日次政策アンカー） |
| 6 | `:long_nominal_yield` | `DGS10` | `long_nominal_yield`（10年国債利回り） |
| 7 | `:long_real_yield` | `DFII10` | `long_real_yield`（10年TIPS利回り） |
| 8 | `:inflation_compensation` | `T10YIE` | `inflation_compensation`（10年breakeven inflation） |

系列3–5はEDPが `financial_stress` role付きで登録済み（EDP #189）。系列1–2・6–8はEDPの汎用
FRED 中継（`GET /v1/series/{series_id}`。EDP ADR 072 決定5でカタログ外の FRED 系列の中継を
続けると確定）でそのまま取得する（DME側で role を独自命名する。
[catalog](../../src/data/financial_stress_catalog.jl) 参照）。系列1–2は FRB Commercial Paper
release の系列で、FRED の権利区分は "Public Domain: Citation Requested" である（2026-11-08 に
FRED の系列ページで確認）。系列5–7（IORB・DGS10・DFII10）も同じ区分であることを EDP の権利
調査（EDP #266）が確認している。

### credit-tier 系列の置き換え（Issue #312）

catalog 1.0.0 は credit-tier stress を ICE BofA の CCC & Lower OAS（`BAMLH0A3HYC`）と
US High Yield OAS（`BAMLH0A0HYM2`）の差で観測していた。EDP は契約6.0.0（ADR 072、
2026-11-07）で両系列の提供を停止した。FRED の権利区分が "Copyrighted: Pre-Approval
Required" で、ICE Data の注記が第三者への提供を禁じているためである。停止後の
`GET /v1/series/{id}` は HTTP 410 と `{"detail": {"code": "distribution_stopped", ...}}` を返す。

catalog 2.0.0 は、30日物 A2/P2 非金融CP金利と AA 非金融CP金利の同日差分で credit-tier
stress を観測する（[ADR 0029](../adr/0029-ice-bofa-distribution-stop-and-replacement-indicators.md)）。
「下位階層 − 上位階層」の構造は同じだが、観測対象が違う。

| | catalog 1.0.0（停止） | catalog 2.0.0 |
|---|---|---|
| 指標 | CCC & Lower OAS − US High Yield OAS | A2/P2 − AA 非金融CP金利（30日物） |
| 市場・満期 | 社債（HY）、数年 | CP、30日 |
| 発行体の信用層 | 投資適格未満（HY と、その中の CCC 以下） | 投資適格（短期格付け A2/P2 と AA） |
| 権利区分（FRED） | Copyrighted: Pre-Approval Required | Public Domain: Citation Requested |

新しい指標は HY・CCC 社債の信用リスクを観測しない。CP を発行できない、または発行を
止めた企業の状態も反映しない。2つの指標の水準・変化幅は比べられない。
停止した2系列の ID は `_REDISTRIBUTION_EXCLUDED_SERIES`（`src/data/data_provider.jl`）に
記録し、catalog への再登録を拒否する。

いずれも日次系列であり、DME の `DataFrequency`（`Annual`/`Quarterly`/`Monthly` のみ）には
対応する値が無いため、`DataSeries` を使わず独立した `FinancialStressSeries` 型で保持する
（日次を月次・四半期へ暗黙に丸めないという契約を守るため）。CCCモデルの既存の較正入力
（`spread_hqm_corporate` 等、`capex_credit_cycle_catalog.jl`）とは独立した診断層であり、CCCの
較正・逆較正には影響しない。

---

## 3. クイックスタート

### fixture モード（既定・API キー不要）

```julia
using DME

raw = build_financial_stress_raw_dataset()
raw.observations[:cp_a2p2_nonfinancial_30d].status   # => :ok
lower = raw.observations[:cp_a2p2_nonfinancial_30d].series
value_on_date(lower, "2026-08-28")    # => 4.5 (fixtureの例示値)
value_on_date(lower, "2026-08-27")    # => missing（fixtureのnull。0や補完値にしない）
value_on_date(lower, "2020-01-01")    # => missing（不在日）
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

# 下位格付け階層 - 上位格付け階層（A2/P2 − AA 非金融CP、30日物。bp、同日整列）
spread = cp_a2p2_minus_aa_bp(raw)
spread.n_common          # 整列できた日数
spread.n_a_only_missing  # A2/P2側だけ欠測だった日数
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
| `:distribution_stopped` | EDP が提供を停止した（HTTP 410 かつ `detail.code == "distribution_stopped"`、EDP ADR 060・ADR 072）。一時的なデータ不足や障害ではなく、恒久的に取得できない。`detail` に `reason_code`（例: `redistribution_rights`）を残す。 |
| `:provider_error` | provider がエラーを返した（上記以外の HTTP エラー・通信失敗。`detail.code` が `distribution_stopped` でない 410 を含む）。 |
| `:invalid_response` | レスポンスが契約と不整合（不正JSON・id不一致・frequency不一致等）。 |

`status != :ok` のとき `series === nothing`。欠測日は `value_on_date` が `missing` を返す
（forward-fill・補間をしない）。

EDP クライアント（`src/data/data_provider.jl`）は、200 以外の応答本文から `detail.code` と
`detail.reason_code` だけを取り出して保持する。どちらも短い小文字のトークンに限り、
`detail.message` などの自由記述は保持しない。

holdout assessment（[デモ](../examples/financial_instability_holdout_demo.md)）は、
`trigger_state`・`weak_credit_state`・`funding_state` の `input_statuses` に入力系列ごとの
status を残す。`label = :insufficient_data` の原因が一時的な欠測か提供停止かを、artifact
だけで判別できる。

---

## 6. 関連

- [ADR 0019](../adr/0019-long-rate-funding-shock-contract.md) — Part A（shock semanticsの分離）
- [マクロイベント変換契約 §14](../architecture/macro_event_contract.md) — `:LongRateFundingShock` の契約
- [経済データ接続（EDP）汎用クライアント](../../src/data/data_provider.jl) — 本ガイドが再利用する `DataProviderClient`
- economic-data-provider [ADR 028](https://github.com/Yuki-Watanabe7/economic-data-provider/blob/main/docs/adr/028-us-financial-stress-series-catalog.md)・[financial-stress 利用ガイド](https://github.com/Yuki-Watanabe7/economic-data-provider/blob/main/docs/guides/financial-stress.md)（vendor: 系列選定の一次情報）
