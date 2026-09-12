# long_rate_funding_shock.jl: 長期金利・funding-cost shockの生データ分解と
# `:LongRateFundingShock`（Issue #260）の構築ヘルパ。
#
# 政策金利変更を伴わない／政策金利だけでは説明できない長期金利上昇を、`:PolicyRateChange`
# （政策金利、短期）とは別入力として扱うための型を定義する。`FundingShockComponents` は
# 観測された生データの分解（long nominal yield / long real yield / inflation compensation /
# secured funding spread）を保持し、`FundingShockPassThrough` は分解要素から CCC の
# `spread_shock_ex`（bp）へのpass-throughを**明示的な versioned parameter**として表現する
# （暗黙の1:1 mappingにしない）。`credit_spread_shift_bps` は既存の `:CreditSpreadShock`
# （マクロイベント変換契約 §4.2 row 5）で既に独立入力として表現できるため、本ファイルの
# 対象に含めない（二重計上防止）。
#
# 本ファイルは**モデルを知らない**（macro_events.jl と同じ契約1）。CCC の
# `exogenous_variables(m)` や `spread_shock_ex` を直接参照しない。`:LongRateFundingShock` から
# `spread_shock_ex` への実際のマッピングは `event_type_registry.jl`（レジストリ行）と
# `scenarios/adapters/capex_credit_cycle_event_adapter.jl`（`EventMappingRule`）が持つ。
#
# 設計契約:
#   docs/architecture/macro_event_contract.md §15（Issue #260 による改訂）
#   docs/adr/0019-long-rate-funding-shock-contract.md

# ------------------------------------------------------------
# FundingShockComponents
# ------------------------------------------------------------

"""
    FundingShockComponents

長期金利・funding条件ショックの観測された生データ分解（Issue #260 Part A）。

## フィールド
- `long_nominal_yield_shift_bps::Float64`: 長期名目金利（例: 10年国債利回り）の変化幅
  （bp）。必須（欠測を許さない）。
- `long_real_yield_shift_bps::Union{Float64,Missing}`: 長期実質金利（例: 10年TIPS利回り）の
  変化幅（bp）。観測できない場合は `missing`（0へ丸めない）。
- `inflation_compensation_shift_bps::Union{Float64,Missing}`: breakeven inflation
  （名目 − 実質）の変化幅（bp）。観測できない場合は `missing`。
- `secured_funding_spread_shift_bps::Float64`: secured funding市場のストレス
  （例: SOFR/TGCRの政策アンカー対比乖離）の変化幅（bp）。必須。
- `decomposition_residual_bps::Union{Float64,Missing}`: `long_real_yield_shift_bps` と
  `inflation_compensation_shift_bps` が両方とも非欠測のときのみ
  `long_nominal_yield_shift_bps - (long_real_yield_shift_bps + inflation_compensation_shift_bps)`
  として自動算出する。**この残差を `term premium` と呼ばない**（根拠のない高精度推定を
  行わないという対象外事項。呼称が必要な場合は別途、根拠となる観測分解を明記する）。

`credit_spread_shift_bps` はここに含めない。既存の `:CreditSpreadShock`
（マクロイベント変換契約 §4.2 row 5）で独立入力として既に表現できるため、本 struct へ重複して
持たせると二重計上の余地が生まれる。
"""
struct FundingShockComponents
    long_nominal_yield_shift_bps::Float64
    long_real_yield_shift_bps::Union{Float64, Missing}
    inflation_compensation_shift_bps::Union{Float64, Missing}
    secured_funding_spread_shift_bps::Float64
    decomposition_residual_bps::Union{Float64, Missing}

    function FundingShockComponents(;
        long_nominal_yield_shift_bps::Float64,
        secured_funding_spread_shift_bps::Float64,
        long_real_yield_shift_bps::Union{Float64, Missing} = missing,
        inflation_compensation_shift_bps::Union{Float64, Missing} = missing,
    )
        _macro_event_require_finite(
            "FundingShockComponents.long_nominal_yield_shift_bps",
            long_nominal_yield_shift_bps,
        )
        _macro_event_require_finite(
            "FundingShockComponents.secured_funding_spread_shift_bps",
            secured_funding_spread_shift_bps,
        )
        _macro_event_require_finite(
            "FundingShockComponents.long_real_yield_shift_bps",
            long_real_yield_shift_bps,
        )
        _macro_event_require_finite(
            "FundingShockComponents.inflation_compensation_shift_bps",
            inflation_compensation_shift_bps,
        )
        residual =
            if long_real_yield_shift_bps === missing ||
               inflation_compensation_shift_bps === missing
                missing
            else
                long_nominal_yield_shift_bps -
                (long_real_yield_shift_bps + inflation_compensation_shift_bps)
            end
        return new(
            long_nominal_yield_shift_bps,
            long_real_yield_shift_bps,
            inflation_compensation_shift_bps,
            secured_funding_spread_shift_bps,
            residual,
        )
    end
