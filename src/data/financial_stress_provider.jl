# financial_stress_provider.jl: 金融ストレス観測の raw fetch（Issue #260 Part B）。
#
# `FINANCIAL_STRESS_SERIES_CATALOG` の各系列を、既存の `DataProviderClient`
# （src/data/data_provider.jl、EDP汎用REST client）経由で取得する。CCC の
# `build_capex_raw_dataset`（capex_credit_cycle_provider.jl）と同じ責務境界
# （raw観測で止め、単位変換・整列・派生指標の計算を行わない）だが、CCC固有の
# catalog_entry 突合（`metadata_mismatches`）は行わない。8系列はいずれも
# EDP側で`role`宣言済み（financial-stress 5種）または汎用FRED passthrough
# （長期金利3種）であり、DME側で宣言値との突合対象となる `declared_*` を
# catalogが持たないため。
#
# 本ファイルは CCC の内部ヘルパ（`_capex_*`、capex_credit_cycle_provider.jl）を
# 再利用しない。CCC の較正catalogから独立した診断層であるという責務分離
# （financial_stress_catalog.jl 冒頭コメント）をヘルパ関数の依存関係でも保つ
# （data_provider.jl の公開/汎用境界のみを共有する）。
#
# 欠測日・provider失敗・空系列を 0 や直近値へ暗黙変換しない（Issue #260 対象外事項）。
# `:ok` 以外の観測は `series === nothing` とし、失敗を空データと混同しない。

"""
    FINANCIAL_STRESS_RAW_STATUSES

`FinancialStressRawObservation.status` の確定集合（Issue #260 Part B）。
"""
const FINANCIAL_STRESS_RAW_STATUSES =
    (:ok, :missing_series, :provider_error, :invalid_response)

"""Internal decode error, mirroring the shape of similar errors elsewhere in `src/data/`
but kept private to this file (no dependency on CCC's `_CapexProviderDecodeError`)."""
struct _FSProviderDecodeError <: Exception
    detail::String
end
Base.showerror(io::IO, e::_FSProviderDecodeError) =
    print(io, "invalid EDP response: ", e.detail)

"""Internal error for a provider response whose series carries no usable observation."""
struct _FSProviderEmptySeries <: Exception
    detail::String
end
Base.showerror(io::IO, e::_FSProviderEmptySeries) = print(io, e.detail)

function _fs_required_string(object, field::String)::String
    haskey(object, field) ||
        throw(_FSProviderDecodeError("required field $field is missing"))
    value = object[field]
    (value === nothing || !(value isa AbstractString) || isempty(strip(value))) &&
        throw(_FSProviderDecodeError("required field $field is missing or empty"))
    return String(value)
end

"""
    FinancialStressSeries

金融ストレス観測1系列の raw daily history（Issue #260 Part B）。`DataSeries`
（src/data/data_series.jl）を流用しない。`DataFrequency` が `Daily` を持たず、
日次を月次・四半期へ暗黙に丸めないという契約と整合しないため（本ファイル冒頭コメント）。

## フィールド
- `key::Symbol`: catalog の `key`。
- `provider_series_id::String`
- `name::String`: EDPが返した系列名。
- `unit::String`: EDPが返した単位。
- `dates::Vector{String}`: 昇順・重複無しの `"YYYY-MM-DD"` ラベル。
- `values::Vector{Union{Float64,Missing}}`: 欠測日は `missing`（0や直近値へ変換しない）。
- `metadata::Dict{String,Any}`
"""
struct FinancialStressSeries
    key::Symbol
    provider_series_id::String
    name::String
    unit::String
    dates::Vector{String}
    values::Vector{Union{Float64, Missing}}
    metadata::Dict{String, Any}

    function FinancialStressSeries(;
        key::Symbol,
        provider_series_id::AbstractString,
        name::AbstractString,
        unit::AbstractString,
        dates::Vector{String},
        values::AbstractVector,
        metadata::Dict{String, Any} = Dict{String, Any}(),
    )
        length(dates) == length(values) || throw(
            ArgumentError(
                "dates と values の長さが一致しません: $(length(dates)) != $(length(values))",
            ),
        )
        (length(unique(dates)) == length(dates) && issorted(dates)) ||
            throw(ArgumentError("dates は昇順・重複無しでなければなりません: $key"))
        return new(
            key,
            String(provider_series_id),
            String(name),
            String(unit),
            dates,
            collect(Union{Float64, Missing}, values),
            metadata,
        )
    end
end

Base.length(s::FinancialStressSeries) = length(s.dates)

"""
    value_on_date(s::FinancialStressSeries, date::AbstractString) -> Union{Float64,Missing}

`date`（`"YYYY-MM-DD"`）ちょうどの観測値を返す。`date` が系列に存在しない、または
存在するが欠測（`missing`）のときは `missing` を返す。前後の値への forward-fill・
補間は行わない（Issue #260 対象外事項）。
"""
function value_on_date(
    s::FinancialStressSeries,
    date::AbstractString,
)::Union{Float64, Missing}
    idx = findfirst(==(date), s.dates)
    idx === nothing && return missing
    return s.values[idx]
