# CCC raw-observation adapter (Issue #242 / P-2).
#
# The adapter deliberately stops at provider-normalised observations.  Unit
# conversion, quarterly aggregation, measurement equations, and model calls
# belong to later empirical layers.

const CAPEX_CC_RAW_STATUSES =
    (:ok, :missing_series, :provider_error, :invalid_response, :unavailable_upstream)

"""
    CapexRawObservation

One CCC catalog entry together with its provider-normalised raw observation.
`provider_*` fields report only what EDP declared; they are never filled from
the catalog's `declared_*` fields.  A non-`:ok` observation has `series ===
nothing`, so failure cannot be mistaken for an empty or zero-valued series.
"""
struct CapexRawObservation
    key::Symbol
    spec::CapexSeriesSpec
    status::Symbol
    series::Union{DataSeries, Nothing}
    provider_unit::Union{String, Missing}
    provider_frequency::Union{DataFrequency, Missing}
    provider_seasonal_adjustment::Union{String, Missing}
    provider_vintage::Union{String, Missing}
    metadata_mismatches::Vector{String}
    retrieved_at::Union{String, Nothing}
    mode::Symbol
    detail::String
end

"""
    CapexRawDataset

Raw observations selected from the versioned CCC catalog.  `provider_base`
contains only scheme and host (never a path, query, or credentials).  The
deterministic `raw_identity` stored in `metadata` excludes `retrieved_at`,
transport mode, and provider location.
"""
struct CapexRawDataset
    observations::Dict{Symbol, CapexRawObservation}
    catalog_version::String
    integration_version::String
    provider_base::String
    quality_flags::Dict{String, Any}
    metadata::Dict{String, Any}
end

struct _CapexProviderDecodeError <: Exception
    detail::String
end

Base.showerror(io::IO, e::_CapexProviderDecodeError) =
    print(io, "invalid EDP response: ", e.detail)

struct _CapexProviderEmptySeries <: Exception
    detail::String
end

Base.showerror(io::IO, e::_CapexProviderEmptySeries) = print(io, e.detail)

_capex_missing_to_nothing(x) = ismissing(x) ? nothing : x

function _capex_provider_optional_string(object, field::String)::Union{String, Missing}
    haskey(object, field) || return missing
    value = object[field]
    value === nothing && return missing
    value isa AbstractString ||
        throw(_CapexProviderDecodeError("$field must be a string when supplied"))
    return String(value)
end

function _capex_provider_optional_value(object, field::String)
    haskey(object, field) || return missing
    value = object[field]
    return value === nothing ? missing : value
end

function _capex_provider_required_string(object, field::String)::String
    value = _capex_provider_optional_string(object, field)
    (ismissing(value) || isempty(strip(value))) &&
        throw(_CapexProviderDecodeError("required field $field is missing or empty"))
    return value
end

function _capex_provider_frequency(value::String)::DataFrequency
    normalized = lowercase(strip(value))
    normalized == "annual" && return Annual
    normalized == "quarterly" && return Quarterly
    normalized == "monthly" && return Monthly
    throw(_CapexProviderDecodeError("unsupported provider frequency: $value"))
end

function _capex_provider_unknown_unit(unit::String)::Bool
    return lowercase(strip(unit)) in ("", "unknown", "n/a", "na", "not available")
end

function _capex_catalog_entries(
    json::String,
)::Tuple{Dict{String, Any}, Union{String, Missing}}
    data = try
        JSON3.read(json)
    catch
        throw(_CapexProviderDecodeError("catalog is not valid JSON"))
    end
    haskey(data, "items") || throw(_CapexProviderDecodeError("catalog is missing items"))
    items = data["items"]
    items isa AbstractVector ||
        throw(_CapexProviderDecodeError("catalog items must be an array"))

    entries = Dict{String, Any}()
    for item in items
        item isa AbstractDict ||
            throw(_CapexProviderDecodeError("catalog item must be an object"))
        series_id = _capex_provider_required_string(item, "series_id")
        haskey(entries, series_id) && throw(
            _CapexProviderDecodeError("catalog contains duplicate series_id: $series_id"),
        )
        entries[series_id] = item
    end

    version = missing
    if haskey(data, "snapshot") && data["snapshot"] !== nothing
        snapshot = data["snapshot"]
        snapshot isa AbstractDict ||
            throw(_CapexProviderDecodeError("catalog snapshot must be an object"))
        version = _capex_provider_optional_string(snapshot, "version")
        if ismissing(version)
            version = _capex_provider_optional_string(snapshot, "contract_version")
        end
    end
    return entries, version
end

function _capex_catalog_metadata(entry, field::String)
    entry === nothing && return missing
    return _capex_provider_optional_string(entry, field)
end

