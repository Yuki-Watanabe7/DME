# CCC measurement / empirical dataset layer (Issue #243 / P-3).
#
# Converts the raw EDP observations from Issue #242 into CCC model units on a
# common quarterly axis while preserving, per series, every transformation stage
# and the nine-element measurement contract (unit, sector scope, nominal/real,
# seasonal adjustment, native→quarterly rule, aggregation/allocation/proxy
# methodology, vintage/provenance).  Steady-state targets, calibration,
# estimation, and historical replay belong to later layers (#244–#251); this
# file performs no model calls and adds no interpolation beyond the ones the
# catalog declares.
#
# Design: docs/architecture/capex_credit_cycle_empirical_integration.md
#         §5.3–§5.4, §7 ; docs/models/capex_credit_cycle_empirical_strategy.md §4
#         ; ADR 0018.

# `:as_of` は先取りしない（`Z-21` / §7.5）。vintage_mode は 1 値に固定する。
const _CAPEX_CC_VINTAGE_MODES = (:latest_only,)
const _CAPEX_CC_ANNUAL_TO_QUARTERLY_METHODS = (:end_of_year_allocation, :flat)

# ---------------------------------------------------------------------------
# 出力型
# ---------------------------------------------------------------------------

"""
    CapexMeasurement

One CCC catalog key together with the applied observation equation.  `stages`
keeps the raw series and each intermediate result (frequency alignment →
de-annualisation → index anchoring); the final `measured` series is in CCC
model units on a quarterly axis.  `conversion_formula` is the verbatim chain of
transformations.  `deflator_key`, `allocation_shares`, and the level anchoring
of index series whose anchor needs an external series are populated by the
calibration layer, not here — those cases are recorded in `warnings`.
"""
struct CapexMeasurement
    key::Symbol
    spec::CapexSeriesSpec
    stages::Vector{Pair{String, DataSeries}}
    measured::DataSeries
    conversion_formula::String
    deflator_key::Union{Symbol, Nothing}
    anchor_detail::Union{String, Nothing}
    allocation_key::Union{Symbol, Nothing}
    allocation_shares::Union{Dict{String, Float64}, Nothing}
    n_source_missing::Int
    n_invalid::Int
    warnings::Vector{String}
end

"""
    CapexSampleWindow

The common quarterly sample decided by the inner join of the
`:calibration_required` series.  `binding_series` lists the calibration-required
keys whose non-missing coverage touches an endpoint; `dropped_dates` and
`exclusion_reasons` record the quarters left out and why.
"""
struct CapexSampleWindow
    sample_start::String
    sample_end::String
    n_obs::Int
    binding_series::Vector{Symbol}
    dropped_dates::Vector{String}
    exclusion_reasons::Dict{String, Int}
end

"""
    CapexEmpiricalDataset

CCC measurements aligned to a common quarterly axis with the observation
classification (`roles` / `observability`) preserved.  Structurally latent keys
(`observability ∈ (:E, :A)`) keep a role but carry no values — they are never
imputed.  `values` holds every non-latent key (including `:validation_only`), so
callers can drop non-calibration inputs mechanically through `roles`.
`dataset_hash` in `metadata` is derived from the catalog version, provider
series IDs, conversion formulas, sample, and values — never from `retrieved_at`,
the provider location, or the transport mode.
"""
struct CapexEmpiricalDataset
    catalog::Vector{CapexSeriesSpec}
    measurements::Dict{Symbol, CapexMeasurement}
    dates::Vector{String}
    observation_times::Vector{Float64}
    values::Dict{Symbol, Vector{Union{Float64, Missing}}}
    roles::Dict{Symbol, Symbol}
    observability::Dict{Symbol, Symbol}
    sample::CapexSampleWindow
    vintage_mode::Symbol
    quality_flags::Dict{String, Any}
    raw::CapexRawDataset
    metadata::Dict{String, Any}
end

Base.length(ds::CapexEmpiricalDataset) = length(ds.dates)

# ---------------------------------------------------------------------------
# 四半期ラベルの構造的 parse（Keen 実証層と同じ規律。文字列順で結合しない）
# ---------------------------------------------------------------------------

