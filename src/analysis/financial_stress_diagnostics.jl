# financial_stress_diagnostics.jl: 金融ストレス観測から導出する差分・変化指標
# （Issue #260 Part B）。
#
# economic-data-provider（EDP）は系列間の差分を計算しない（EDPガイド §4・
# financial_stress_provider.jl 冒頭コメント）。本ファイルはDME側の責務として、
# 「同日の値を使う」原則の下で差分・変化を計算し、provenance
# （どの日付の値を使ったか・何件を欠測として除外したか）を残す。
#
# 片方の系列にその日の観測が無い場合、EDPと同様に補完しない。欠測日は結果から
# 除外し、除外件数を明示する（0やdirect fillへの暗黙変換をしない、Issue #260 対象外事項）。

"""
    AlignedDailySpread

2系列を同日で整列した差分（Issue #260 Part B）。`values` は `b` 側系列を基準にした
`a - b`（`unit` に従う。EDPの系列は `"Percent"` なので `bp_scale=100.0` で bp化する）。

## フィールド
- `a_key::Symbol` / `b_key::Symbol`: 差分の対象（`a - b`）。
- `dates::Vector{String}`: 両系列とも非欠測だった日付（昇順）。
- `values::Vector{Float64}`: `dates` に対応する差分（bp）。
- `n_common::Int`: `dates` の件数。
- `n_a_only_missing::Int`: `a` が欠測または不在で除外した日数（`b` 側日付集合との対比）。
- `n_b_only_missing::Int`: `b` が欠測または不在で除外した日数。
"""
struct AlignedDailySpread
    a_key::Symbol
    b_key::Symbol
    dates::Vector{String}
    values::Vector{Float64}
    n_common::Int
    n_a_only_missing::Int
    n_b_only_missing::Int
end

"""
    aligned_daily_spread_bp(a::FinancialStressSeries, b::FinancialStressSeries) -> AlignedDailySpread

`a.values - b.values` を同日（`dates` の積集合）についてのみ計算し、`"Percent"` 単位を
bp（×100）へ変換する（Issue #260 Part B）。どちらかが欠測の日は結果から除外し、
0 や前後の値へ補完しない。

`a.unit`・`b.unit` はいずれも `"Percent"` でなければならない（本カタログの8系列は
全て `"Percent"`。異なる単位の取り違えを検出する）。
"""
function aligned_daily_spread_bp(
    a::FinancialStressSeries,
    b::FinancialStressSeries,
)::AlignedDailySpread
    a.unit == "Percent" ||
        throw(ArgumentError("a.unit は \"Percent\" でなければなりません: $(a.unit)"))
    b.unit == "Percent" ||
        throw(ArgumentError("b.unit は \"Percent\" でなければなりません: $(b.unit)"))

    a_dates = Set(a.dates)
    b_dates = Set(b.dates)
    all_dates = sort(collect(union(a_dates, b_dates)))

    dates = String[]
    diffs = Float64[]
    n_a_only_missing = 0
    n_b_only_missing = 0
    for d in all_dates
        av = value_on_date(a, d)
        bv = value_on_date(b, d)
        if av === missing && bv !== missing
            n_a_only_missing += 1
        elseif bv === missing && av !== missing
            n_b_only_missing += 1
        elseif av === missing && bv === missing
            n_a_only_missing += 1
            n_b_only_missing += 1
        else
            push!(dates, d)
            push!(diffs, (av - bv) * 100.0)
        end
    end
    return AlignedDailySpread(
        a.key,
        b.key,
        dates,
        diffs,
        length(dates),
        n_a_only_missing,
        n_b_only_missing,
    )
end

"""
    latest_aligned(spread::AlignedDailySpread) -> Union{Tuple{String,Float64},Nothing}

`spread` の最新（日付順で最後）の観測を `(date, value_bp)` で返す。`n_common == 0` の
ときは `nothing`（0や欠測を偽装しない）。
"""
function latest_aligned(spread::AlignedDailySpread)::Union{Tuple{String, Float64}, Nothing}
    isempty(spread.dates) && return nothing
    return (spread.dates[end], spread.values[end])
end

function _fs_dataset_series(
    dataset::FinancialStressRawDataset,
    key::Symbol,
)::FinancialStressSeries
    haskey(dataset.observations, key) ||
        throw(ArgumentError("dataset に存在しない key です: $key"))
    obs = dataset.observations[key]
    obs.status == :ok || throw(
        ArgumentError(
            "key=$key の観測が :ok ではありません（status=$(obs.status)）: $(obs.detail)",
        ),
    )
    return obs.series
end

"""
    ccc_minus_broad_hy_oas_bp(dataset::FinancialStressRawDataset) -> AlignedDailySpread

CCC & Lower OAS（`:ccc_oas`）と広範HY OAS（`:broad_hy_oas`）の同日差分（bp）。
最弱信用層が広範HYより先行悪化しているかを示す（Issue #260 背景）。
"""
ccc_minus_broad_hy_oas_bp(dataset::FinancialStressRawDataset) = aligned_daily_spread_bp(
    _fs_dataset_series(dataset, :ccc_oas),
    _fs_dataset_series(dataset, :broad_hy_oas),
)