function _capex_provider_metadata_value(data, entry, field::String)
    value = _capex_provider_optional_string(data, field)
    return ismissing(value) ? _capex_catalog_metadata(entry, field) : value
end

function _capex_provider_json_text(value)::Union{String, Missing}
    ismissing(value) && return missing
    return JSON3.write(value)
end

function _capex_provider_metadata_mismatches(
    spec::CapexSeriesSpec,
    unit::String,
    frequency::DataFrequency,
    seasonal_adjustment::Union{String, Missing},
    real_nominal::Union{String, Missing},
    base_year,
)::Vector{String}
    mismatches = String[]
    unit == spec.declared_unit ||
        push!(mismatches, "unit: declared=$(spec.declared_unit), provider=$unit")
    frequency == spec.declared_frequency || push!(
        mismatches,
        "frequency: declared=$(spec.declared_frequency), provider=$frequency",
    )
    if !ismissing(seasonal_adjustment) &&
       seasonal_adjustment != spec.declared_seasonal_adjustment
        push!(
            mismatches,
            "seasonal_adjustment: declared=$(spec.declared_seasonal_adjustment), provider=$seasonal_adjustment",
        )
    end
    if !ismissing(real_nominal) &&
       lowercase(real_nominal) != String(spec.declared_real_nominal)
        push!(
            mismatches,
            "real_nominal: declared=$(spec.declared_real_nominal), provider=$real_nominal",
        )
    end
    if spec.declared_base_year !== nothing && !ismissing(base_year)
        provider_base_year = try
            Int(base_year)
        catch
            throw(_CapexProviderDecodeError("base_year must be an integer when supplied"))
        end
        provider_base_year == spec.declared_base_year || push!(
            mismatches,
            "base_year: declared=$(spec.declared_base_year), provider=$provider_base_year",
        )
    end
    return mismatches
end

function _decode_capex_provider_series(
    json::String,
    spec::CapexSeriesSpec,
    catalog_entry,
)::NamedTuple
    data = try
        JSON3.read(json)
    catch
        throw(_CapexProviderDecodeError("series response is not valid JSON"))
    end

    id = _capex_provider_required_string(data, "id")
    id == spec.provider_series_id || throw(
        _CapexProviderDecodeError(
            "series id does not match catalog: expected $(spec.provider_series_id), got $id",
        ),
    )
    name = _capex_provider_required_string(data, "name")
    unit = _capex_provider_required_string(data, "unit")
    _capex_provider_unknown_unit(unit) &&
        throw(_CapexProviderDecodeError("provider unit is unknown"))
    frequency =
        _capex_provider_frequency(_capex_provider_required_string(data, "frequency"))
    haskey(data, "points") ||
        throw(_CapexProviderDecodeError("required field points is missing"))
    points = data["points"]
    points isa AbstractVector || throw(_CapexProviderDecodeError("points must be an array"))
    isempty(points) && throw(_CapexProviderEmptySeries("provider returned an empty series"))

    dates = String[]
    values = Union{Float64, Missing}[]
    seen_dates = Set{String}()
    for point in points
        point isa AbstractDict ||
            throw(_CapexProviderDecodeError("point must be an object"))
        label = _capex_provider_required_string(point, "label")
        label in seen_dates &&
            throw(_CapexProviderDecodeError("points contain duplicate label: $label"))
        push!(seen_dates, label)
        push!(dates, label)
        haskey(point, "value") ||
            throw(_CapexProviderDecodeError("point $label is missing value"))
        value = point["value"]
        if value === nothing
            push!(values, missing)
        elseif value isa Number && isfinite(Float64(value))
            push!(values, Float64(value))
        else
            throw(
                _CapexProviderDecodeError(
                    "point $label has a non-finite or non-numeric value",
                ),
            )
        end
    end
    all(ismissing, values) &&
        throw(_CapexProviderEmptySeries("provider returned no usable observations"))

    seasonal_adjustment =
        _capex_provider_metadata_value(data, catalog_entry, "seasonal_adjustment")
    real_nominal = _capex_provider_metadata_value(data, catalog_entry, "real_nominal")
    base_year = _capex_provider_optional_value(data, "base_year")
    if ismissing(base_year) && catalog_entry !== nothing
        base_year = _capex_provider_optional_value(catalog_entry, "base_year")
    end
    vintage = _capex_provider_metadata_value(data, catalog_entry, "vintage")
    vintage_capability = _capex_provider_optional_value(data, "vintage_capability")
    if ismissing(vintage_capability) && catalog_entry !== nothing
        vintage_capability =
            _capex_provider_optional_value(catalog_entry, "vintage_capability")
    end
    revision_capability = _capex_provider_optional_value(data, "revision_capability")
    source_agency = _capex_provider_metadata_value(data, catalog_entry, "source")
    provider_name = _capex_provider_metadata_value(data, catalog_entry, "provider")
    snapshot_version = _capex_catalog_metadata(catalog_entry, "snapshot_version")

    metadata = Dict{String, Any}(
        "provider_series_id" => id,
        "provider_source_id" => _capex_provider_optional_string(data, "source_id"),
        "source_agency" => source_agency,
        "source_name" => name,
        "provider_name" => provider_name,
        "provider_seasonal_adjustment" => seasonal_adjustment,
        "provider_real_nominal" => real_nominal,
        "provider_base_year" => base_year,
        "provider_vintage" => vintage,
        "provider_vintage_capability" => _capex_provider_json_text(vintage_capability),
        "provider_revision_capability" =>
            _capex_provider_json_text(revision_capability),
        "provider_snapshot_version" => snapshot_version,
    )
    source = ismissing(source_agency) ? spec.provider : source_agency
    series = DataSeries(
        id = id,
        name = name,
        source = source,
        frequency = frequency,
        unit = unit,
        dates = dates,
        values = values,
        metadata = metadata,
    )
    return (
        series = series,
        unit = unit,
        frequency = frequency,
        seasonal_adjustment = seasonal_adjustment,
        vintage = vintage,
        mismatches = _capex_provider_metadata_mismatches(
            spec,
            unit,
            frequency,
            seasonal_adjustment,
            real_nominal,
            base_year,
        ),
    )