function _capex_parse_quarter_label(label::AbstractString)::Tuple{Int, Int}
    m = match(r"^(\d{4})-Q([1-4])$", label)
    m === nothing &&
        throw(ArgumentError("四半期ラベル形式が不正です: '$(label)'（YYYY-Qn 形式が必要）"))
    return parse(Int, m.captures[1]), parse(Int, m.captures[2])
end

function _capex_quarter_index(label::AbstractString)::Int
    year, quarter = _capex_parse_quarter_label(label)
    return year * 4 + (quarter - 1)
end

function _capex_quarter_time(label::AbstractString)::Float64
    year, quarter = _capex_parse_quarter_label(label)
    return year + (quarter - 1) * 0.25
end

# ---------------------------------------------------------------------------
# 系列変換の純粋ヘルパー（0 埋め・clamp をしない）
# ---------------------------------------------------------------------------

function _capex_scale_series(s::DataSeries, factor::Real, note::String)::DataSeries
    vals = Union{Float64, Missing}[
        ismissing(v) ? missing : Float64(v) * Float64(factor) for v in s.values
    ]
    meta = deepcopy(s.metadata)
    _append_transform!(meta, note)
    return DataSeries(
        s.id,
        s.name,
        s.source,
        s.frequency,
        s.unit,
        copy(s.dates),
        vals,
        meta,
    )
end

function _capex_offset_series(s::DataSeries, offset::Real, note::String)::DataSeries
    vals = Union{Float64, Missing}[
        ismissing(v) ? missing : Float64(v) - Float64(offset) for v in s.values
    ]
    meta = deepcopy(s.metadata)
    _append_transform!(meta, note)
    return DataSeries(
        s.id,
        s.name,
        s.source,
        s.frequency,
        s.unit,
        copy(s.dates),
        vals,
        meta,
    )
end

"""
    capex_annual_to_quarterly(s::DataSeries; method = :end_of_year_allocation) -> DataSeries

Convert an annual (`"YYYY"`) series to quarterly (`"YYYY-Qn"`) without touching
`preprocess.jl`'s generic `to_quarterly` (`Z-04`).

- `:end_of_year_allocation` (default): the annual value is the year-end level
  placed at `Qn = 4`; `Q1`–`Q3` are the linear path from the previous year-end.
  The first year (and any year after a gap) keeps only its `Q4` value.  Use for
  stocks (`cap_s`).
- `:flat`: the annual value is repeated across all four quarters.  Use for
  annual flows before the separate `÷ 4` de-annualisation (`dep_s`).

Interpolation smooths within-year variation, so annual-derived series must not
drive high-frequency validation metrics (recorded as a measurement warning).
"""
function capex_annual_to_quarterly(
    s::DataSeries;
    method::Symbol = :end_of_year_allocation,
)::DataSeries
    s.frequency == Annual ||
        throw(ArgumentError("年次系列が必要です (frequency=$(s.frequency))"))
    method in _CAPEX_CC_ANNUAL_TO_QUARTERLY_METHODS || throw(
        ArgumentError(
            "method は $(_CAPEX_CC_ANNUAL_TO_QUARTERLY_METHODS) のいずれかでなければなりません: $method",
        ),
    )

    parsed = Tuple{Int, Union{Float64, Missing}}[]
    seen = Set{Int}()
    for (date, value) in zip(s.dates, s.values)
        m = match(r"^(\d{4})$", date)
        m === nothing &&
            throw(ArgumentError("年次日付形式が不正です: '$(date)'（YYYY 形式が必要）"))
        year = parse(Int, m.captures[1])
        year in seen && throw(ArgumentError("年次系列に重複した年があります: '$(date)'"))
        push!(seen, year)
        push!(parsed, (year, value))
    end
    sort!(parsed; by = first)

    new_dates = String[]
    new_values = Union{Float64, Missing}[]
    prev_year::Union{Int, Nothing} = nothing
    prev_value::Union{Float64, Missing} = missing
    for (year, value) in parsed
        for q in 1:4
            push!(new_dates, "$(year)-Q$(q)")
        end
        if method === :flat
            push!(new_values, value, value, value, value)
        elseif prev_year !== nothing &&
               prev_year == year - 1 &&
               !ismissing(prev_value) &&
               !ismissing(value)
            step = (value - prev_value) / 4
            push!(
                new_values,
                prev_value + step,
                prev_value + 2step,
                prev_value + 3step,
                value,
            )
        else
            push!(new_values, missing, missing, missing, value)
        end
        prev_year = year
        prev_value = value
    end

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "capex_annual_to_quarterly(method=$method)")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        Quarterly,
        s.unit,
        new_dates,
        new_values,
        meta,
    )
