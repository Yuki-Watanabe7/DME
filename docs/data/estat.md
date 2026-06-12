# e-Stat API 接続ガイド

e-Stat（政府統計の総合窓口）API クライアントの使い方・appId 設定・系列指定例・制約を説明する。

## 概要

`EStatClient` / `fetch_estat_series` / `fetch_estat_dataset` を使い、e-Stat API から日本のマクロ統計系列を取得して DME 標準の `DataSeries` / `MacroDataset` に変換できる。

## appId の取得と設定

### appId 取得

1. [e-Stat ユーザ登録ページ](https://api.e-stat.go.jp/api/register) でユーザ登録する
2. 登録後、マイページから **appId** を発行する
3. **appId はコードに直書きしない**こと

### 環境変数への設定

```bash
export ESTAT_APP_ID=your_app_id_here
```

`.env` ファイルを使う場合は Julia 起動前に `source .env` を実行すること（アプリケーションは `.env` を直接読まない）。

## データ取得モード

| モード | 説明 | 必要なもの |
|---|---|---|
| `:fixture` | ローカル fixture ファイルを使用（デフォルト） | 不要 |
| `:live` | 実際の e-Stat API を呼び出す | `ESTAT_APP_ID` |

モードの自動判定ルール:
1. `mode` キーワード引数が最優先
2. `DME_DATA_MODE` 環境変数（`"fixture"` または `"live"`）
3. `ESTAT_APP_ID` が設定されていれば `:live`、なければ `:fixture`

## 使用例

### fixture モード（テスト・デモ）

```julia
using DME

# デフォルトは fixture モード（appId 不要）
cpi = fetch_estat_series("0003427113")
cpi["2020-01"]  # 101.2

# 複数系列を一括取得
ds = fetch_estat_dataset(["0003427113", "0003307059"])
series_ids(ds)  # ["ESTAT_0003427113", "ESTAT_0003307059"]
```

### live モード（実 API 使用）

```julia
using DME

client = EStatClient(mode=:live)

# CPI（消費者物価指数）を取得
cpi = fetch_estat_series("0003427113"; client=client)

# 分類コードや地域コードで絞り込む
cpi = fetch_estat_series(
    "0003427113";
    client  = client,
    cd_cat01 = "0010001",   # 分類事項01コード
    cd_area  = "00000",     # 地域コード（全国）
)

# 期間を指定する（live モードのみ有効）
cpi = fetch_estat_series(
    "0003427113";
    client     = client,
    start_date = "2020-01",
    end_date   = "2020-12",
)
```

### series_id / series_name の上書き

```julia
cpi = fetch_estat_series(
    "0003427113";
    series_id   = "JPN_CPI",
    series_name = "日本 消費者物価指数（総合）",
)
```

## 対象系列の例

| 系列 | 統計表 ID | 周期 | 単位 | 主な用途 |
|---|---|---|---|---|
| 消費者物価指数（CPI） | 0003427113 | 月次 | 2020年=100 | インフレ動向 |
| 完全失業率（労働力調査） | 0003307059 | 月次 | % | 労働市場 |
| 消費支出（家計調査）2人以上世帯 | 0003343671 | 月次 | 円 | 家計消費 |
| 総人口（人口推計） | 0003445078 | 年次 | 千人 | 人口動態 |

> **注意**: 統計表 ID は e-Stat の改訂により変更される場合がある。最新の ID は [e-Stat データベース](https://www.e-stat.go.jp/stat-search/database) で確認すること。

## fixture の追加方法

`test/fixtures/estat/<STATS_DATA_ID>.json` にファイルを追加することで、fixture モードで使用できる。

ファイル形式（e-Stat API レスポンス準拠）:

```json
{
  "GET_STATS_DATA": {
    "RESULT": {"STATUS": 0, "ERROR_MSG": "正常に終了しました。"},
    "STATISTICAL_DATA": {
      "TABLE_INF": {
        "STATISTICS_NAME": "統計名",
        "TITLE": {"$": "系列タイトル"},
        "CYCLE": "月次",
        "UNIT": "単位文字列"
      },
      "CLASS_INF": {
        "CLASS_OBJ": {
          "@id": "time",
          "@name": "時間軸(月次)",
          "CLASS": [
            {"@code": "2020010101", "@name": "2020年1月"},
            {"@code": "2020020101", "@name": "2020年2月"}
          ]
        }
      },
      "DATA_INF": {
        "VALUE": [
          {"@time": "2020010101", "@unit": "単位", "$": "100.0"},
          {"@time": "2020020101", "@unit": "単位", "$": "101.0"}
        ]
      }
    }
  }
}
```

### 時間軸コード形式

| 周期 | コード形式 | 例 | 変換後ラベル |
|---|---|---|---|
| 月次 | `YYYYMM0101` | `2020010101` | `"2020-01"` |
| 月次（代替） | `YYYY00MMDD` | `2020000101` | `"2020-01"` |
| 年次 | `YYYY000000` | `2020000000` | `"2020"` |

## 制約・注意事項

- e-Stat API は1日あたりのリクエスト数に上限がある（詳細は [利用規約](https://api.e-stat.go.jp/api/terms) 参照）
- 統計表によっては分類コード（`cd_cat01`）や地域コード（`cd_area`）の指定が必要な場合がある
- 複雑な多次元統計表の完全自動解釈は対象外（`CLASS_OBJ` が時間軸のみの場合を想定）
- 季節調整や指数変換は `src/data/preprocess.jl` のユーティリティを使って別途行う
- `DataSeries.source` は `"e-Stat"` に固定される
- 欠損・非公表値（`"-"`, `"***"`, `"X"` 等）は `missing` に変換される
