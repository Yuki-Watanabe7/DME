# FRED (Federal Reserve Economic Data) API クライアント
# https://fred.stlouisfed.org/docs/api/fred/
#
# データ取得モード:
#   :fixture  ローカルの fixture ファイルを使用（デフォルト・API キー不要）
#   :live     実際の FRED API を使用（FRED_API_KEY 環境変数が必要）
#
# fixture ディレクトリ: test/fixtures/fred/<SERIES_ID>.json

const _FRED_BASE_URL = "https://api.stlouisfed.org/fred"
const _DEFAULT_FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "test", "fixtures")

"""
    FredClient

FRED API クライアント。接続モードと API キーを保持する。

## フィールド
- `api_key`: FRED API キー。`nothing` のときは fixture/mock モードで動作。
- `mode`: データ取得モード。`:fixture`（デフォルト）または `:live`。
- `fixture_dir`: fixture データのディレクトリパス。
- `base_url`: FRED API の基底 URL（テスト用のみ変更）。

## 使用例
```julia
# fixture モード（デフォルト・API キー不要）
client = FredClient()

# live モード（環境変数から API キーを読む）
# export FRED_API_KEY=your_key
client = FredClient(mode=:live)

# キーを直接渡す場合
client = FredClient(api_key="your_key", mode=:live)
```
"""
struct FredClient
    api_key::Union{String,Nothing}
    mode::Symbol
    fixture_dir::String
    base_url::String
end

"""
    FredClient(; api_key, mode, fixture_dir, base_url) -> FredClient

FRED クライアントを作成する。

- `api_key`: FRED API キー。省略時は環境変数 `FRED_API_KEY` を参照。
- `mode`: `:fixture` または `:live`。省略時は `DME_DATA_MODE` 環境変数を参照し、
  それも未設定の場合は API キーが存在すれば `:live`、なければ `:fixture`。
- `fixture_dir`: fixture JSON のディレクトリ（デフォルト: `test/fixtures`）。
- `base_url`: FRED API 基底 URL（デフォルト: `https://api.stlouisfed.org/fred`）。
"""
function FredClient(;
    api_key::Union{String,Nothing}=nothing,
    mode::Union{Symbol,Nothing}=nothing,
    fixture_dir::String=_DEFAULT_FIXTURE_DIR,
    base_url::String=_FRED_BASE_URL,
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

    FredClient(resolved_key, resolved_mode, fixture_dir, base_url)
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
- `:fixture` — `client.fixture_dir/fred/<series_id>.json` を読み込む。
- `:live`    — FRED API を呼び出す（`FRED_API_KEY` が必要）。

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
```
"""
function fetch_fred_series(
    series_id::String;
    client::FredClient=FredClient(),
    start_date::Union{String,Nothing}=nothing,
    end_date::Union{String,Nothing}=nothing,
)::DataSeries
    if client.mode == :fixture
        return _load_fred_fixture(series_id, client.fixture_dir)
    end

    if client.api_key === nothing
        error(
            "FRED_API_KEY が設定されていません。\n" *
            "  live モードで使用する場合:\n" *
            "    https://fred.stlouisfed.org/docs/api/api_key.html で API キーを取得し、\n" *
            "    環境変数 FRED_API_KEY に設定してください。\n" *
            "  API キーなしで使用する場合（テスト・デモ）:\n" *
            "    DME_DATA_MODE=fixture を設定するか、FredClient(mode=:fixture) を使用してください。"
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
    client::FredClient=FredClient(),
    start_date::Union{String,Nothing}=nothing,
    end_date::Union{String,Nothing}=nothing,
    name::String="FRED Dataset",
)::MacroDataset
    ds = MacroDataset(name)
    for id in series_ids
        s = fetch_fred_series(id; client=client, start_date=start_date, end_date=end_date)
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
        "  fixture を追加するか、DME_DATA_MODE=live と FRED_API_KEY を設定して実 API を使用してください。"
    )
    _parse_fred_json(read(path, String))
end

# ----------------------------------------------------------------
# Live API
# ----------------------------------------------------------------

function _fetch_fred_live(
    series_id::String,
    client::FredClient,
    start_date::Union{String,Nothing},
    end_date::Union{String,Nothing},
)::DataSeries
    meta_url = _build_fred_url(client.base_url, "/series", client.api_key, series_id)
    meta_data = JSON3.read(_http_get(meta_url))
    series_info = first(meta_data["seriess"])

    freq = _detect_frequency(String(series_info["frequency"]))
    title = String(series_info["title"])
    units = String(series_info["units"])
    sa = string(get(series_info, "seasonal_adjustment", ""))

    obs_params = Dict{String,String}()
    start_date !== nothing && (obs_params["observation_start"] = start_date)
    end_date !== nothing && (obs_params["observation_end"] = end_date)
    obs_url = _build_fred_url(client.base_url, "/series/observations", client.api_key, series_id; params=obs_params)
    obs_data = JSON3.read(_http_get(obs_url))
    dates, values = _parse_fred_observations(obs_data["observations"], freq)

    DataSeries(
        id=       "FRED_$(series_id)",
        name=     title,
        source=   "FRED",
        frequency=freq,
        unit=     units,
        dates=    dates,
        values=   values,
        metadata= Dict{String,Any}("seasonal_adjustment" => sa),
    )
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
        id=       "FRED_$(String(s["id"]))",
        name=     String(s["title"]),
        source=   "FRED",
        frequency=freq,
        unit=     String(s["units"]),
        dates=    dates,
        values=   values,
        metadata= Dict{String,Any}("seasonal_adjustment" => sa),
    )
end

function _parse_fred_observations(observations, freq::DataFrequency)
    dates  = String[]
    values = Union{Float64,Missing}[]
    for obs in observations
        date_str = String(obs["date"])
        val_str  = String(obs["value"])
        push!(dates, _fred_date_to_label(date_str, freq))
        push!(values, val_str == "." ? missing : parse(Float64, val_str))
    end
    dates, values
end

function _fred_date_to_label(date_str::String, freq::DataFrequency)::String
    year  = date_str[1:4]
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
    params::Dict{String,String}=Dict{String,String}(),
)::String
    url = "$(base_url)$(endpoint)?series_id=$(series_id)&api_key=$(api_key)&file_type=json"
    for (k, v) in params
        url *= "&$(k)=$(v)"
    end
    url
end

function _http_get(url::String)::String
    buf  = IOBuffer()
    resp = Downloads.request(url; output=buf)
    resp.status == 200 || error("FRED API リクエスト失敗: HTTP $(resp.status)")
    String(take!(buf))
end
