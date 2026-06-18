# FRED (Federal Reserve Economic Data) API クライアント
# https://fred.stlouisfed.org/docs/api/fred/
#
# データ取得モード:
#   :fixture   ローカルの fixture ファイルを使用（デフォルト・API キー不要）
#   :live      実際の FRED API を使用（FRED_API_KEY 環境変数が必要）
#   :rest_api  economic-data-provider REST API 経由（DATA_PROVIDER_BASE_URL が必要）
#
# fixture ディレクトリ: test/fixtures/fred/<SERIES_ID>.json

const _FRED_BASE_URL = "https://api.stlouisfed.org/fred"
const _DEFAULT_FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "test", "fixtures")
const _DEFAULT_REST_API_URL = "http://localhost:8000"

"""
    FredClient

FRED API クライアント。接続モードと API キーを保持する。

## フィールド
- `api_key`: FRED API キー。`nothing` のときは fixture/rest_api モードで動作。
- `mode`: データ取得モード。`:fixture`（デフォルト）、`:live`、または `:rest_api`。
- `fixture_dir`: fixture データのディレクトリパス。
- `base_url`: FRED API の基底 URL（テスト用のみ変更）。
- `rest_api_url`: economic-data-provider REST API の基底 URL。

## 使用例
```julia
# fixture モード（デフォルト・API キー不要）
client = FredClient()

# live モード（環境変数から API キーを読む）
# export FRED_API_KEY=your_key
client = FredClient(mode=:live)

# REST API モード（economic-data-provider サーバー経由）
# export DATA_PROVIDER_BASE_URL=http://localhost:8000
client = FredClient(mode=:rest_api)

# キーを直接渡す場合
client = FredClient(api_key="your_key", mode=:live)
```
"""
struct FredClient
    api_key::Union{String, Nothing}
    mode::Symbol
    fixture_dir::String
    base_url::String
    rest_api_url::String
end

"""
    FredClient(; api_key, mode, fixture_dir, base_url, rest_api_url) -> FredClient

FRED クライアントを作成する。

- `api_key`: FRED API キー。省略時は環境変数 `FRED_API_KEY` を参照。
- `mode`: `:fixture`、`:live`、または `:rest_api`。省略時は `DME_DATA_MODE` 環境変数を参照し、
  それも未設定の場合は API キーが存在すれば `:live`、なければ `:fixture`。
- `fixture_dir`: fixture JSON のディレクトリ（デフォルト: `test/fixtures`）。
- `base_url`: FRED API 基底 URL（デフォルト: `https://api.stlouisfed.org/fred`）。
- `rest_api_url`: economic-data-provider REST API 基底 URL。省略時は `DATA_PROVIDER_BASE_URL` 環境変数、
  それも未設定の場合は `http://localhost:8000`。
"""
function FredClient(;
    api_key::Union{String, Nothing} = nothing,
    mode::Union{Symbol, Nothing} = nothing,
    fixture_dir::String = _DEFAULT_FIXTURE_DIR,
    base_url::String = _FRED_BASE_URL,
    rest_api_url::Union{String, Nothing} = nothing,
)
    resolved_key = api_key !== nothing ? api_key : get(ENV, "FRED_API_KEY", nothing)

    resolved_mode = if mode !== nothing
        mode
    elseif get(ENV, "DME_DATA_MODE", "") != ""
        Symbol(ENV["DME_DATA_MODE"])
    elseif resolved_key !== nothing
        :live
    else
        :fixture
    end

    resolved_rest_url = if rest_api_url !== nothing
        rest_api_url
    else
        get(ENV, "DATA_PROVIDER_BASE_URL", _DEFAULT_REST_API_URL)
    end

    FredClient(resolved_key, resolved_mode, fixture_dir, base_url, resolved_rest_url)
end

# ----------------------------------------------------------------
# Public API
# ----------------------------------------------------------------