end

# ------------------------------------------------------------
# FundingShockPassThrough
# ------------------------------------------------------------

"長期金利・funding-cost shockのpass-through parameter設定の version。"
const FUNDING_SHOCK_PASS_THROUGH_VERSION = "funding-shock-pass-through/1.0.0"

"""
    FundingShockPassThrough

`FundingShockComponents` から実効借入コスト（CCCの `spread_shock_ex`、bp）への
pass-through係数（Issue #260 Part A）。**既定値（1.0）は「暗黙の1:1」ではなく、
`version` とともに明示的に記録・追跡される named constant**である。呼び出し側が
根拠を持って上書きする場合はsensitivity分析として別途扱い、上書きの事実と値を
出力へ残す（呼び出し側の責務）。

## フィールド
- `long_nominal_yield_pass_through::Float64`: `long_nominal_yield_shift_bps` の
  実効借入コストへの反映率。既定 `1.0`。
- `secured_funding_pass_through::Float64`: `secured_funding_spread_shift_bps` の
  実効借入コストへの反映率。既定 `1.0`。
- `version::String`: 本係数セットの version（既定 `FUNDING_SHOCK_PASS_THROUGH_VERSION`）。

`long_real_yield_shift_bps`・`inflation_compensation_shift_bps`・
`decomposition_residual_bps` はここでは重み付けしない。これらは
`long_nominal_yield_shift_bps` の内訳（診断用）であり、名目値と並行して再度加算すると
二重計上になる。
"""
struct FundingShockPassThrough
    long_nominal_yield_pass_through::Float64
    secured_funding_pass_through::Float64
    version::String

    function FundingShockPassThrough(;
        long_nominal_yield_pass_through::Float64 = 1.0,
        secured_funding_pass_through::Float64 = 1.0,
        version::AbstractString = FUNDING_SHOCK_PASS_THROUGH_VERSION,
    )
        isfinite(long_nominal_yield_pass_through) || throw(
            ArgumentError(
                "FundingShockPassThrough.long_nominal_yield_pass_through は有限でなければ" *
                "なりません（実値: $(long_nominal_yield_pass_through)）",
            ),
        )
        isfinite(secured_funding_pass_through) || throw(
            ArgumentError(
                "FundingShockPassThrough.secured_funding_pass_through は有限でなければ" *
                "なりません（実値: $(secured_funding_pass_through)）",
            ),
        )
        isempty(version) && throw(
            ArgumentError("FundingShockPassThrough.version は空文字であってはいけません"),
        )
        return new(
            long_nominal_yield_pass_through,
            secured_funding_pass_through,
            String(version),
        )
    end
end

"""
    funding_shock_magnitude_bps(components, pass_through = FundingShockPassThrough()) -> Float64

`components` と `pass_through` から、CCC の `spread_shock_ex`（bp、`:additive`）へ適用する
実効magnitudeを算出する（Issue #260 Part A）。

```
magnitude = long_nominal_yield_shift_bps * long_nominal_yield_pass_through
          + secured_funding_spread_shift_bps * secured_funding_pass_through
```

`long_real_yield_shift_bps`・`inflation_compensation_shift_bps`・
`decomposition_residual_bps` は含めない（`FundingShockPassThrough` のdocstring参照）。
`credit_spread_shift_bps` も含めない（既存 `:CreditSpreadShock` の対象）。
"""
function funding_shock_magnitude_bps(
    components::FundingShockComponents,
    pass_through::FundingShockPassThrough = FundingShockPassThrough(),
)
    return components.long_nominal_yield_shift_bps *
           pass_through.long_nominal_yield_pass_through +
           components.secured_funding_spread_shift_bps *
           pass_through.secured_funding_pass_through