end

"""
    FinancialStressRawObservation

`FinancialStressSeriesSpec` 1行に対する raw観測（Issue #260 Part B）。`:ok` 以外は
`series === nothing`。
"""
struct FinancialStressRawObservation
    key::Symbol
    spec::FinancialStressSeriesSpec
    status::Symbol
    series::Union{FinancialStressSeries, Nothing}
    retrieved_at::Union{String, Nothing}
    mode::Symbol
    detail::String

    function FinancialStressRawObservation(;
        key::Symbol,
        spec::FinancialStressSeriesSpec,
        status::Symbol,
        series::Union{FinancialStressSeries, Nothing},
        retrieved_at::Union{String, Nothing},
        mode::Symbol,
        detail::AbstractString = "",
    )
        status in FINANCIAL_STRESS_RAW_STATUSES ||
            throw(ArgumentError("未知の raw status: $status"))
        status == :ok &&
            series === nothing &&
            throw(ArgumentError("status=:ok は series を伴わなければなりません: $key"))
        status != :ok &&
            series !== nothing &&
            throw(
                ArgumentError(
                    "status=$status は series === nothing でなければなりません: $key",
                ),
            )
        return new(key, spec, status, series, retrieved_at, mode, String(detail))
    end
end

"""
    FinancialStressRawDataset

`FINANCIAL_STRESS_SERIES_CATALOG` から選択した系列の raw観測集合（Issue #260 Part B）。
`key` から観測を引くには `dataset.observations[key]` を使う（`CapexRawDataset` と同じ
直接フィールドアクセスの慣習。ラッパ関数は追加しない）。
"""
struct FinancialStressRawDataset
    observations::Dict{Symbol, FinancialStressRawObservation}
    catalog_version::String
    provider_base::String
    metadata::Dict{String, Any}
end

_fs_frequency_ok(value::AbstractString)::Bool = lowercase(strip(value)) == "daily"

function _decode_financial_stress_series(json::String, spec::FinancialStressSeriesSpec)
    data = try
        JSON3.read(json)
    catch
        throw(_FSProviderDecodeError("series response is not valid JSON"))
    end

    id = _fs_required_string(data, "id")
    id == spec.provider_series_id || throw(
        _FSProviderDecodeError(
            "series id does not match catalog: expected $(spec.provider_series_id), got $id",
        ),
    )
    name = _fs_required_string(data, "name")
    unit = _fs_required_string(data, "unit")
    frequency = _fs_required_string(data, "frequency")
    _fs_frequency_ok(frequency) || throw(
        _FSProviderDecodeError(
            "expected a daily series (financial stress catalog is daily-only), got: $frequency",
        ),
    )
    haskey(data, "points") ||
        throw(_FSProviderDecodeError("required field points is missing"))
    points = data["points"]
    points isa AbstractVector || throw(_FSProviderDecodeError("points must be an array"))
    isempty(points) && throw(_FSProviderEmptySeries("provider returned an empty series"))

    dates = String[]
    values = Union{Float64, Missing}[]
    seen_dates = Set{String}()
    for point in points
        point isa AbstractDict || throw(_FSProviderDecodeError("point must be an object"))
        label = _fs_required_string(point, "label")
        label in seen_dates &&
            throw(_FSProviderDecodeError("points contain duplicate label: $label"))
        push!(seen_dates, label)
        push!(dates, label)
        haskey(point, "value") ||
            throw(_FSProviderDecodeError("point $label is missing value"))
        value = point["value"]
        if value === nothing
            push!(values, missing)
        elseif value isa Number && isfinite(Float64(value))
            push!(values, Float64(value))
        else
            throw(
                _FSProviderDecodeError(
                    "point $label has a non-finite or non-numeric value",
                ),
            )
        end
    end
    all(ismissing, values) &&
        throw(_FSProviderEmptySeries("provider returned no usable observations"))
    issorted(dates) ||
        throw(_FSProviderDecodeError("points must be sorted ascending by label"))

    return FinancialStressSeries(;
        key = spec.key,
        provider_series_id = id,
        name = name,
        unit = unit,
        dates = dates,
        values = values,
        metadata = Dict{String, Any}("provider_frequency" => frequency),
    )
end

function _fs_retrieved_at(client::DataProviderClient)::Union{String, Nothing}
    client.mode == :fixture && return nothing
    return Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ")
end

function _fs_exception_status(error)::Symbol
    error isa _FSProviderDecodeError && return :invalid_response
    error isa _FSProviderEmptySeries && return :missing_series
    error isa _DataProviderFixtureMissingError && return :missing_series
    error isa _DataProviderHTTPError &&
        return error.status == 404 ? :missing_series : :provider_error
    return :provider_error