"""
    fetch_fred_series(series_id; client, start_date, end_date) -> DataSeries

FRED から指定した系列を取得し、`DataSeries` に変換する。

## 引数
- `series_id`: FRED 系列 ID（例: `"GDPC1"`, `"CPIAUCSL"`, `"UNRATE"`）。
- `client`: `FredClient`。省略時はデフォルトのクライアントを作成。
- `start_date`: 開始日（`"YYYY-MM-DD"` 形式）。省略時は全期間（live モードのみ有効）。
- `end_date`: 終了日（`"YYYY-MM-DD"` 形式）。省略時は全期間（live モードのみ有効）。

## モード別の動作
- `:fixture`  — `client.fixture_dir/fred/<series_id>.json` を読み込む。
- `:live`     — FRED API を呼び出す（`FRED_API_KEY` が必要）。
- `:rest_api` — economic-data-provider REST API 経由でデータを取得する。

## 返り値
系列 id は `"FRED_<series_id>"` 形式（例: `"FRED_GDPC1"`）。

## 使用例
```julia
using DME

# fixture モード（デフォルト・API キー不要）
gdp = fetch_fred_series("GDPC1")
gdp["2020-Q1"]   # 19254.0

# live モード
# export FRED_API_KEY=your_key
client = FredClient(mode=:live)
gdp = fetch_fred_series("GDPC1"; client=client, start_date="2020-01-01")

# REST API モード
# export DATA_PROVIDER_BASE_URL=http://localhost:8000
client = FredClient(mode=:rest_api)
gdp = fetch_fred_series("GDPC1"; client=client)
```
"""
function fetch_fred_series(
    series_id::String;
    client::FredClient = FredClient(),
    start_date::Union{String, Nothing} = nothing,
    end_date::Union{String, Nothing} = nothing,
)::DataSeries
    if client.mode == :fixture
        return _load_fred_fixture(series_id, client.fixture_dir)
    end

    if client.mode == :rest_api
        return _fetch_fred_rest_api(series_id, client)
    end

    if client.api_key === nothing
        error(
            "FRED_API_KEY が設定されていません。\n" *
            "  live モードで使用する場合:\n" *
            "    https://fred.stlouisfed.org/docs/api/api_key.html で API キーを取得し、\n" *
            "    環境変数 FRED_API_KEY に設定してください。\n" *
            "  API キーなしで使用する場合（テスト・デモ）:\n" *
            "    DME_DATA_MODE=fixture を設定するか、FredClient(mode=:fixture) を使用してください。\n" *
            "  REST API 経由で使用する場合:\n" *
            "    DME_DATA_MODE=rest_api を設定するか、FredClient(mode=:rest_api) を使用してください。",
        )
    end

    _fetch_fred_live(series_id, client, start_date, end_date)
end

"""
    fetch_fred_dataset(series_ids; client, start_date, end_date, name) -> MacroDataset

複数の FRED 系列を取得し、`MacroDataset` に変換する。

## 引数
- `series_ids`: 取得する系列 ID のベクタ（例: `["GDPC1", "CPIAUCSL"]`）。
- `client`: `FredClient`。省略時はデフォルトのクライアントを作成。
- `start_date`, `end_date`: 期間指定（live モードのみ有効）。
- `name`: データセット名（デフォルト: `"FRED Dataset"`）。

## 使用例
```julia
using DME

ds = fetch_fred_dataset(["GDPC1", "CPIAUCSL", "UNRATE", "FEDFUNDS", "GS10"])
series_ids(ds)  # ["FRED_GDPC1", "FRED_CPIAUCSL", ...]
get_series(ds, "FRED_GDPC1")["2020-Q1"]  # 19254.0
```
"""
function fetch_fred_dataset(
    series_ids::Vector{String};
    client::FredClient = FredClient(),
    start_date::Union{String, Nothing} = nothing,
    end_date::Union{String, Nothing} = nothing,
    name::String = "FRED Dataset",
)::MacroDataset
    ds = MacroDataset(name)
    for id in series_ids
        s = fetch_fred_series(
            id;
            client = client,
            start_date = start_date,
            end_date = end_date,
        )
        push!(ds, s)
    end
    ds
end

# ----------------------------------------------------------------
# Fixture loading
# ----------------------------------------------------------------

function _load_fred_fixture(series_id::String, fixture_dir::String)::DataSeries
    path = joinpath(fixture_dir, "fred", "$(series_id).json")
    isfile(path) || error(
        "FRED fixture が見つかりません: $path\n" *
        "  fixture を追加するか、DME_DATA_MODE=live と FRED_API_KEY を設定して実 API を使用してください。",
    )
    _parse_fred_json(read(path, String))
end

# ----------------------------------------------------------------
# Live API
# ----------------------------------------------------------------

function _fetch_fred_live(
    series_id::String,
    client::FredClient,
    start_date::Union{String, Nothing},
    end_date::Union{String, Nothing},
)::DataSeries
    meta_url = _build_fred_url(client.base_url, "/series", client.api_key, series_id)
    meta_data = JSON3.read(_http_get(meta_url))
    series_info = first(meta_data["seriess"])

    freq = _detect_frequency(String(series_info["frequency"]))
    title = String(series_info["title"])
    units = String(series_info["units"])
    sa = string(get(series_info, "seasonal_adjustment", ""))

    obs_params = Dict{String, String}()
    start_date !== nothing && (obs_params["observation_start"] = start_date)
    end_date !== nothing && (obs_params["observation_end"] = end_date)
    obs_url = _build_fred_url(
        client.base_url,
        "/series/observations",
        client.api_key,
        series_id;
        params = obs_params,
    )
    obs_data = JSON3.read(_http_get(obs_url))
    dates, values = _parse_fred_observations(obs_data["observations"], freq)

    DataSeries(
        id = "FRED_$(series_id)",
        name = title,
        source = "FRED",
        frequency = freq,
        unit = units,
        dates = dates,
        values = values,
        metadata = Dict{String, Any}("seasonal_adjustment" => sa),
    )
