# financial_stress_catalog.jl: 米国 credit-tier / secured-funding / long-rate 観測系列の
# catalog（Issue #260 Part B）。
#
# economic-data-provider（EDP）#189 が登録した financial-stress 系列5種
# （CCC OAS・broad HY OAS・SOFR・TGCR・IORB、EDP ADR 028）と、EDP が既存の汎用 FRED
# passthrough（`GET /v1/series/{series_id}`）でそのまま取得できる長期金利系列3種
# （10年名目金利・10年TIPS実質金利・inflation compensation）を対象とする。
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
#   docs/adr/0019-long-rate-funding-shock-contract.md（Part A、本カタログが供給する
#     生データの用途）
#   economic-data-provider ADR 028・docs/guides/financial-stress.md（vendor: 系列選定の
#     一次情報。DME側ではvendorコピーを持たず本ファイルが参照するのみ）

"金融ストレス観測 catalog の version。"
const FINANCIAL_STRESS_CATALOG_VERSION = "financial-stress-catalog/1.0.0"

"""
    FINANCIAL_STRESS_ROLES

`FinancialStressSeriesSpec.role` の確定集合。EDP ADR 028 の `role`（5種）に加え、
EDP の汎用 FRED passthrough で取得する長期金利系列3種の役割を独自に定義する
（EDPはこれらに `financial_stress` roleを付与していないため、DME側で命名する）。
"""
const FINANCIAL_STRESS_ROLES = (
    :credit_stress_ccc_oas,
    :credit_stress_broad_hy_oas,
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

金融ストレス観測 catalog 本体（8系列、Issue #260 Part B）。`comparison_key` は
「同日で比較して初めて意味を持つ」関係を明示するのみであり、差分計算そのものは
`src/analysis/financial_stress_diagnostics.jl` が行う（EDPは差分を計算しない、
EDPガイド §4 と同じ責務境界）。
"""
const FINANCIAL_STRESS_SERIES_CATALOG = FinancialStressSeriesSpec[
    FinancialStressSeriesSpec(;
        key = :ccc_oas,
        provider_series_id = "BAMLH0A3HYC",
        role = :credit_stress_ccc_oas,
        comparison_key = :broad_hy_oas,
        unit = "Percent",
        description = "ICE BofA CCC & Lower US High Yield Index Option-Adjusted Spread。" *
                      "最弱信用層のOAS。broad HY OASとは別系列として保持し暗黙fallbackしない。",
    ),
    FinancialStressSeriesSpec(;
        key = :broad_hy_oas,
        provider_series_id = "BAMLH0A0HYM2",
        role = :credit_stress_broad_hy_oas,
        comparison_key = nothing,
        unit = "Percent",
        description = "ICE BofA US High Yield Index Option-Adjusted Spread（広範HY）。" *
                      "ccc_oas との比較baseline。CCCモデルの較正入力（spread_hy、" *
                      "capex_credit_cycle_catalog.jl）とは独立に取得する（責務分離）。",
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