end

function _capex_safe_provider_base(url::String)::String
    match_result = match(r"^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)", strip(url))
    match_result === nothing && return ""
    # Split after matching so an optional userinfo part cannot escape into the
    # persisted base.  Path and query were excluded by the regex above.
    host = last(split(match_result.captures[2], '@'))
    return "$(match_result.captures[1])://$host"
end

function _capex_retrieved_at(client::DataProviderClient)::Union{String, Nothing}
    client.mode == :fixture && return nothing
    return Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ")
end

function _capex_failed_observation(
    spec::CapexSeriesSpec,
    status::Symbol,
    client::DataProviderClient,
    detail::String;
    retrieved_at::Union{String, Nothing} = _capex_retrieved_at(client),
)::CapexRawObservation
    status in CAPEX_CC_RAW_STATUSES || throw(ArgumentError("未知の raw status: $status"))
    return CapexRawObservation(
        spec.key,
        spec,
        status,
        nothing,
        missing,
        missing,
        missing,
        missing,
        String[],
        retrieved_at,
        client.mode,
        detail,
    )
end

function _capex_gap_detail(spec::CapexSeriesSpec)::Union{String, Nothing}
    gaps = [gap.detail for gap in CAPEX_CC_PROVIDER_GAPS if gap.key == spec.key]
    return isempty(gaps) ? nothing : join(sort(gaps), " | ")
end

function _capex_exception_status(error)::Symbol
    error isa _CapexProviderDecodeError && return :invalid_response
    error isa _CapexProviderEmptySeries && return :missing_series
    error isa _DataProviderFixtureMissingError && return :missing_series
    error isa _DataProviderHTTPError &&
        return error.status == 404 ? :missing_series : :provider_error
    return :provider_error
end

function _capex_exception_detail(error)::String
    error isa _CapexProviderDecodeError && return error.detail
    error isa _CapexProviderEmptySeries && return error.detail
    error isa _DataProviderFixtureMissingError &&
        return "provider response fixture is missing"
    error isa _DataProviderHTTPError && return "provider returned HTTP $(error.status)"
    # Do not record a network exception verbatim: it may include a credentialed
    # request URL.  The status retains the actionable distinction safely.
    return "provider request failed"
end

function _capex_selected_catalog(
    catalog::AbstractVector{<:CapexSeriesSpec},
    keys,
)::Vector{CapexSeriesSpec}
    validate_capex_series_catalog(catalog)
    keys === nothing && return sort(collect(catalog); by = spec -> String(spec.key))

    requested = Symbol.(collect(keys))
    length(unique(requested)) == length(requested) ||
        throw(ArgumentError("keys に重複があります"))
    by_key = Dict(spec.key => spec for spec in catalog)
    unknown = [key for key in requested if !haskey(by_key, key)]
    isempty(unknown) ||
        throw(ArgumentError("catalog に存在しない keys: $(join(string.(unknown), ", "))"))
    return sort([by_key[key] for key in requested]; by = spec -> String(spec.key))
end