"""
    sofr_minus_iorb_bp(dataset::FinancialStressRawDataset) -> AlignedDailySpread

SOFR と政策アンカー（IORB）の同日差分（bp）。secured funding市場の政策アンカーからの
乖離を示す。
"""
sofr_minus_iorb_bp(dataset::FinancialStressRawDataset) = aligned_daily_spread_bp(
    _fs_dataset_series(dataset, :sofr),
    _fs_dataset_series(dataset, :iorb),
)

"""
    tgcr_minus_iorb_bp(dataset::FinancialStressRawDataset) -> AlignedDailySpread

TGCR と政策アンカー（IORB）の同日差分（bp）。tri-party GC repoのみに限定した
secured funding市場の乖離を示す。
"""
tgcr_minus_iorb_bp(dataset::FinancialStressRawDataset) = aligned_daily_spread_bp(
    _fs_dataset_series(dataset, :tgcr),
    _fs_dataset_series(dataset, :iorb),
)

"""
    sofr_minus_tgcr_bp(dataset::FinancialStressRawDataset) -> AlignedDailySpread

SOFR と TGCR の同日差分（bp）。broadなsecured funding指標とtri-party GCのみの指標の
乖離を示す。
"""
sofr_minus_tgcr_bp(dataset::FinancialStressRawDataset) = aligned_daily_spread_bp(
    _fs_dataset_series(dataset, :sofr),
    _fs_dataset_series(dataset, :tgcr),
)

"""
    yield_shift_bps(s::FinancialStressSeries, from_date::AbstractString, to_date::AbstractString)
        -> Union{Float64,Missing}

`s` の `from_date` から `to_date` への変化（bp、`"Percent"` を ×100）。`from_date`・
`to_date` のいずれかが欠測（不在・`missing`値）のときは `missing`
（0や前後の値への補完をしない、Issue #260 対象外事項）。
"""
function yield_shift_bps(
    s::FinancialStressSeries,
    from_date::AbstractString,
    to_date::AbstractString,
)::Union{Float64, Missing}
    s.unit == "Percent" ||
        throw(ArgumentError("s.unit は \"Percent\" でなければなりません: $(s.unit)"))
    from_value = value_on_date(s, from_date)
    to_value = value_on_date(s, to_date)
    (from_value === missing || to_value === missing) && return missing
    return (to_value - from_value) * 100.0
end

"""
    long_rate_shift_components(dataset::FinancialStressRawDataset, from_date, to_date;
                                secured_funding_reference = :iorb)
        -> NamedTuple

`dataset` の `:long_nominal_yield`・`:long_real_yield`・`:inflation_compensation`・
`:sofr`（`secured_funding_reference` 対比）から、`from_date`→`to_date` の変化を
`long_nominal_yield_shift_bps`・`long_real_yield_shift_bps`・
`inflation_compensation_shift_bps`・`secured_funding_spread_shift_bps` として返す
（Issue #260 Part A の `FundingShockComponents` へそのまま渡せる形。ただし本関数は
`FundingShockComponents` を構築しない。基準日の選定は Part D の holdout artifact 側の
責務であり、本ファイルはモデル入力を知らない、macro_events.jl と同じ契約1）。

`secured_funding_spread_shift_bps` は `(sofr - secured_funding_reference)` の
`from_date`→`to_date` の変化として計算する（Issue #260 背景「SOFR/TGCR minus policy
anchor」）。いずれかの構成要素が欠測（不在・値欠測）のときは、その要素だけ `missing` を
返し、他の要素の計算を妨げない。
"""
function long_rate_shift_components(
    dataset::FinancialStressRawDataset,
    from_date::AbstractString,
    to_date::AbstractString;
    secured_funding_reference::Symbol = :iorb,
)
    nominal = _fs_dataset_series(dataset, :long_nominal_yield)
    real = _fs_dataset_series(dataset, :long_real_yield)
    inflation_comp = _fs_dataset_series(dataset, :inflation_compensation)
    sofr = _fs_dataset_series(dataset, :sofr)
    anchor = _fs_dataset_series(dataset, secured_funding_reference)

    # `missing` はどちらの脚が欠測でも Julia の Missing 伝播でそのまま `missing` になる
    # （0や補完値へフォールバックしない）。
    secured_funding_spread_shift_bps =
        yield_shift_bps(sofr, from_date, to_date) -
        yield_shift_bps(anchor, from_date, to_date)

    return (
        long_nominal_yield_shift_bps = yield_shift_bps(nominal, from_date, to_date),
        long_real_yield_shift_bps = yield_shift_bps(real, from_date, to_date),
        inflation_compensation_shift_bps = yield_shift_bps(
            inflation_comp,
            from_date,
            to_date,
        ),
        secured_funding_spread_shift_bps = secured_funding_spread_shift_bps,
        from_date = from_date,
        to_date = to_date,
        secured_funding_reference = secured_funding_reference,
    )
end
