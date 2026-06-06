"""
    DataFrequency

外部マクロデータの観測頻度を表す列挙型。

| 値 | 説明 |
|---|---|
| `Annual` | 年次 |
| `Quarterly` | 四半期次 |
| `Monthly` | 月次 |
"""
@enum DataFrequency Annual Quarterly Monthly

"""
    DataSeries

単一の経済時系列データを保持する標準データ型。

外部データソース（FRED・e-Stat・日銀等）から取得したデータを DME 内で
統一的に扱うための型。欠損値は `missing` で表現する。

## フィールド
- `id::String`                          : 系列識別子（例: "FRED_GDPC1", "GDP"）
- `name::String`                        : 人間可読な系列名（例: "Real GDP"）
- `source::String`                      : データ出所（例: "FRED", "e-Stat", "BOJ"）
- `frequency::DataFrequency`            : 観測頻度（`Annual`, `Quarterly`, `Monthly`）
- `unit::String`                        : 単位（例: "Billions of Chained 2017 Dollars"）
- `dates::Vector{String}`               : 日付ラベル（例: ["2020-Q1", "2020-Q2"]）
- `values::Vector{Union{Float64,Missing}}` : 観測値。欠損値は `missing`
- `metadata::Dict{String,Any}`          : 追加メタデータ（季節調整フラグ等）

## 制約
- `dates` と `values` は同じ長さでなければならない（コンストラクタで検証）

## 使用例
```julia
s = DataSeries(
    id        = "FRED_GDPC1",
    name      = "Real GDP",
    source    = "FRED",
    frequency = Quarterly,
    unit      = "Billions of Chained 2017 Dollars",
    dates     = ["2020-Q1", "2020-Q2", "2020-Q3"],
    values    = [19254.0, 17302.0, 18638.0],
)
s["2020-Q1"]   # 19254.0
length(s)      # 3
```
"""
struct DataSeries
    id::String
    name::String
    source::String
    frequency::DataFrequency
    unit::String
    dates::Vector{String}
    values::Vector{Union{Float64,Missing}}
    metadata::Dict{String,Any}

    function DataSeries(
        id, name, source, frequency, unit, dates, values, metadata=Dict{String,Any}()
    )
        length(dates) == length(values) ||
            throw(ArgumentError("dates と values の長さが一致しません: $(length(dates)) != $(length(values))"))
        new(id, name, source, frequency, unit, dates, collect(Union{Float64,Missing}, values), metadata)
    end
end

"""
    DataSeries(; id, name, source, frequency, unit, dates, values, metadata=Dict())

キーワード引数コンストラクタ。
"""
function DataSeries(;
    id::String,
    name::String,
    source::String,
    frequency::DataFrequency,
    unit::String,
    dates::Vector{String},
    values::AbstractVector,
    metadata::Dict{String,Any}=Dict{String,Any}(),
)
    DataSeries(id, name, source, frequency, unit, dates, values, metadata)
end

"""
    series[date_label]

日付ラベルで観測値を取得する。存在しない場合は `KeyError`。
"""
function Base.getindex(s::DataSeries, date::String)
    idx = findfirst(==(date), s.dates)
    idx === nothing && throw(KeyError(date))
    s.values[idx]
end

"""
    length(series) -> Int

観測点数を返す。
"""
Base.length(s::DataSeries) = length(s.values)

"""
    haskey(series, date_label) -> Bool

指定した日付ラベルが存在するか確認する。
"""
Base.haskey(s::DataSeries, date::String) = date in s.dates

"""
    nonmissing_values(series) -> Vector{Float64}

欠損値を除いた観測値を返す。
"""
nonmissing_values(s::DataSeries) = collect(Float64, skipmissing(s.values))

"""
    missing_count(series) -> Int

欠損値の個数を返す。
"""
missing_count(s::DataSeries) = count(ismissing, s.values)

# ----------------------------------------------------------------

"""
    MacroDataset

複数の `DataSeries` をまとめて管理するコンテナ型。

外部データ取得の結果として複数系列を一括して扱う際に使用する。
系列の追加・取得・一覧はすべてこの型を通じて行う。

## フィールド
- `name::String`                    : データセット名（例: "FRED Macro Dataset"）
- `series::Dict{String,DataSeries}` : 系列 id → `DataSeries` のマップ

## 使用例
```julia
ds = MacroDataset("My Dataset")
push!(ds, gdp_series)
push!(ds, cpi_series)

series_ids(ds)          # ["FRED_GDPC1", "FRED_CPIAUCSL"]
get_series(ds, "FRED_GDPC1")  # DataSeries
```
"""
struct MacroDataset
    name::String
    series::Dict{String,DataSeries}
end

"""
    MacroDataset(name)

空の `MacroDataset` を作成する。
"""
MacroDataset(name::String) = MacroDataset(name, Dict{String,DataSeries}())

"""
    MacroDataset(name, series_list)

`DataSeries` のベクタから `MacroDataset` を作成する。
"""
function MacroDataset(name::String, series_list::Vector{DataSeries})
    d = Dict{String,DataSeries}(s.id => s for s in series_list)
    MacroDataset(name, d)
end

"""
    push!(dataset, series)

`DataSeries` を追加する。同じ id が存在する場合は上書き。
"""
Base.push!(ds::MacroDataset, s::DataSeries) = (ds.series[s.id] = s; ds)

"""
    get_series(dataset, id) -> DataSeries

系列 id で `DataSeries` を取得する。存在しない場合は `KeyError`。
"""
function get_series(ds::MacroDataset, id::String)
    haskey(ds.series, id) || throw(KeyError(id))
    ds.series[id]
end

"""
    series_ids(dataset) -> Vector{String}

利用可能な系列 id のリストを返す。
"""
series_ids(ds::MacroDataset) = collect(keys(ds.series))

"""
    haskey(dataset, id) -> Bool

指定した系列 id が存在するか確認する。
"""
Base.haskey(ds::MacroDataset, id::String) = haskey(ds.series, id)

"""
    length(dataset) -> Int

保持している系列数を返す。
"""
Base.length(ds::MacroDataset) = length(ds.series)