end

# ------------------------------------------------------------
# ScenarioAssumption 構築ヘルパ
# ------------------------------------------------------------

function _funding_shock_caveats(
    components::FundingShockComponents,
    pass_through::FundingShockPassThrough,
    caller_caveats::AbstractString,
)
    parts = String[
        "分解: long_nominal_yield_shift_bps=$(components.long_nominal_yield_shift_bps)" * " / long_real_yield_shift_bps=$(components.long_real_yield_shift_bps)" * " / inflation_compensation_shift_bps=$(components.inflation_compensation_shift_bps)" * " / secured_funding_spread_shift_bps=$(components.secured_funding_spread_shift_bps)" * " / decomposition_residual_bps=$(components.decomposition_residual_bps)" * "（term premiumではない、根拠なく命名しない）。",
        "pass_through: version=$(pass_through.version)" * " / long_nominal_yield_pass_through=$(pass_through.long_nominal_yield_pass_through)" * " / secured_funding_pass_through=$(pass_through.secured_funding_pass_through)" * "（暗黙の1:1ではなく明示parameterとして記録）。",
        "policy_rate（:PolicyRateChange）・credit_spread（:CreditSpreadShock）とは別入力であり、" * "二重計上防止のため credit_spread_shift_bps は本assumptionに含めない。",
    ]
    isempty(caller_caveats) || push!(parts, String(caller_caveats))
    return join(parts, " ")
end

"""
    long_rate_funding_scenario_assumption(;
        assumption_id, components, timing, persistence, provenance,
        pass_through = FundingShockPassThrough(), magnitude_source = :derived,
        sector = :unknown, geography = "US", confidence = nothing,
        uncertainty = nothing, notes = "", caveats = "",
    ) -> ScenarioAssumption

`:LongRateFundingShock` の `ScenarioAssumption`（`L3`）を構築する（Issue #260 Part A）。
`magnitude` は `funding_shock_magnitude_bps(components, pass_through)` から自動算出し、
`direction` は `magnitude` の符号から自動決定する（呼び出し側が符号を誤って指定できない
ようにする）。`target_concepts = [:long_rate_funding_condition]`・`unit = "bp"`・
`application_mode = :additive` に固定する（レジストリの `allowed_*` と一致）。

`components`・`pass_through` の内訳は `caveats` へ自動的に記録する（必須 methodology
metadata、`macro_event_type_spec(:LongRateFundingShock).required_methodology_keys`）。
呼び出し側の `caveats` はこれに追記される。

`magnitude_source` の既定は `:derived`（観測された生データから pass-through 経由で導出した
値であり、直接観測された bp ではないため）。
"""
function long_rate_funding_scenario_assumption(;
    assumption_id::AbstractString,
    components::FundingShockComponents,
    timing::EventTiming,
    persistence::PersistenceSpec,
    provenance::EventProvenance,
    pass_through::FundingShockPassThrough = FundingShockPassThrough(),
    magnitude_source::Symbol = :derived,
    sector::Symbol = :unknown,
    geography::AbstractString = "US",
    confidence::Union{Float64, Nothing} = nothing,
    uncertainty::Union{Tuple{Float64, Float64}, Nothing} = nothing,
    notes::AbstractString = "",
    caveats::AbstractString = "",
)
    magnitude = funding_shock_magnitude_bps(components, pass_through)
    direction = magnitude > 0 ? :up : (magnitude < 0 ? :down : :none)
    return scenario_assumption(;
        assumption_id = assumption_id,
        event_type = :LongRateFundingShock,
        sector = sector,
        direction = direction,
        magnitude = magnitude,
        unit = "bp",
        magnitude_source = magnitude_source,
        application_mode = :additive,
        timing = timing,
        persistence = persistence,
        target_concepts = [:long_rate_funding_condition],
        provenance = provenance,
        geography = geography,
        confidence = confidence,
        uncertainty = uncertainty,
        notes = notes,
        caveats = _funding_shock_caveats(components, pass_through, caveats),
    )
end
