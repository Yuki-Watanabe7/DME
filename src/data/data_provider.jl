# economic-data-provider (EDP) REST client.
#
# This is intentionally separate from FredClient and EStatClient.  It accepts
# the provider series ID supplied by a caller (for CCC, CapexSeriesSpec) and
# never adds a source-specific prefix or falls back to a source's public API.

const _DEFAULT_DATA_PROVIDER_FIXTURE_DIR =
    joinpath(@__DIR__, "..", "..", "test", "fixtures", "data", "capex_credit_cycle")
const _DATA_PROVIDER_MODES = (:fixture, :live, :rest_api)

"""
    DataProviderClient

Read-only client for the `economic-data-provider` REST boundary.  `:live` and
`:rest_api` both call the configured EDP server; neither mode calls a source
provider directly.  `:fixture` reads the exact JSON response shape from local
files so that fixture and EDP responses can use the same decoder.

`base_url` is read from `DATA_PROVIDER_BASE_URL`.  It deliberately has no
CCC-specific localhost default: a live request without that setting is a
configuration error instead of an implicit connection to a different server.
"""
struct DataProviderClient
    mode::Symbol
    base_url::String
    fixture_dir::String
    timeout_seconds::Float64
    requester::Function
end

"""
    DataProviderClient(; mode, base_url, fixture_dir, timeout_seconds, requester)

Construct a generic EDP client.  The `requester` keyword is an injection point
for deterministic tests; it receives `(url, timeout_seconds)` and returns the
response body as a string.  It is not persisted in any dataset artifact.
"""
function DataProviderClient(;
    mode::Union{Symbol, Nothing} = nothing,
    base_url::Union{String, Nothing} = nothing,
    fixture_dir::String = _DEFAULT_DATA_PROVIDER_FIXTURE_DIR,
    timeout_seconds::Real = 15.0,
    requester::Function = _data_provider_http_get,
)
    resolved_mode = if mode !== nothing
        mode
    elseif get(ENV, "DME_DATA_MODE", "") != ""
        Symbol(ENV["DME_DATA_MODE"])
    else
        :fixture
    end
    resolved_mode in _DATA_PROVIDER_MODES || throw(
        ArgumentError(
            "DataProviderClient.mode は $(_DATA_PROVIDER_MODES) のいずれかでなければなりません: $resolved_mode",
        ),
    )
    timeout_seconds > 0 ||
        throw(ArgumentError("timeout_seconds は 0 より大きくなければなりません"))

    # Do not reuse the FRED/e-Stat localhost fallback here.  This client is the
    # EDP boundary used by the CCC empirical layer, whose deployment must be
    # chosen explicitly through the existing shared environment setting.
    resolved_base_url =
        base_url === nothing ? get(ENV, "DATA_PROVIDER_BASE_URL", "") : base_url
    return DataProviderClient(
        resolved_mode,
        String(resolved_base_url),
        fixture_dir,
        Float64(timeout_seconds),
        requester,
    )
end

"""
Internal error that records an HTTP status without retaining a request URL.

`error_code` / `reason_code` keep EDP's structured `detail.code` / `detail.reason_code`
(for example `distribution_stopped` / `redistribution_rights` on HTTP 410, EDP ADR 060 /
ADR 072) so that callers can tell an intentional stop of distribution apart from missing
data or an outage.  Only these two machine-readable tokens are kept; the free-text
`detail.message` is not retained.
"""
struct _DataProviderHTTPError <: Exception
    status::Int
    detail::String
    error_code::Union{String, Nothing}
    reason_code::Union{String, Nothing}
end

_DataProviderHTTPError(status::Integer, detail::AbstractString) =
    _DataProviderHTTPError(Int(status), String(detail), nothing, nothing)

Base.showerror(io::IO, e::_DataProviderHTTPError) = print(
    io,
    "EDP request failed with HTTP ",
    e.status,
    ": ",
    e.detail,
    e.error_code === nothing ? "" : " (code=$(e.error_code))",
    e.reason_code === nothing ? "" : " (reason_code=$(e.reason_code))",
)

"""
    _REDISTRIBUTION_EXCLUDED_SERIES

DME の catalog（金融ストレス観測・CCC 実証）に宣言してはならない FRED 系列 ID
（ADR 0029）。キーは FRED の元 ID（大文字）。`basis` は除外の根拠で、
`"edp_distribution_stopped"` は EDP が提供を停止した系列（EDP 契約 6.0.0・ADR 072、
`GET /v1/series/{id}` が HTTP 410 `distribution_stopped`）、`"dme_rights_review"` は EDP の
catalog には無いが同じ権利表示（FRED 区分 "Copyrighted: Pre-Approval Required"、ICE Data
Indices の "internal use only" 注記）を持つため DME が自ら宣言から外した系列を表す。
"""
const _REDISTRIBUTION_EXCLUDED_SERIES = Dict{String, NamedTuple}(
    "BAMLH0A0HYM2" => (
        name = "ICE BofA US High Yield Index Option-Adjusted Spread",
        basis = "edp_distribution_stopped",
        reason_code = "redistribution_rights",
        reference = "economic-data-provider ADR 072 (contract 6.0.0, 2026-11-07); DME ADR 0029",
    ),
    "BAMLH0A3HYC" => (
        name = "ICE BofA CCC & Lower US High Yield Index Option-Adjusted Spread",
        basis = "edp_distribution_stopped",
        reason_code = "redistribution_rights",
        reference = "economic-data-provider ADR 072 (contract 6.0.0, 2026-11-07); DME ADR 0029",
    ),
    "BAMLC0A0CM" => (
        name = "ICE BofA US Corporate Index Option-Adjusted Spread",
        basis = "dme_rights_review",
        reason_code = "redistribution_rights",
        reference = "DME ADR 0029 (same ICE Data Indices notice as the EDP-stopped series)",
    ),
)