end

function _fs_exception_detail(error)::String
    error isa _FSProviderDecodeError && return error.detail
    error isa _FSProviderEmptySeries && return error.detail
    error isa _DataProviderFixtureMissingError &&
        return "provider response fixture is missing"
    error isa _DataProviderHTTPError && return "provider returned HTTP $(error.status)"
    # Network exceptions may embed a credentialed request URL; keep only the
    # actionable status distinction, matching the same choice made for CCC.
    return "provider request failed"
end

function _fs_safe_provider_base(url::String)::String
    match_result = match(r"^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)", strip(url))
    match_result === nothing && return ""
    host = last(split(match_result.captures[2], '@'))
    return "$(match_result.captures[1])://$host"
end

function _fs_failed_observation(
    spec::FinancialStressSeriesSpec,
    status::Symbol,
    client::DataProviderClient,
    detail::AbstractString,
)::FinancialStressRawObservation
    return FinancialStressRawObservation(;
        key = spec.key,
        spec = spec,
        status = status,
        series = nothing,
        retrieved_at = _fs_retrieved_at(client),
        mode = client.mode,
        detail = detail,
    )
end

function _fs_raw_identity(observations::Dict{Symbol, FinancialStressRawObservation})::String
    ordered = sort(collect(values(observations)); by = o -> String(o.key))
    payload = Dict{String, Any}(
        "catalog_version" => FINANCIAL_STRESS_CATALOG_VERSION,
        "observations" => [
            Dict{String, Any}(
                "key" => String(o.key),
                "provider_series_id" => o.spec.provider_series_id,
                "status" => String(o.status),
                "series" =>
                    o.series === nothing ? nothing :
                    Dict{String, Any}(
                        "id" => o.series.provider_series_id,
                        "name" => o.series.name,
                        "unit" => o.series.unit,
                        "dates" => o.series.dates,
                        "values" =>
                            [ismissing(v) ? nothing : v for v in o.series.values],
                    ),
            ) for o in ordered
        ],
    )
    return "sha256:" * sha256_hex_of_canonical(payload)
end

"""
    build_financial_stress_raw_dataset(; catalog = FINANCIAL_STRESS_SERIES_CATALOG,
                                          client = DataProviderClient(), keys = nothing)
        -> FinancialStressRawDataset

`catalog`（既定 `FINANCIAL_STRESS_SERIES_CATALOG`）の各系列をEDP経由で取得する
（Issue #260 Part B）。`keys` を渡すと部分集合のみ取得する。EDPの `/v1/catalog/series`
突合は行わない（本ファイル冒頭コメント）。fixtureが無い・HTTP失敗・空系列・
frequency不一致はそれぞれ別のstatusとして記録し、0や直近値へ変換しない。
"""
function build_financial_stress_raw_dataset(;
    catalog::AbstractVector{<:FinancialStressSeriesSpec} = FINANCIAL_STRESS_SERIES_CATALOG,
    client::DataProviderClient = DataProviderClient(),
    keys = nothing,
)::FinancialStressRawDataset
    selected = if keys === nothing
        collect(catalog)
    else
        requested = Symbol.(collect(keys))
        length(unique(requested)) == length(requested) ||
            throw(ArgumentError("keys に重複があります"))
        by_key = Dict(spec.key => spec for spec in catalog)
        unknown = [key for key in requested if !haskey(by_key, key)]
        isempty(unknown) || throw(
            ArgumentError("catalog に存在しない keys: $(join(string.(unknown), ", "))"),
        )
        [by_key[key] for key in requested]
    end

    observations = Dict{Symbol, FinancialStressRawObservation}()
    for spec in selected
        try
            json = fetch_provider_series(spec.provider_series_id; client = client)
            series = _decode_financial_stress_series(json, spec)
            observations[spec.key] = FinancialStressRawObservation(;
                key = spec.key,
                spec = spec,
                status = :ok,
                series = series,
                retrieved_at = _fs_retrieved_at(client),
                mode = client.mode,
            )
        catch error
            status = _fs_exception_status(error)
            detail = _fs_exception_detail(error)
            observations[spec.key] = _fs_failed_observation(spec, status, client, detail)
        end
    end

    status_counts = Dict{String, Any}(
        String(status) => count(o -> o.status == status, values(observations)) for
        status in FINANCIAL_STRESS_RAW_STATUSES
    )
    metadata = Dict{String, Any}(
        "selected_keys" => sort(String.(getfield.(selected, :key))),
        "status_counts" => status_counts,
        "raw_identity" => _fs_raw_identity(observations),
    )
    return FinancialStressRawDataset(
        observations,
        FINANCIAL_STRESS_CATALOG_VERSION,
        _fs_safe_provider_base(client.base_url),
        metadata,
    )
end