function _capex_raw_identity(observations::Dict{Symbol, CapexRawObservation})::String
    ordered =
        sort(collect(values(observations)); by = observation -> String(observation.key))
    payload = Dict{String, Any}(
        "catalog_version" => CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "integration_version" => CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "observations" => [
            Dict{String, Any}(
                "key" => String(observation.key),
                "provider_series_id" => observation.spec.provider_series_id,
                "status" => String(observation.status),
                "provider_unit" => _capex_missing_to_nothing(observation.provider_unit),
                "provider_frequency" =>
                    ismissing(observation.provider_frequency) ? nothing :
                    string(observation.provider_frequency),
                "provider_seasonal_adjustment" => _capex_missing_to_nothing(
                    observation.provider_seasonal_adjustment,
                ),
                "provider_vintage" =>
                    _capex_missing_to_nothing(observation.provider_vintage),
                "metadata_mismatches" => sort(observation.metadata_mismatches),
                "series" =>
                    observation.series === nothing ? nothing :
                    Dict{String, Any}(
                        "id" => observation.series.id,
                        "name" => observation.series.name,
                        "source" => observation.series.source,
                        "frequency" => string(observation.series.frequency),
                        "unit" => observation.series.unit,
                        "dates" => observation.series.dates,
                        "values" => [
                            ismissing(value) ? nothing : value for
                            value in observation.series.values
                        ],
                    ),
            ) for observation in ordered
        ],
    )
    return "sha256:" * sha256_hex_of_canonical(payload)
end

"""
    build_capex_raw_dataset(; catalog = CAPEX_CC_SERIES_CATALOG,
                              client = DataProviderClient(), keys = nothing)
        -> CapexRawDataset

Fetch the requested CCC catalog entries through EDP and preserve their raw
observations plus provider metadata.  The DME catalog determines which series
to request; an EDP catalog response can only confirm or reject availability.
Known cross-repository provider gaps become `:unavailable_upstream`, while
empty data, an absent series, an HTTP failure, and malformed JSON retain
distinct statuses.  The function does not perform measurement conversion or
invoke the CCC model.
"""
function build_capex_raw_dataset(;
    catalog::AbstractVector{<:CapexSeriesSpec} = CAPEX_CC_SERIES_CATALOG,
    client::DataProviderClient = DataProviderClient(),
    keys = nothing,
)::CapexRawDataset
    selected = _capex_selected_catalog(catalog, keys)
    observations = Dict{Symbol, CapexRawObservation}()
    fetchable = [spec for spec in selected if _capex_gap_detail(spec) === nothing]
    catalog_entries = Dict{String, Any}()
    catalog_version = missing
    catalog_error = nothing

    if !isempty(fetchable)
        try
            catalog_entries, catalog_version =
                _capex_catalog_entries(fetch_provider_catalog(; client = client))
        catch error
            catalog_error = error
        end
    end

    for spec in selected
        gap_detail = _capex_gap_detail(spec)
        if gap_detail !== nothing
            observations[spec.key] =
                _capex_failed_observation(spec, :unavailable_upstream, client, gap_detail)
            continue
        end
        if catalog_error !== nothing
            observations[spec.key] = _capex_failed_observation(
                spec,
                _capex_exception_status(catalog_error),
                client,
                "provider catalog: $(_capex_exception_detail(catalog_error))",
            )
            continue
        end
        if !haskey(catalog_entries, spec.provider_series_id)
            observations[spec.key] = _capex_failed_observation(
                spec,
                :missing_series,
                client,
                "provider catalog does not list $(spec.provider_series_id)",
            )
            continue
        end
        retrieved_at = _capex_retrieved_at(client)
        try
            decoded = _decode_capex_provider_series(
                fetch_provider_series(spec.provider_series_id; client = client),
                spec,
                catalog_entries[spec.provider_series_id],
            )
            observations[spec.key] = CapexRawObservation(
                spec.key,
                spec,
                :ok,
                decoded.series,
                decoded.unit,
                decoded.frequency,
                decoded.seasonal_adjustment,
                decoded.vintage,
                decoded.mismatches,
                retrieved_at,
                client.mode,
                "",
            )
        catch error
            observations[spec.key] = _capex_failed_observation(
                spec,
                _capex_exception_status(error),
                client,
                _capex_exception_detail(error);
                retrieved_at = retrieved_at,
            )
        end
    end

    status_counts = Dict{String, Any}(
        String(status) =>
            count(observation -> observation.status == status, values(observations)) for
        status in CAPEX_CC_RAW_STATUSES
    )
    quality_flags = Dict{String, Any}(
        "status_counts" => status_counts,
        "catalog_checked" => catalog_error === nothing,
    )
    metadata = Dict{String, Any}(
        "provider_catalog_version" => _capex_missing_to_nothing(catalog_version),
        "selected_keys" => sort(String.(getfield.(selected, :key))),
        "raw_identity" => _capex_raw_identity(observations),
    )
    return CapexRawDataset(
        observations,
        CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        _capex_safe_provider_base(client.base_url),
        quality_flags,
        metadata,
    )
end