end

"""
    _capex_eop_to_bop(s::DataSeries) -> DataSeries

Construct a beginning-of-period (`BOP`) quarterly series as the one-quarter lag
of an end-of-period (`EOP`) series: `bop[t] = eop[t-1]`.  `BOP` is not an
independent aggregation method; the model reads it as `x[t-1]` (design §7.3,
`Z-05`).  Quarters with no predecessor become `missing`.
"""
function _capex_eop_to_bop(s::DataSeries)::DataSeries
    s.frequency == Quarterly ||
        throw(ArgumentError("BOP 構成には四半期系列が必要です (frequency=$(s.frequency))"))
    by_index = Dict{Int, Union{Float64, Missing}}()
    for (date, value) in zip(s.dates, s.values)
        idx = _capex_quarter_index(date)
        haskey(by_index, idx) &&
            throw(ArgumentError("四半期ラベルが重複しています: '$(date)'"))
        by_index[idx] = value
    end
    order = sortperm([_capex_quarter_index(d) for d in s.dates])
    new_dates = s.dates[order]
    new_values = Union{Float64, Missing}[
        get(by_index, _capex_quarter_index(d) - 1, missing) for d in new_dates
    ]
    meta = deepcopy(s.metadata)
    _append_transform!(meta, "eop_to_bop_lag(1)")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        Quarterly,
        s.unit,
        new_dates,
        new_values,
        meta,
    )
end

# ---------------------------------------------------------------------------
# 指数系列のアンカー水準化
# ---------------------------------------------------------------------------

# returns (series, anchor_detail, formula_fragment, deferred::Bool)
function _capex_anchor_index(s::DataSeries, spec::CapexSeriesSpec)
    anchor = spec.anchor
    anchor === nothing &&
        throw(ArgumentError("index 系列に anchor がありません: $(spec.key)"))
    base_year =
        spec.declared_base_year === nothing ? "n/a" : string(spec.declared_base_year)
    finite_positions =
        [i for i in eachindex(s.values) if !ismissing(s.values[i]) && isfinite(s.values[i])]
    if isempty(finite_positions)
        return s,
        "anchor :$(anchor) skipped: no finite observations (declared_base_year=$base_year)",
        "anchor(:$(anchor),empty)",
        true
    end
    by_time = sort(finite_positions; by = i -> _capex_quarter_index(s.dates[i]))
    window_lo = s.dates[first(by_time)]
    window_hi = s.dates[last(by_time)]
    mean_value =
        sum(Float64(s.values[i]) for i in finite_positions) / length(finite_positions)

    if anchor === :baseline_mean_one
        if !isfinite(mean_value) || mean_value == 0.0
            return s,
            "anchor :baseline_mean_one skipped: degenerate mean (declared_base_year=$base_year)",
            "anchor(:baseline_mean_one,degenerate)",
            true
        end
        out = _capex_scale_series(
            s,
            1.0 / mean_value,
            "anchor(:baseline_mean_one over $window_lo..$window_hi)",
        )
        return out,
        "index rebased to mean=1 over $window_lo..$window_hi (declared_base_year=$base_year)",
        "anchor(:baseline_mean_one)",
        false
    elseif anchor === :baseline_mean_zero
        out = _capex_offset_series(
            s,
            mean_value,
            "anchor(:baseline_mean_zero over $window_lo..$window_hi)",
        )
        return out,
        "index recentred to mean=0 over $window_lo..$window_hi (declared_base_year=$base_year)",
        "anchor(:baseline_mean_zero)",
        false
    elseif anchor === :bea_annual_real_value_added
        return s,
        "level anchoring to BEA annual real value added deferred to calibration layer " *
        "(declared_base_year=$base_year; y_s[q] = va_s^annual(base)/st_va_share_s/4 " *
        "× IP_s[q]/mean_base IP_s[q])",
        "anchor(:bea_annual_real_value_added,deferred)",
        true
    else
        throw(ArgumentError("未知の anchor 方式です: $(anchor)（key=$(spec.key)）"))
    end
