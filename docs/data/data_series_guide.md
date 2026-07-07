# DataSeries / MacroDataset 利用ガイド

> 関連 Issue: #60

---

## 1. 目的

`DataSeries` と `MacroDataset` は、外部マクロデータ（FRED・e-Stat・日本銀行・内閣府等）を
DME 内で統一的に扱うための標準データ型です。

API ごとに異なる戻り値・メタデータ形式を各接続モジュールが `DataSeries` に変換することで、
前処理・可視化・モデル比較・LLM 解釈を共通のインターフェースで実装できます。

---

## 2. 型の概要

### DataSeries

単一の経済時系列を保持する型。

| フィールド | 型 | 説明 |
|---|---|---|
| `id` | `String` | 系列識別子（例: `"FRED_GDPC1"`, `"GDP"`） |
| `name` | `String` | 人間可読な系列名 |
| `source` | `String` | データ出所（例: `"FRED"`, `"e-Stat"`, `"BOJ"`） |
| `frequency` | `DataFrequency` | 観測頻度（`Annual` / `Quarterly` / `Monthly`） |
| `unit` | `String` | 単位説明 |
| `dates` | `Vector{String}` | 日付ラベル（例: `["2020-Q1", "2020-Q2"]`） |
| `values` | `Vector{Union{Float64,Missing}}` | 観測値。欠損値は `missing` |
| `metadata` | `Dict{String,Any}` | 追加メタデータ（季節調整フラグ等） |

### MacroDataset

複数の `DataSeries` をまとめるコンテナ型。

| フィールド | 型 | 説明 |
|---|---|---|
| `name` | `String` | データセット名 |
| `series` | `Dict{String,DataSeries}` | 系列 id → `DataSeries` のマップ |

---

## 3. 欠損値の扱い方針

- 欠損値は `missing` で表現する（`values` の型は `Vector{Union{Float64,Missing}}`）
- 後処理では `nonmissing_values(s)` で欠損を除いた `Vector{Float64}` を取得する
- 欠損の個数は `missing_count(s)` で確認する
- 欠損値の補完・前方補完・線形補間などは上位の前処理層（`fill_missing` 等、[前処理ユーティリティ](preprocess.md)）が担う

---

## 4. SimulationResult との変換方針

### 4.1 基本方針

`DataSeries` と `SimulationResult` は**目的が異なる**型であり、相互変換は慎重に行う。

| 型 | 用途 |
|---|---|
| `SimulationResult` | モデル計算の出力（定常状態・移行経路・IRF） |
| `DataSeries` | 外部観測データの保持 |

### 4.2 DataSeries → SimulationResult への変換（比較用）

実データとモデル出力を並べてプロットする際に使用する。

```julia
# DataSeries の values を SimulationResult の variables に変換する例
function dataseries_to_simresult(s::DataSeries, scenario::String)
    vals = nonmissing_values(s)
    SimulationResult(
        s.source,
        scenario,
        Dict{String, Vector{Float64}}(s.id => vals),
        Dict{String, Any}(
            "source"    => s.source,
            "unit"      => s.unit,
            "frequency" => string(s.frequency),
        ),
    )
end
```

**注意**: この変換は可視化・比較専用であり、欠損値は除去される。
欠損点を含んだまま比較する場合は `DataSeries` を直接扱うこと。

### 4.3 単位・頻度・スケールの整合性

実データとモデル変数を比較する際は以下を確認すること：

1. **単位の整合**: モデル変数は多くの場合「対定常状態比」「対数偏差」または「ノーマライズ済み」
   → 実データを同じスケールに変換してから比較すること
2. **頻度の整合**: モデルは四半期を想定することが多い。月次データは四半期集計してから比較する
3. **キャリブレーションなし比較の禁止**: キャリブレーションなしにモデル変数と実データ値を
   直接数値比較・同一視しない（`docs/simulation_outputs.md` セクション 6.2 参照）

### 4.4 変換が不要なケース

- 実データの時系列を単独で可視化する場合は `DataSeries` のまま扱う
- モデルとの比較なしに記述統計を取る場合も `nonmissing_values()` を直接使う

---

## 5. 利用例

### 5.1 DataSeries の作成

```julia
using DME

gdp = DataSeries(
    id        = "FRED_GDPC1",
    name      = "Real GDP",
    source    = "FRED",
    frequency = Quarterly,
    unit      = "Billions of Chained 2017 Dollars",
    dates     = ["2019-Q1", "2019-Q2", "2019-Q3", "2019-Q4",
                 "2020-Q1", "2020-Q2", "2020-Q3", "2020-Q4"],
    values    = [19221.0, 19471.0, 19636.0, 19827.0,
                 19254.0, 17302.0, 18638.0, 18878.0],
    metadata  = Dict{String,Any}("seasonal_adjustment" => "SAAR"),
)

gdp["2020-Q2"]      # 17302.0  (COVID ショック期)
length(gdp)         # 8
missing_count(gdp)  # 0
```

### 5.2 MacroDataset による複数系列管理

```julia
cpi = DataSeries(
    id        = "FRED_CPIAUCSL",
    name      = "CPI: All Items",
    source    = "FRED",
    frequency = Monthly,
    unit      = "Index 1982-1984=100",
    dates     = ["2020-01", "2020-02", "2020-03"],
    values    = [258.7, 258.7, 258.1],
)

ds = MacroDataset("US Macro")
push!(ds, gdp)
push!(ds, cpi)

series_ids(ds)              # ["FRED_GDPC1", "FRED_CPIAUCSL"]（順不同）
get_series(ds, "FRED_GDPC1").name  # "Real GDP"
length(ds)                  # 2
```

### 5.3 欠損値を含む系列

```julia
# 一部観測不能な系列
s = DataSeries(
    id        = "BOJ_M2",
    name      = "M2",
    source    = "BOJ",
    frequency = Monthly,
    unit      = "100 Million JPY",
    dates     = ["2020-01", "2020-02", "2020-03"],
    values    = Union{Float64,Missing}[1200.0, missing, 1250.0],
)

missing_count(s)        # 1
nonmissing_values(s)    # [1200.0, 1250.0]
```

---

## 6. 設計上の制約

1. `DataSeries` はイミュータブル（`struct`）。値の変更はコピーを作成して行う
2. `MacroDataset` は `series` フィールドが `Dict` であるため、`push!` で系列を追加・上書きできる
3. 系列 id の重複は上書きとなる。同一ソースで id が衝突しないよう命名規則を設けること
   - 推奨: `"SOURCE_SERIESKEY"` 形式（例: `"FRED_GDPC1"`, `"ESTAT_1004_00001"`）

---

## 7. 外部 API 接続モジュールの責務

本型は外部 API 接続実装（FRED・e-Stat 等）の「受け皿」として設計されている。
各接続モジュールは以下の責務を持つ：

- API レスポンスを `DataSeries` に変換して返す
- `frequency` / `unit` / `source` を API ドキュメントに基づき正確に設定する
- 欠損値を `missing` で明示する（0 や NaN で埋めない）
- `MacroDataset` に複数系列をまとめて返す場合は `MacroDataset` を戻り値とする
