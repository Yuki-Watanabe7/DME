# financial_stress_catalog.jl: 米国 credit-tier / secured-funding / long-rate 観測系列の
# catalog（Issue #260 Part B。credit-tier の2系列は Issue #312・ADR 0029 で置き換え）。
#
# economic-data-provider（EDP）の financial-stress catalog に残る3系列（SOFR・TGCR・IORB、
# EDP ADR 028）と、EDP の汎用 FRED 中継（`GET /v1/series/{series_id}`、EDP ADR 072 決定5で
# 「カタログ外の任意の FRED 系列を中継する挙動は変えない」と確定）でそのまま取得する5系列
# （credit-tier の CP 金利2種・10年名目金利・10年TIPS実質金利・inflation compensation）を
# 対象とする。
#
# credit-tier stress は当初 ICE BofA の CCC & Lower OAS（BAMLH0A3HYC）と US High Yield OAS
# （BAMLH0A0HYM2）で観測していたが、EDP は契約6.0.0（ADR 072）で両系列の提供を停止した
# （FRED 区分 "Copyrighted: Pre-Approval Required"、ICE Data の "internal use only" 注記）。
# DME は FRB Commercial Paper release の非金融 CP 金利（A2/P2 と AA、30日物、FRED 区分
# "Public Domain: Citation Requested"）の同日差分へ置き換えた（ADR 0029）。停止系列の ID は
# `_REDISTRIBUTION_EXCLUDED_SERIES`（data_provider.jl）が catalog への再登録を拒否する。
#
# 本ファイルは `CapexSeriesSpec`（src/data/capex_credit_cycle_catalog.jl）を再利用しない。
# CCCモデルの較正入力ではなく、政策金利変更から分離した長期金利・funding-cost shockの
# 診断（Issue #260 Part A・D）向けの独立した観測 catalog であるため、CCC固有の役割区分
# （:calibration_required 等）・部門scope・逆較正との結びつきを持たせない。
#
# いずれも日次系列であり、DME の `DataFrequency`（`Annual`/`Quarterly`/`Monthly` のみ）には
# 対応する値が無い。日次を月次・四半期へ暗黙に丸めないという契約（EDPガイド・Issue #260
# 対象外事項）を守るため、`DataSeries` を流用せず `FinancialStressSeries`
# （src/data/financial_stress_provider.jl）という独立した最小の型で保持する。
#
# 設計契約:
#   docs/data/financial_stress.md
#   docs/adr/0029-ice-bofa-distribution-stop-and-replacement-indicators.md（credit-tier 系列の
#     置き換え・410 distribution_stopped の扱い）
#   docs/adr/0019-long-rate-funding-shock-contract.md（Part A、本カタログが供給する
#     生データの用途）
#   economic-data-provider ADR 028・ADR 072・docs/guides/financial-stress.md（vendor: 系列選定・
#     提供停止の一次情報。DME側ではvendorコピーを持たず本ファイルが参照するのみ）

"金融ストレス観測 catalog の version。"
const FINANCIAL_STRESS_CATALOG_VERSION = "financial-stress-catalog/2.0.0"

"""
    FINANCIAL_STRESS_ROLES

`FinancialStressSeriesSpec.role` の確定集合。EDP ADR 028 の `role` のうち EDP に残る3種
（`secured_funding_rate`・`repo_general_collateral_rate`・`policy_anchor_rate`）に加え、
EDP の汎用 FRED 中継で取得する5系列の役割を DME 側で命名する（EDPはこれらに
`financial_stress` roleを付与していない）。

`credit_tier_lower_cp_rate`・`credit_tier_upper_cp_rate` は ADR 0029 で、EDP が削除した
`credit_stress_ccc_oas`・`credit_stress_broad_hy_oas` の代わりに置いた。名前を引き継がない
のは、観測対象（短期 CP 市場の格付け階層）が HY 社債の OAS と異なるためである。
"""
const FINANCIAL_STRESS_ROLES = (
    :credit_tier_lower_cp_rate,
    :credit_tier_upper_cp_rate,
    :secured_funding_rate,
    :repo_general_collateral_rate,
    :policy_anchor_rate,
    :long_nominal_yield,
    :long_real_yield,
    :inflation_compensation,
)

"""
    FinancialStressSeriesSpec

金融ストレス観測 catalog の1行（Issue #260 Part B）。

## フィールド
- `key::Symbol`: DME内部の参照キー。
- `provider_series_id::String`: EDP `/v1/series/{series_id}` へ渡す FRED series ID
  （そのまま渡す。EDP側でのprefix付与・変換は行われない）。
- `role::Symbol`: `FINANCIAL_STRESS_ROLES` のいずれか。
- `comparison_key::Union{Symbol,Nothing}`: 比較対象となる catalog 内の `key`
  （EDP ADR 028 の `comparison_series_id` に対応。無い場合（自身がbaseline/anchor）は
  `nothing`）。
- `unit::String`: 宣言単位（EDPは全系列 `"Percent"` を返す）。
- `description::String`: 日本語の説明。
"""
struct FinancialStressSeriesSpec
    key::Symbol
    provider_series_id::String
    role::Symbol
    comparison_key::Union{Symbol, Nothing}
    unit::String
    description::String

    function FinancialStressSeriesSpec(;
        key::Symbol,
        provider_series_id::AbstractString,
        role::Symbol,
        unit::AbstractString,
        description::AbstractString,
        comparison_key::Union{Symbol, Nothing} = nothing,
    )
        isempty(provider_series_id) &&
            throw(ArgumentError("provider_series_id は空にできません: $key"))
        excluded = _redistribution_excluded_series_id(provider_series_id)
        excluded === nothing || throw(
            ArgumentError(
                "provider_series_id=$provider_series_id は再配布できない系列として catalog " *
                "から除外されています（$(_REDISTRIBUTION_EXCLUDED_SERIES[excluded].reference)）: " *
                "$key",
            ),
        )
        role in FINANCIAL_STRESS_ROLES || throw(
            ArgumentError(
                "role=$role は FINANCIAL_STRESS_ROLES のいずれかでなければなりません: $key",
            ),
        )
        return new(
            key,
            String(provider_series_id),
            role,
            comparison_key,
            String(unit),
            String(description),
        )
    end