end

# ---------------------------------------------------------------------------
# 1 系列の観測方程式適用
# ---------------------------------------------------------------------------

function _capex_annual_method(spec::CapexSeriesSpec)::Symbol
    return spec.model_timing == :EOP ? :end_of_year_allocation : :flat
end

function _capex_measure_series(obs::CapexRawObservation)::CapexMeasurement
    spec = obs.spec
    source = obs.series::DataSeries
    stages = Pair{String, DataSeries}["source" => source]
    formula = String["source($(lowercase(string(source.frequency))))"]
    warnings = String[]
    n_source_missing = count(ismissing, source.values)

    current = source
    if source.frequency == Monthly
        current = to_quarterly(source; method = spec.aggregation)
        push!(stages, "quarterly(:$(spec.aggregation))" => current)
        push!(formula, "to_quarterly(:$(spec.aggregation))")
    elseif source.frequency == Annual
        annual_method = _capex_annual_method(spec)
        current = capex_annual_to_quarterly(source; method = annual_method)
        push!(stages, "quarterly($(annual_method))" => current)
        push!(formula, "capex_annual_to_quarterly(:$(annual_method))")
        annual_method === :end_of_year_allocation && push!(
            warnings,
            "annual→quarterly interpolation smooths within-year variation; do not use " *
            "$(spec.key) for high-frequency validation metrics",
        )
    elseif source.frequency != Quarterly
        throw(ArgumentError("未対応の頻度です: $(source.frequency)（key=$(spec.key)）"))
    end

    if spec.annualized
        current = _capex_scale_series(current, 0.25, "deannualize(÷4)")
        push!(stages, "deannualized" => current)
        push!(formula, "÷4")
        source.frequency == Monthly &&
            spec.aggregation === :sum &&
            push!(
                warnings,
                "monthly annual-rate series summed then divided by 4; confirm the catalog " *
                "frequency (SAAR series are usually published quarterly)",
            )
    end

    anchor_detail::Union{String, Nothing} = nothing
    if spec.level_form === :index
        current, anchor_detail, anchor_fragment, deferred =
            _capex_anchor_index(current, spec)
        push!(stages, "anchored" => current)
        push!(formula, anchor_fragment)
        deferred && push!(
            warnings,
            "index level anchoring for $(spec.key) via :$(spec.anchor) is deferred to the " *
            "calibration layer; the measured series stays in index form",
        )
    end

    spec.declared_real_nominal === :nominal && push!(
        warnings,
        "nominal series; real conversion via a deflator is applied in the calibration layer",
    )
    spec.methodology === :allocation && push!(
        warnings,
        "allocation methodology (allocation_key=:$(spec.allocation_key)); sector shares and " *
        "the allocation-key sensitivity are applied in the calibration layer",
    )
    spec.methodology === :proxy &&
        spec.scope_bias in (:over, :under, :indeterminate) &&
        push!(
            warnings,
            "proxy series with $(spec.scope_bias) scope bias relative to: $(spec.sector_scope)",
        )

    n_invalid = count(v -> !ismissing(v) && !isfinite(v), current.values)

    return CapexMeasurement(
        spec.key,
        spec,
        stages,
        current,
        join(formula, " → "),
        nothing,
        anchor_detail,
        spec.allocation_key,
        nothing,
        n_source_missing,
        n_invalid,
        warnings,
    )
end

# ---------------------------------------------------------------------------
# dataset identity（§5.4。retrieved_at / provider_base / mode を含めない）
# ---------------------------------------------------------------------------