"""
    _redistribution_excluded_series_id(provider_series_id) -> Union{String,Nothing}

`provider_series_id` が `_REDISTRIBUTION_EXCLUDED_SERIES` の系列を指していれば、その FRED
元 ID を返す。前後の空白・大文字小文字・CCC catalog の `FRED_` 接頭辞を無視して照合する
（FRED の ID は大文字小文字を区別しないため。EDP ADR 072 決定2と同じ照合）。
"""
function _redistribution_excluded_series_id(
    provider_series_id::AbstractString,
)::Union{String, Nothing}
    id = uppercase(strip(provider_series_id))
    startswith(id, "FRED_") && (id = id[(lastindex("FRED_") + 1):end])
    return haskey(_REDISTRIBUTION_EXCLUDED_SERIES, id) ? id : nothing
end

"""EDP の HTTP 410 `distribution_stopped`（EDP ADR 060・ADR 072）かどうか。"""
_data_provider_distribution_stopped(e::_DataProviderHTTPError)::Bool =
    e.status == 410 && e.error_code == "distribution_stopped"

const _DATA_PROVIDER_ERROR_TOKEN = r"^[a-z][a-z0-9_]{0,63}$"

"""
    _data_provider_error_codes(body) -> (code, reason_code)

Extract EDP's structured error tokens from a non-success response body of the shape
`{"detail": {"code": "...", "reason_code": "..."}}`.  Anything else (a plain-string
`detail`, invalid JSON, a value that is not a short lowercase token) yields `nothing`
for that field: the body is untrusted and is never echoed into DME artifacts.
"""
function _data_provider_error_codes(
    body::AbstractString,
)::Tuple{Union{String, Nothing}, Union{String, Nothing}}
    parsed = try
        json_read(String(body))
    catch
        return (nothing, nothing)
    end
    parsed isa AbstractDict || return (nothing, nothing)
    detail = get(parsed, "detail", nothing)
    detail isa AbstractDict || return (nothing, nothing)
    token(value) =
        (value isa AbstractString && occursin(_DATA_PROVIDER_ERROR_TOKEN, value)) ?
        String(value) : nothing
    return (token(get(detail, "code", nothing)), token(get(detail, "reason_code", nothing)))
end

"""Internal error for a fixture that has no response file for the requested route."""
struct _DataProviderFixtureMissingError <: Exception
    endpoint::String
end

Base.showerror(io::IO, e::_DataProviderFixtureMissingError) =
    print(io, "EDP fixture is missing for ", e.endpoint)

function _data_provider_http_get(url::String, timeout_seconds::Float64)::String
    buffer = IOBuffer()
    response = Downloads.request(url; output = buffer, timeout = timeout_seconds)
    body = String(take!(buffer))
    if response.status != 200
        code, reason_code = _data_provider_error_codes(body)
        throw(
            _DataProviderHTTPError(
                response.status,
                "EDP returned a non-success response",
                code,
                reason_code,
            ),
        )
    end
    return body
end

function _data_provider_endpoint(client::DataProviderClient, suffix::String)::String
    isempty(strip(client.base_url)) && throw(
        ArgumentError(
            "DATA_PROVIDER_BASE_URL が未設定です。:live または :rest_api では EDP の基底URLを設定してください。",
        ),
    )
    return "$(rstrip(client.base_url, '/'))$(suffix)"
end

function _validate_provider_series_id(series_id::String)::Nothing
    isempty(series_id) && throw(ArgumentError("provider series ID は空にできません"))
    occursin(r"^[A-Za-z0-9._:-]+$", series_id) || throw(
        ArgumentError(
            "provider series ID は URL path segment として安全な文字だけを使う必要があります: $series_id",
        ),
    )
    return nothing
end

function _data_provider_fixture_path(client::DataProviderClient, endpoint::String)::String
    if endpoint == "/v1/catalog/series"
        return joinpath(client.fixture_dir, "catalog.json")
    end
    prefix = "/v1/series/"
    startswith(endpoint, prefix) ||
        throw(ArgumentError("未知の EDP fixture endpoint: $endpoint"))
    series_id = endpoint[(lastindex(prefix) + 1):end]
    _validate_provider_series_id(series_id)
    return joinpath(client.fixture_dir, "series", "$(series_id).json")
end

function _fetch_data_provider_response(client::DataProviderClient, endpoint::String)::String
    if client.mode == :fixture
        path = _data_provider_fixture_path(client, endpoint)
        isfile(path) || throw(_DataProviderFixtureMissingError(endpoint))
        return read(path, String)
    end
    return client.requester(
        _data_provider_endpoint(client, endpoint),
        client.timeout_seconds,
    )
end

"""
    fetch_provider_catalog(; client = DataProviderClient()) -> String

Fetch the raw JSON response from EDP's `/v1/catalog/series` endpoint.  The
DME-side catalog remains the selection authority; this response is used only
for metadata and availability checks by consumers such as the CCC adapter.
"""
function fetch_provider_catalog(; client::DataProviderClient = DataProviderClient())::String
    return _fetch_data_provider_response(client, "/v1/catalog/series")
end

"""
    fetch_provider_series(series_id; client = DataProviderClient()) -> String

Fetch the raw JSON response from EDP's `/v1/series/{series_id}` endpoint.
`series_id` is passed through unchanged, so the caller's catalog controls any
provider prefix.  No direct-source fallback is attempted.
"""
function fetch_provider_series(
    series_id::String;
    client::DataProviderClient = DataProviderClient(),
)::String
    _validate_provider_series_id(series_id)
    return _fetch_data_provider_response(client, "/v1/series/$(series_id)")
end
