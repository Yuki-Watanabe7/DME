# FRED API 接続ガイド

> 関連 Issue: #61

---

## 概要

`DME.fetch_fred_series` / `DME.fetch_fred_dataset` を使用して、
[FRED（Federal Reserve Economic Data）](https://fred.stlouisfed.org/) から
マクロ経済データを取得し、`DataSeries` / `MacroDataset` に変換できます。

**API キーなしでも使用できます**。デフォルトは `fixture` モードで、
ローカルの fixture ファイルからデータを読み込みます。

---

## クイックスタート

### fixture モード（デフォルト・API キー不要）

```julia
using DME

# GDP（実質・四半期）を取得
gdp = fetch_fred_series("GDPC1")
gdp["2020-Q1"]   # => 19254.0
length(gdp)       # => 12

# 複数系列を一括取得
ds = fetch_fred_dataset(["GDPC1", "CPIAUCSL", "UNRATE", "FEDFUNDS", "GS10"])
series_ids(ds)
# => ["FRED_GDPC1", "FRED_CPIAUCSL", "FRED_UNRATE", "FRED_FEDFUNDS", "FRED_GS10"]
```

### live モード（実 FRED API）

```bash
# API キーを環境変数に設定
export FRED_API_KEY=your_api_key_here
export DME_DATA_MODE=live
```

```julia
using DME

# 環境変数から自動的に live モードで動作
gdp = fetch_fred_series("GDPC1")

# または FredClient を明示的に作成
client = FredClient(mode=:live)
gdp = fetch_fred_series("GDPC1"; client=client, start_date="2010-01-01")
```

---

## API キーの取得方法

1. [https://fred.stlouisfed.org/docs/api/api_key.html](https://fred.stlouisfed.org/docs/api/api_key.html) にアクセス
2. FRED アカウントを作成（無料）
3. API キーを発行
4. 環境変数 `FRED_API_KEY` に設定

```bash
export FRED_API_KEY=your_api_key_here
```

`.env` ファイルを使う場合は Julia 起動前に `source .env` を実行すること（アプリケーションは `.env` を直接読まない）。

---

## 主な対象系列

| 系列 ID | 名称 | 頻度 | fixture 利用可 |
|--------|------|------|---------------|
| `GDPC1` | Real Gross Domestic Product | 四半期 | ✓ |
| `CPIAUCSL` | CPI: All Urban Consumers | 月次 | ✓ |
| `UNRATE` | Unemployment Rate | 月次 | ✓ |
| `FEDFUNDS` | Federal Funds Effective Rate | 月次 | ✓ |
| `GS10` | 10-Year Treasury Yield | 月次 | ✓ |

fixture は `test/fixtures/fred/<SERIES_ID>.json` に格納されています。
上記以外の系列を fixture モードで使用するには、同ディレクトリに JSON ファイルを追加してください。

---

## データモード

| モード | 説明 | API キー | fixture |
|-------|------|---------|---------|
| `fixture`（**デフォルト**） | ローカル fixture から読み込み | 不要 | 必要 |
| `live` | 実際の FRED API を呼び出し | 必要 | 不要 |

モードの決定順序:

1. `FredClient(mode=...)` キーワード引数
2. 環境変数 `DME_DATA_MODE`
3. 環境変数 `FRED_API_KEY` が設定されていれば `:live`
4. それ以外は `:fixture`

---

## API リファレンス

### `FredClient`

```julia
FredClient(;
    api_key::Union{String,Nothing}  = nothing,   # FRED_API_KEY 環境変数より優先
    mode::Union{Symbol,Nothing}     = nothing,   # :fixture または :live
    fixture_dir::String             = "test/fixtures",
    base_url::String                = "https://api.stlouisfed.org/fred",
)
```

### `fetch_fred_series`

```julia
fetch_fred_series(
    series_id::String;
    client::FredClient = FredClient(),
    start_date::Union{String,Nothing} = nothing,   # "YYYY-MM-DD"（live のみ有効）
    end_date::Union{String,Nothing}   = nothing,   # "YYYY-MM-DD"（live のみ有効）
) -> DataSeries
```

返り値の `DataSeries` の `id` は `"FRED_<series_id>"` 形式（例: `"FRED_GDPC1"`）。

日付ラベルの形式:
- 四半期: `"2020-Q1"`, `"2020-Q2"`, ...
- 月次: `"2020-01"`, `"2020-02"`, ...
- 年次: `"2020"`, `"2021"`, ...

欠損値（FRED が `"."` で返す値）は `missing` に変換されます。

### `fetch_fred_dataset`

```julia
fetch_fred_dataset(
    series_ids::Vector{String};
    client::FredClient = FredClient(),
    start_date::Union{String,Nothing} = nothing,
    end_date::Union{String,Nothing}   = nothing,
    name::String = "FRED Dataset",
) -> MacroDataset
```

---

## fixture ファイルの追加

新しい系列を fixture モードで使用するには、
`test/fixtures/fred/<SERIES_ID>.json` を以下の形式で作成してください。

```json
{
  "series": {
    "id": "SERIES_ID",
    "title": "Series Name",
    "frequency": "Quarterly",
    "units": "Units Description",
    "seasonal_adjustment": "Seasonally Adjusted"
  },
  "observations": [
    {"date": "2020-01-01", "value": "100.0"},
    {"date": "2020-04-01", "value": "95.0"},
    {"date": "2020-07-01", "value": "."}
  ]
}
```

- `frequency`: `"Quarterly"`, `"Monthly"`, `"Annual"` など
- `value`: 欠損値は `"."` と記載

---

## セキュリティ上の注意

- API キーをコードに直書きしないこと
- `.env` はコミットしないこと（`.gitignore` に登録済み）
- CI では `fixture` モードで動作させること（API キー不要）

---

## 関連ドキュメント

| ドキュメント | 参照目的 |
|------------|---------|
| [設定・環境変数管理ガイド](../development/configuration.md) | `FRED_API_KEY` 等の設定方法 |
| [DataSeries / MacroDataset 利用ガイド](data_series_guide.md) | データ型の使い方 |
| [モデル変数と実データ系列のマッピング表](variable_mapping.md) | どの系列をどのモデル変数に対応させるか |
| [実データ前処理ユーティリティ](preprocess.md) | 取得後の対数変換・差分・集計など |