function _capex_dataset_hash(
    raw::CapexRawDataset,
    catalog::Vector{CapexSeriesSpec},
    measurements::Dict{Symbol, CapexMeasurement},
    dates::Vector{String},
    value_map::Dict{Symbol, Vector{Union{Float64, Missing}}},
    window::CapexSampleWindow,
)::String
    payload = Dict{String, Any}(
        "catalog_version" => Dict{String, Any}(
            "version" => raw.catalog_version,
            "integration_version" => raw.integration_version,
            "keys" => sort([String(spec.key) for spec in catalog]),
        ),
        "integration_version" => CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "provider_series_ids" => sort([spec.provider_series_id for spec in catalog]),
        # provider raw identity already excludes retrieved_at / provider location /
        # transport mode (#242 `_capex_raw_identity`), so chaining it here keeps the
        # dataset hash volatile-field-free while linking it to the raw layer.
        "raw_identity" => get(raw.metadata, "raw_identity", nothing),
        "measurement_formulas" => Dict{String, Any}(
            String(key) => measurement.conversion_formula for
            (key, measurement) in measurements
        ),
        "sample" => Dict{String, Any}(
            "start" => window.sample_start,
            "end" => window.sample_end,
            "n_obs" => window.n_obs,
            "binding_series" => sort(String.(window.binding_series)),
        ),
        "dates" => dates,
        "values" => Dict{String, Any}(
            String(key) => Any[
                (ismissing(v) || !isfinite(v)) ? nothing : Float64(v) for v in series
            ] for (key, series) in value_map
        ),
    )
    return "sha256:" * sha256_hex_of_canonical(payload)
end

# ---------------------------------------------------------------------------
# empirical dataset の構築
# ---------------------------------------------------------------------------