end

# ----------------------------------------------------------------
# REST API
# ----------------------------------------------------------------

function _fetch_fred_rest_api(series_id::String, client::FredClient)::DataSeries
    url = "$(rstrip(client.rest_api_url, '/'))/v1/series/FRED_$(series_id)"
    json_str = _http_get(url)
    _parse_rest_api_response(json_str, "FRED")
end

"""
    _parse_rest_api_response(json_str, source) -> DataSeries

economic-data-provider REST API の TimeSeries JSON レスポンスを DataSeries に変換する。

レスポンス形式:
  {
    "id": "FRED_GDPC1",
    "source_id": "GDPC1",
    "name": "Real GDP",
    "unit": "...",
    "frequency": "quarterly",
    "points": [{"label": "2020-Q1", "value": 19254.0}, ...]
  }
"""
function _parse_rest_api_response(json_str::String, source::String)::DataSeries
    data = JSON3.read(json_str)
    freq = _rest_api_frequency(String(data["frequency"]))
    unit = haskey(data, "unit") && data["unit"] !== nothing ? String(data["unit"]) : ""
    dates = String[]
    values = Union{Float64, Missing}[]
    for pt in data["points"]
        push!(dates, String(pt["label"]))
        v = pt["value"]
        push!(values, v === nothing ? missing : Float64(v))
    end
    DataSeries(
        id = String(data["id"]),
        name = String(data["name"]),
        source = source,
        frequency = freq,
        unit = unit,
        dates = dates,
        values = values,
    )
end

function _rest_api_frequency(freq_str::String)::DataFrequency
    if freq_str == "quarterly"
        return Quarterly
    elseif freq_str == "annual"
        return Annual
    else
        return Monthly
    end
end

# ----------------------------------------------------------------
# JSON parsing (shared between fixture and live)
# ----------------------------------------------------------------

function _parse_fred_json(json_str::String)::DataSeries
    data = JSON3.read(json_str)
    s = data["series"]
    freq = _detect_frequency(String(s["frequency"]))
    sa = string(get(s, "seasonal_adjustment", ""))
    dates, values = _parse_fred_observations(data["observations"], freq)
    DataSeries(
        id = "FRED_$(String(s["id"]))",
        name = String(s["title"]),
        source = "FRED",
        frequency = freq,
        unit = String(s["units"]),
        dates = dates,
        values = values,
        metadata = Dict{String, Any}("seasonal_adjustment" => sa),
    )
end

function _parse_fred_observations(observations, freq::DataFrequency)
    dates = String[]
    values = Union{Float64, Missing}[]
    for obs in observations
        date_str = String(obs["date"])
        val_str = String(obs["value"])
        push!(dates, _fred_date_to_label(date_str, freq))
        push!(values, val_str == "." ? missing : parse(Float64, val_str))
    end
    dates, values
end

function _fred_date_to_label(date_str::String, freq::DataFrequency)::String
    year = date_str[1:4]
    month = parse(Int, date_str[6:7])
    if freq == Annual
        return year
    elseif freq == Quarterly
        q = (month - 1) ÷ 3 + 1
        return "$(year)-Q$(q)"
    else
        return date_str[1:7]
    end
end

function _detect_frequency(freq_str::String)::DataFrequency
    if occursin("Quarterly", freq_str)
        return Quarterly
    elseif occursin("Annual", freq_str) || occursin("Semiannual", freq_str)
        return Annual
    else
        return Monthly
    end
end

# ----------------------------------------------------------------
# HTTP utilities
# ----------------------------------------------------------------

function _build_fred_url(
    base_url::String,
    endpoint::String,
    api_key::String,
    series_id::String;
    params::Dict{String, String} = Dict{String, String}(),
)::String
    url = "$(base_url)$(endpoint)?series_id=$(series_id)&api_key=$(api_key)&file_type=json"
    for (k, v) in params
        url *= "&$(k)=$(v)"
    end
    url
end

function _http_get(url::String)::String
    buf = IOBuffer()
    resp = Downloads.request(url; output = buf)
    resp.status == 200 || error("HTTP リクエスト失敗: HTTP $(resp.status) — $(url)")
    String(take!(buf))
end
