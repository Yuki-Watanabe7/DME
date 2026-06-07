# e-Stat（政府統計の総合窓口）API クライアント
# https://api.e-stat.go.jp/
#
# データ取得モード:
#   :fixture  ローカルの fixture ファイルを使用（デフォルト・appId不要）
#   :live     実際の e-Stat API を使用（ESTAT_APP_ID 環境変数が必要）
#
# fixture ディレクトリ: test/fixtures/estat/<STATS_DATA_ID>.json

const _ESTAT_BASE_URL = "https://api.e-stat.go.jp/rest/3.0/app/json"
const _ESTAT_DEFAULT_FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "test", "fixtures")

"""
    EStatClient

e-Stat API クライアント。接続モードと appId を保持する。

## フィールド
- `app_id`: e-Stat API の appId。`nothing` のときは fixture モードで動作。
- `mode`: データ取得モード。`:fixture`（デフォルト）または `:live`。
- `fixture_dir`: fixture データのディレクトリパス。
- `base_url`: e-Stat API の基底 URL（テスト用のみ変更）。

## 使用例
```julia
# fixture モード（デフォルト・appId不要）
client = EStatClient()

# live モード（環境変数から appId を読む）
# export ESTAT_APP_ID=your_app_id
client = EStatClient(mode=:live)

# appId を直接渡す場合
client = EStatClient(app_id="your_app_id", mode=:live)
```
"""
struct EStatClient
    app_id::Union{String, Nothing}
    mode::Symbol
    fixture_dir::String
    base_url::String
end

"""
    EStatClient(; app_id, mode, fixture_dir, base_url) -> EStatClient

e-Stat クライアントを作成する。

- `app_id`: e-Stat appId。省略時は環境変数 `ESTAT_APP_ID` を参照。
- `mode`: `:fixture` または `:live`。省略時は `DME_DATA_MODE` 環境変数を参照し、
  それも未設定の場合は appId が存在すれば `:live`、なければ `:fixture`。
- `fixture_dir`: fixture JSON のディレクトリ（デフォルト: `test/fixtures`）。
- `base_url`: e-Stat API 基底 URL（デフォルト: `https://api.e-stat.go.jp/rest/3.0/app/json`）。
"""
function EStatClient(;
    app_id::Union{String, Nothing} = nothing,
    mode::Union{Symbol, Nothing} = nothing,
    fixture_dir::String = _ESTAT_DEFAULT_FIXTURE_DIR,
    base_url::String = _ESTAT_BASE_URL,
)
    resolved_key = app_id !== nothing ? app_id : get(ENV, "ESTAT_APP_ID", nothing)

    resolved_mode = if mode !== nothing
        mode
    elseif get(ENV, "DME_DATA_MODE", "") != ""
        Symbol(ENV["DME_DATA_MODE"])
    elseif resolved_key !== nothing
        :live
    else
        :fixture
    end

    EStatClient(resolved_key, resolved_mode, fixture_dir, base_url)
end

# ----------------------------------------------------------------
# Public API
# ----------------------------------------------------------------

"""
    fetch_estat_series(stats_data_id; client, ...) -> DataSeries

e-Stat から指定した統計表の時系列を取得し、`DataSeries` に変換する。

## 引数
- `stats_data_id`: 統計表 ID（例: `"0003427113"`）。
- `client`: `EStatClient`。省略時はデフォルトのクライアントを作成。
- `cd_cat01`: 分類事項 01 のコード（live モードのみ有効）。
- `cd_area`: 地域コード（live モードのみ有効）。
- `start_date`: 開始時点（`"YYYY-MM"` 形式、live モードのみ有効）。
- `end_date`: 終了時点（`"YYYY-MM"` 形式、live モードのみ有効）。
- `series_id`: 返す `DataSeries` の id（省略時は `"ESTAT_<stats_data_id>"`）。
- `series_name`: 返す `DataSeries` の name（省略時は統計表名）。

## モード別の動作
- `:fixture` — `client.fixture_dir/estat/<stats_data_id>.json` を読み込む。
- `:live`    — e-Stat API を呼び出す（`ESTAT_APP_ID` が必要）。

## 使用例
```julia
using DME

# fixture モード（デフォルト・appId不要）
cpi = fetch_estat_series("0003427113")
cpi["2020-01"]  # 101.2

# live モード
# export ESTAT_APP_ID=your_app_id
client = EStatClient(mode=:live)
cpi = fetch_estat_series("0003427113"; client=client, cd_cat01="0010001")
```
"""
function fetch_estat_series(
    stats_data_id::String;
    client::EStatClient = EStatClient(),
    cd_cat01::Union{String, Nothing} = nothing,
    cd_area::Union{String, Nothing} = nothing,
    start_date::Union{String, Nothing} = nothing,
    end_date::Union{String, Nothing} = nothing,
    series_id::Union{String, Nothing} = nothing,
    series_name::Union{String, Nothing} = nothing,
)::DataSeries
    if client.mode == :fixture
        return _load_estat_fixture(
            stats_data_id,
            client.fixture_dir;
            series_id = series_id,
            series_name = series_name,
        )
    end

    if client.app_id === nothing
        error(
            "ESTAT_APP_ID が設定されていません。\n" *
            "  live モードで使用する場合:\n" *
            "    https://api.e-stat.go.jp/api/register で appId を取得し、\n" *
            "    環境変数 ESTAT_APP_ID に設定してください。\n" *
            "  appId なしで使用する場合（テスト・デモ）:\n" *
            "    DME_DATA_MODE=fixture を設定するか、EStatClient(mode=:fixture) を使用してください。",
        )
    end

    _fetch_estat_live(
        stats_data_id,
        client;
        cd_cat01 = cd_cat01,
        cd_area = cd_area,
        start_date = start_date,
        end_date = end_date,
        series_id = series_id,
        series_name = series_name,
    )