"""
    build_capex_empirical_dataset(raw::CapexRawDataset;
                                  sample_start = nothing, sample_end = nothing,
                                  min_valid_obs::Int = 8) -> CapexEmpiricalDataset

Apply the CCC observation equations to `raw` (Issue #242) and align every
non-latent series to the common quarterly sample.

- Monthly series use `to_quarterly` with the catalog `aggregation`
  (`:SUM`/`:AVG`/`:EOP` → `:sum`/`:mean`/`:end`); annual series use
  [`capex_annual_to_quarterly`](@ref); quarterly series pass through.
- `annualized == true` series are divided by 4 mechanically — no series-ID
  branching (`Z-06`).
- `level_form == :index` series are levelled by their `anchor`; anchors that
  need an external series (`:bea_annual_real_value_added`) are left in index
  form with a recorded, deferred `anchor_detail`.
- The sample endpoints come only from the `:calibration_required` inner join
  (`Z-29`); `:estimation_input` gaps never shrink the sample; `:validation_only`
  never affects it.
- `observability ∈ (:E, :A)` keys keep a role but carry no values and are never
  imputed.
- Missing values are never zero-filled; no interpolation beyond the declared
  annual→quarterly rule is added.

`sample_start` / `sample_end` (`"YYYY-Qn"`) override the automatic window; any
difference from the automatic endpoints is recorded in `quality_flags`.
"""
function build_capex_empirical_dataset(
    raw::CapexRawDataset;
    sample_start::Union{AbstractString, Nothing} = nothing,
    sample_end::Union{AbstractString, Nothing} = nothing,
    min_valid_obs::Int = 8,
)::CapexEmpiricalDataset
    min_valid_obs >= 1 ||
        throw(ArgumentError("min_valid_obs は 1 以上でなければなりません"))

    catalog = CapexSeriesSpec[obs.spec for (_, obs) in raw.observations]
    sort!(catalog; by = spec -> String(spec.key))
    validate_capex_series_catalog(catalog)

    roles = Dict{Symbol, Symbol}(spec.key => spec.role for spec in catalog)
    observability = Dict{Symbol, Symbol}(spec.key => spec.observability for spec in catalog)

    measurements = Dict{Symbol, CapexMeasurement}()
    measurement_failures = Dict{String, String}()
    latent_keys = String[]
    per_key = Dict{String, Any}()

    for spec in catalog
        obs = raw.observations[spec.key]
        key_str = String(spec.key)
        base_flags = Dict{String, Any}(
            "role" => String(spec.role),
            "observability" => String(spec.observability),
            "raw_status" => String(obs.status),
        )
        if spec.observability in (:E, :A)
            push!(latent_keys, key_str)
            per_key[key_str] = merge(
                base_flags,
                Dict{String, Any}(
                    "state" => "latent_excluded",
                    "in_values" => false,
                    "reason" =>
                        "structurally latent (observability=$(spec.observability)); " *
                        "not imputed",
                ),
            )
            continue
        end
        if obs.status != :ok || obs.series === nothing
            per_key[key_str] = merge(
                base_flags,
                Dict{String, Any}(
                    "state" => "unavailable",
                    "in_values" => true,
                    "reason" => "no measured series (raw status=$(obs.status))",
                ),
            )
            continue
        end
        try
            measurement = _capex_measure_series(obs)
            measurements[spec.key] = measurement
            per_key[key_str] = merge(
                base_flags,
                Dict{String, Any}(
                    "state" => "measured",
                    "in_values" => true,
                    "conversion_formula" => measurement.conversion_formula,
                    "n_source_missing" => measurement.n_source_missing,
                    "n_invalid" => measurement.n_invalid,
                    "n_warnings" => length(measurement.warnings),
                    "provider_vintage" =>
                        obs.provider_vintage isa AbstractString ?
                        String(obs.provider_vintage) : "unknown",
                ),
            )
        catch err
            message = sprint(showerror, err)
            measurement_failures[key_str] = message
            per_key[key_str] = merge(
                base_flags,
                Dict{String, Any}(
                    "state" => "measurement_failed",
                    "in_values" => true,
                    "reason" => message,
                ),
            )
        end
    end

    # 有効（非欠損・有限）四半期ラベル → 値
    label_values = Dict{Symbol, Dict{String, Float64}}()
    for (key, measurement) in measurements
        valid = Dict{String, Float64}()
        seen = Set{String}()
        for (date, value) in zip(measurement.measured.dates, measurement.measured.values)
            date in seen && throw(
                ArgumentError("系列 $(key) の四半期ラベルが重複しています: '$(date)'"),
            )
            push!(seen, date)
            _capex_parse_quarter_label(date)
            (ismissing(value) || !isfinite(value)) && continue
            valid[date] = Float64(value)
        end
        label_values[key] = valid
    end

    calib_keys = sort(
        [spec.key for spec in catalog if spec.role === :calibration_required];
        by = String,
    )
    calib_unmeasured = Symbol[key for key in calib_keys if !haskey(measurements, key)]

    common_set::Union{Set{String}, Nothing} = nothing
    for key in calib_keys
        key_labels =
            haskey(label_values, key) ? Set(keys(label_values[key])) : Set{String}()
        common_set = common_set === nothing ? key_labels : intersect(common_set, key_labels)
    end
    common_set === nothing && (common_set = Set{String}())
    common = sort(collect(common_set); by = _capex_quarter_index)

    manual_window = sample_start !== nothing || sample_end !== nothing
    window_overrides = String[]
    auto_start = isempty(common) ? nothing : first(common)
    auto_end = isempty(common) ? nothing : last(common)
    if sample_start !== nothing
        low = _capex_quarter_index(sample_start)
        filter!(label -> _capex_quarter_index(label) >= low, common)
        auto_start !== nothing &&
            String(sample_start) != auto_start &&
            push!(
                window_overrides,
                "manual sample_start=$(sample_start) overrides automatic start=$(auto_start)",
            )
    end
    if sample_end !== nothing
        high = _capex_quarter_index(sample_end)
        filter!(label -> _capex_quarter_index(label) <= high, common)
        auto_end !== nothing &&
            String(sample_end) != auto_end &&
            push!(
                window_overrides,
                "manual sample_end=$(sample_end) overrides automatic end=$(auto_end)",
            )
    end

    n_obs = length(common)
    if n_obs < min_valid_obs
        calib_list = join(string.(calib_keys), ", ")
        unmeasured_detail =
            isempty(calib_unmeasured) ? "" :
            " 測定できない較正必須系列: " * join(string.(calib_unmeasured), ", ") * "。"
        throw(
            ArgumentError(
                "共通四半期軸の観測数 $(n_obs) が min_valid_obs=$(min_valid_obs) を下回りました。" *
                "較正必須系列（$(calib_list)）の inner join で揃う四半期が不足しています。" *
                unmeasured_detail,
            ),
        )
    end

    sample_start_label = first(common)
    sample_end_label = last(common)
    start_index = _capex_quarter_index(sample_start_label)
    end_index = _capex_quarter_index(sample_end_label)

    binding_series = Symbol[]
    for key in calib_keys
        indices = sort([_capex_quarter_index(label) for label in keys(label_values[key])])
        isempty(indices) && continue
        (first(indices) == start_index || last(indices) == end_index) &&
            push!(binding_series, key)
    end
    isempty(binding_series) && (binding_series = copy(calib_keys))

    all_calib_labels = Set{String}()
    for key in calib_keys
        union!(all_calib_labels, keys(label_values[key]))
    end
    common_lookup = Set(common)
    dropped_dates = sort(
        [label for label in all_calib_labels if !(label in common_lookup)];
        by = _capex_quarter_index,
    )
    interior_gap = count(
        label -> start_index <= _capex_quarter_index(label) <= end_index,
        dropped_dates,
    )
    exclusion_reasons = Dict{String, Int}(
        "partial_calibration_coverage" => interior_gap,
        "outside_sample_window" => length(dropped_dates) - interior_gap,
    )

    window = CapexSampleWindow(
        sample_start_label,
        sample_end_label,
        n_obs,
        binding_series,
        dropped_dates,
        exclusion_reasons,
    )

    observation_times = Float64[_capex_quarter_time(label) for label in common]

    value_map = Dict{Symbol, Vector{Union{Float64, Missing}}}()
    for spec in catalog
        spec.observability in (:E, :A) && continue
        key = spec.key
        if haskey(measurements, key)
            valid = label_values[key]
            value_map[key] = Union{Float64, Missing}[
                haskey(valid, label) ? valid[label] : missing for label in common
            ]
        else
            value_map[key] = Union{Float64, Missing}[missing for _ in common]
        end
    end

    for spec in catalog
        haskey(value_map, spec.key) || continue
        flags = per_key[String(spec.key)]
        flags["n_in_sample_missing"] = count(ismissing, value_map[spec.key])
    end

    raw_status_counts = Dict{String, Any}(
        String(status) =>
            count(o -> o.status == status, (obs for (_, obs) in raw.observations)) for
        status in CAPEX_CC_RAW_STATUSES
    )

    anchor_deferred = sort([
        String(key) for
        (key, measurement) in measurements if measurement.anchor_detail !== nothing &&
            occursin("deferred", measurement.anchor_detail)
    ])

    quality_flags = Dict{String, Any}(
        "n_obs" => n_obs,
        "n_series" => length(catalog),
        "n_measured" => length(measurements),
        "n_calibration_required" => length(calib_keys),
        "n_latent_excluded" => length(latent_keys),
        "latent_keys" => sort(latent_keys),
        "calibration_unmeasured" => sort(String.(calib_unmeasured)),
        "measurement_failures" => measurement_failures,
        "raw_status_counts" => raw_status_counts,
        "index_anchor_deferred" => anchor_deferred,
        "window_overrides" => window_overrides,
        "min_valid_obs" => min_valid_obs,
        "per_key" => per_key,
    )

    dataset_hash =
        _capex_dataset_hash(raw, catalog, measurements, common, value_map, window)

    measured_vintages = unique([
        get(per_key[String(key)], "provider_vintage", "unknown") for
        key in keys(measurements)
    ])
    data_vintage =
        length(measured_vintages) == 1 && first(measured_vintages) != "unknown" ?
        String(first(measured_vintages)) : "unknown"

    vintage_mode = first(_CAPEX_CC_VINTAGE_MODES)
    metadata = Dict{String, Any}(
        "integration_version" => CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "catalog_version" => raw.catalog_version,
        "vintage_mode" => String(vintage_mode),
        "data_vintage" => data_vintage,
        "dataset_hash" => dataset_hash,
        "sample_start" => sample_start_label,
        "sample_end" => sample_end_label,
        "binding_series" => sort(String.(binding_series)),
        "manual_sample_window" => manual_window,
    )

    return CapexEmpiricalDataset(
        catalog,
        measurements,
        common,
        observation_times,
        value_map,
        roles,
        observability,
        window,
        vintage_mode,
        quality_flags,
        raw,
        metadata,
    )
end
