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

"""Internal error that records an HTTP status without retaining a request URL."""
struct _DataProviderHTTPError <: Exception
    status::Int
    detail::String
end

Base.showerror(io::IO, e::_DataProviderHTTPError) =
    print(io, "EDP request failed with HTTP ", e.status, ": ", e.detail)

"""Internal error for a fixture that has no response file for the requested route."""
struct _DataProviderFixtureMissingError <: Exception
    endpoint::String
end

Base.showerror(io::IO, e::_DataProviderFixtureMissingError) =
    print(io, "EDP fixture is missing for ", e.endpoint)

function _data_provider_http_get(url::String, timeout_seconds::Float64)::String
    buffer = IOBuffer()
    response = Downloads.request(url; output = buffer, timeout = timeout_seconds)
    response.status == 200 || throw(
        _DataProviderHTTPError(response.status, "EDP returned a non-success response"),
    )
    return String(take!(buffer))
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