end

"""
    fetch_estat_dataset(stats_data_ids; client, name, start_date, end_date) -> MacroDataset

複数の e-Stat 統計表を取得し、`MacroDataset` に変換する。

## 使用例
```julia
using DME

ds = fetch_estat_dataset(["0003427113", "0003307059"])
series_ids(ds)  # ["ESTAT_0003427113", "ESTAT_0003307059"]
```
"""
function fetch_estat_dataset(
    stats_data_ids::Vector{String};
    client::EStatClient = EStatClient(),
    name::String = "e-Stat Dataset",
    start_date::Union{String, Nothing} = nothing,
    end_date::Union{String, Nothing} = nothing,
)::MacroDataset
    ds = MacroDataset(name)
    for id in stats_data_ids
        s = fetch_estat_series(
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

function _load_estat_fixture(
    stats_data_id::String,
    fixture_dir::String;
    series_id::Union{String, Nothing} = nothing,
    series_name::Union{String, Nothing} = nothing,
)::DataSeries
    path = joinpath(fixture_dir, "estat", "$(stats_data_id).json")
    isfile(path) || error(
        "e-Stat fixture が見つかりません: $path\n" *
        "  fixture を追加するか、DME_DATA_MODE=live と ESTAT_APP_ID を設定して実 API を使用してください。",
    )
    _parse_estat_json(
        read(path, String),
        stats_data_id;
        series_id = series_id,
        series_name = series_name,
    )
end

# ----------------------------------------------------------------
# Live API
# ----------------------------------------------------------------

function _fetch_estat_live(
    stats_data_id::String,
    client::EStatClient;
    cd_cat01::Union{String, Nothing} = nothing,
    cd_area::Union{String, Nothing} = nothing,
    start_date::Union{String, Nothing} = nothing,
    end_date::Union{String, Nothing} = nothing,
    series_id::Union{String, Nothing} = nothing,
    series_name::Union{String, Nothing} = nothing,
)::DataSeries
    url = _build_estat_url(
        client.base_url,
        client.app_id,
        stats_data_id;
        cd_cat01 = cd_cat01,
        cd_area = cd_area,
        start_date = start_date,
        end_date = end_date,
    )
    json_str = _estat_http_get(url)
    _parse_estat_json(
        json_str,
        stats_data_id;
        series_id = series_id,
        series_name = series_name,
    )
end

function _build_estat_url(
    base_url::String,
    app_id::String,
    stats_data_id::String;
    cd_cat01::Union{String, Nothing} = nothing,
    cd_area::Union{String, Nothing} = nothing,
    start_date::Union{String, Nothing} = nothing,
    end_date::Union{String, Nothing} = nothing,
)::String
    url = "$(base_url)/getStatsData?appId=$(app_id)&statsDataId=$(stats_data_id)"
    cd_cat01 !== nothing && (url *= "&cdCat01=$(cd_cat01)")
    cd_area !== nothing && (url *= "&cdArea=$(cd_area)")
    start_date !== nothing && (url *= "&startDate=$(start_date)")
    end_date !== nothing && (url *= "&endDate=$(end_date)")
    url
end

function _estat_http_get(url::String)::String
    buf = IOBuffer()
    resp = Downloads.request(url; output = buf)
    resp.status == 200 || error("e-Stat API リクエスト失敗: HTTP $(resp.status)")
    String(take!(buf))
end

# ----------------------------------------------------------------
# JSON parsing
# ----------------------------------------------------------------

function _parse_estat_json(
    json_str::String,
    stats_data_id::String;
    series_id::Union{String, Nothing} = nothing,
    series_name::Union{String, Nothing} = nothing,
)::DataSeries
    data = JSON3.read(json_str)
    root = data["GET_STATS_DATA"]

    status = Int(root["RESULT"]["STATUS"])
    status == 0 ||
        error("e-Stat API エラー (STATUS=$(status)): $(root["RESULT"]["ERROR_MSG"])")

    stat_data = root["STATISTICAL_DATA"]
    table_inf = stat_data["TABLE_INF"]

    stats_name = String(get(table_inf, "STATISTICS_NAME", "e-Stat"))
    title_obj = get(table_inf, "TITLE", nothing)
    title = title_obj !== nothing ? string(get(title_obj, "\$", stats_name)) : stats_name
    cycle = String(get(table_inf, "CYCLE", "月次"))
    unit_str = String(get(table_inf, "UNIT", ""))

    freq = _estat_detect_frequency(cycle)

    class_obj = stat_data["CLASS_INF"]["CLASS_OBJ"]
    time_map = _build_estat_time_map(class_obj, freq)

    dates, values = _parse_estat_values(stat_data["DATA_INF"]["VALUE"], time_map)

    sid = series_id !== nothing ? series_id : "ESTAT_$(stats_data_id)"
    sname = series_name !== nothing ? series_name : title

    DataSeries(
        id = sid,
        name = sname,
        source = "e-Stat",
        frequency = freq,
        unit = unit_str,
        dates = dates,
        values = values,
    )
end

function _build_estat_time_map(class_obj, freq::DataFrequency)::Dict{String, String}
    time_classes = if class_obj isa AbstractArray
        filter(c -> String(get(c, "@id", "")) == "time", collect(class_obj))
    else
        String(get(class_obj, "@id", "")) == "time" ? [class_obj] : []
    end

    time_map = Dict{String, String}()
    for tc in time_classes
        classes = tc["CLASS"]
        items = classes isa AbstractArray ? collect(classes) : [classes]
        for item in items
            code = String(item["@code"])
            time_map[code] = _estat_code_to_label(code, freq)
        end
    end
    time_map
end

function _parse_estat_values(values_raw, time_map::Dict{String, String})
    dates = String[]
    values = Union{Float64, Missing}[]
    items = values_raw isa AbstractArray ? collect(values_raw) : [values_raw]
    for v in items
        time_code = String(v["@time"])
        haskey(time_map, time_code) || continue
        push!(dates, time_map[time_code])
        push!(values, _estat_parse_value(String(v["\$"])))
    end
    dates, values
end

function _estat_parse_value(val_str::String)::Union{Float64, Missing}
    stripped = strip(val_str)
    isempty(stripped) && return missing
    stripped in ("-", "***", "X", "…", "－") && return missing
    parsed = tryparse(Float64, replace(stripped, "," => ""))
    parsed === nothing ? missing : parsed
end

function _estat_detect_frequency(cycle::String)::DataFrequency
    if occursin("年次", cycle) || occursin("5年", cycle) || occursin("10年", cycle)
        return Annual
    elseif occursin("四半期", cycle) || occursin("3ヵ月", cycle)
        return Quarterly
    else
        return Monthly
    end
end

"""
    _estat_code_to_label(code, freq) -> String

e-Stat の時間軸コードを DME 日付ラベルに変換する。

対応フォーマット:
- 10文字月次 (`YYYYMM0101`): positions 5-6 が月
- 10文字月次 (`YYYY00MMDD`): positions 5-6 が "00" の場合 positions 7-8 を月として使用
- 年次: 先頭4文字を年として返す
"""
function _estat_code_to_label(code::String, freq::DataFrequency)::String
    length(code) < 4 && return code
    year = code[1:4]
    freq == Annual && return year

    if length(code) >= 6
        month_str = code[5:6]
        if month_str == "00" && length(code) >= 8
            month_str = code[7:8]
        end
        month_num = tryparse(Int, month_str)
        if month_num !== nothing && 1 <= month_num <= 12
            if freq == Quarterly
                q = (month_num - 1) ÷ 3 + 1
                return "$(year)-Q$(q)"
            else
                return "$(year)-$(lpad(month_num, 2, '0'))"
            end
        end
    end
    year
end