end

"""
    FINANCIAL_STRESS_SERIES_CATALOG

金融ストレス観測 catalog 本体（8系列、Issue #260 Part B・Issue #312）。`comparison_key` は
「同日で比較して初めて意味を持つ」関係を明示するのみであり、差分計算そのものは
`src/analysis/financial_stress_diagnostics.jl` が行う（EDPは差分を計算しない、
EDPガイド §4 と同じ責務境界）。
"""
const FINANCIAL_STRESS_SERIES_CATALOG = FinancialStressSeriesSpec[
    FinancialStressSeriesSpec(;
        key = :cp_a2p2_nonfinancial_30d,
        provider_series_id = "RIFSPPNA2P2D30NB",
        role = :credit_tier_lower_cp_rate,
        comparison_key = :cp_aa_nonfinancial_30d,
        unit = "Percent",
        description = "30-Day A2/P2 Nonfinancial Commercial Paper Interest Rate（FRB Commercial " *
                      "Paper release、日次）。短期 CP 市場の下位格付け階層（A2/P2）の発行金利。" *
                      "AA 非金融 CP との同日差分で credit-tier stress を観測する（ADR 0029）。" *
                      "HY・CCC 社債の信用リスクは観測しない。",
    ),
    FinancialStressSeriesSpec(;
        key = :cp_aa_nonfinancial_30d,
        provider_series_id = "RIFSPPNAAD30NB",
        role = :credit_tier_upper_cp_rate,
        comparison_key = nothing,
        unit = "Percent",
        description = "30-Day AA Nonfinancial Commercial Paper Interest Rate（FRB Commercial " *
                      "Paper release、日次）。A2/P2 との比較baseline（上位格付け階層）。" *
                      "同じ release・同じ満期の系列を対にし、満期・発行体区分の差を差分に" *
                      "持ち込まない。",
    ),
    FinancialStressSeriesSpec(;
        key = :sofr,
        provider_series_id = "SOFR",
        role = :secured_funding_rate,
        comparison_key = :iorb,
        unit = "Percent",
        description = "Secured Overnight Financing Rate。Treasury担保のtri-party・GCF・" *
                      "二者間repoを含む広範な指標。",
    ),
    FinancialStressSeriesSpec(;
        key = :tgcr,
        provider_series_id = "TGCRRATE",
        role = :repo_general_collateral_rate,
        comparison_key = :iorb,
        unit = "Percent",
        description = "Tri-Party General Collateral Rate。tri-party GC repoのみの狭い指標。",
    ),
    FinancialStressSeriesSpec(;
        key = :iorb,
        provider_series_id = "IORB",
        role = :policy_anchor_rate,
        comparison_key = nothing,
        unit = "Percent",
        description = "Interest Rate on Reserve Balances。SOFR/TGCRの日次政策アンカー。",
    ),
    FinancialStressSeriesSpec(;
        key = :long_nominal_yield,
        provider_series_id = "DGS10",
        role = :long_nominal_yield,
        comparison_key = nothing,
        unit = "Percent",
        description = "米国10年国債利回り（名目）。EDPの汎用FRED passthroughで取得する" *
                      "（financial_stress role無し。既存の生 series）。",
    ),
    FinancialStressSeriesSpec(;
        key = :long_real_yield,
        provider_series_id = "DFII10",
        role = :long_real_yield,
        comparison_key = :long_nominal_yield,
        unit = "Percent",
        description = "米国10年TIPS利回り（実質）。",
    ),
    FinancialStressSeriesSpec(;
        key = :inflation_compensation,
        provider_series_id = "T10YIE",
        role = :inflation_compensation,
        comparison_key = :long_nominal_yield,
        unit = "Percent",
        description = "10年breakeven inflation（FREDの公式系列。DGS10-DFII10の残差を" *
                      "DME側で独自算出しない。両者に差があれば decomposition_residual " *
                      "として記録し term premium と呼ばない、ADR 0019）。",
    ),
]

function _financial_stress_check_catalog(
    catalog::AbstractVector{<:FinancialStressSeriesSpec},
)
    keys_seen = Symbol[]
    for spec in catalog
        spec.key in keys_seen &&
            throw(ArgumentError("catalog に重複した key があります: $(spec.key)"))
        push!(keys_seen, spec.key)
        spec.comparison_key === nothing && continue
        spec.comparison_key in keys_seen ||
            spec.comparison_key in getfield.(catalog, :key) ||
            throw(
                ArgumentError(
                    "$(spec.key).comparison_key=$(spec.comparison_key) が catalog に" *
                    "存在しません",
                ),
            )
    end
    return nothing
end

_financial_stress_check_catalog(FINANCIAL_STRESS_SERIES_CATALOG)

"""
    financial_stress_spec(key::Symbol) -> FinancialStressSeriesSpec

`FINANCIAL_STRESS_SERIES_CATALOG` から `key` に対応する `FinancialStressSeriesSpec` を返す。
"""
function financial_stress_spec(key::Symbol)::FinancialStressSeriesSpec
    idx = findfirst(spec -> spec.key == key, FINANCIAL_STRESS_SERIES_CATALOG)
    idx === nothing && throw(ArgumentError("catalog に存在しない key です: $key"))
    return FINANCIAL_STRESS_SERIES_CATALOG[idx]
end
