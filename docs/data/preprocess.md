# 実データ前処理ユーティリティ

`DataSeries` を入力・出力として動作する変換関数群。
各関数は **不変（immutable）** 設計で新しい `DataSeries` を返す。
変換履歴は `metadata["transformations"]` に自動的に追記される。

## 関数一覧

| 関数 | 概要 |
|---|---|
| `fill_missing` | 欠損値を前値・後値・定数で補完 |
| `drop_missing` | 欠損値を持つ観測点を除外 |
| `apply_log` | 自然対数変換 |
| `difference` | 差分変換 |
| `pct_change` | 前期比変化率（%） |
| `moving_average` | 後方移動平均 |
| `standardize` | z スコア標準化 |
| `trim_period` | 期間トリミング |
| `to_quarterly` | 月次 → 四半期次 |
| `to_annual` | 四半期次 → 年次 |

---

## 使用例

### 欠損値処理

```julia
using DME

s = DataSeries(
    id="GDP", name="Real GDP", source="FRED",
    frequency=Quarterly, unit="Billions USD",
    dates=["2020-Q1","2020-Q2","2020-Q3","2020-Q4"],
    values=Union{Float64,Missing}[100.0, missing, 103.0, 105.0],
)

# 前値で補完
r = fill_missing(s; method=:forward)
r.values  # [100.0, 100.0, 103.0, 105.0]

# 欠損点を除外
r2 = drop_missing(s)
length(r2)  # 3
```

### 対数変換

```julia
r = apply_log(s)
r.unit  # "log(Billions USD)"
```

非正値（≤ 0）が含まれる場合は `DomainError` を投げる。

### 差分・変化率

```julia
# 前期差分
r_diff = difference(s)

# 前期比（QoQ）
r_qoq = pct_change(s; periods=1)

# 前年同期比（YoY）— 四半期系列の場合
r_yoy = pct_change(s; periods=4)
```

前期値がゼロまたは欠損の場合、変化率は `missing` になる。

### 移動平均

```julia
# 3 期後方移動平均
r = moving_average(s; window=3)
# 先頭 2 点は missing になる
```

ウィンドウ内に欠損値が含まれる場合はその点も `missing` になる。

### 標準化

```julia
r = standardize(s)
r.unit  # "standardized"
# mean ≈ 0, std ≈ 1
```

### 期間トリミング

```julia
r = trim_period(s; start_date="2020-Q2", end_date="2020-Q4")
length(r)  # 3
```

### 頻度変換

```julia
# 月次 → 四半期（平均）
monthly = DataSeries(
    id="CPI", name="CPI", source="BLS",
    frequency=Monthly, unit="index",
    dates=["2020-01","2020-02","2020-03","2020-04","2020-05","2020-06"],
    values=[260.0,261.0,262.0, 263.0,264.0,265.0],
)
q = to_quarterly(monthly)         # method=:mean がデフォルト
q_sum = to_quarterly(monthly; method=:sum)

# 四半期 → 年次（平均）
annual = to_annual(q)
```

### パイプラインによる複数変換

```julia
result = s |> apply_log |> standardize

# 変換履歴の確認
result.metadata["transformations"]
# ["apply_log", "standardize(mean=..., std=...)"]
```

---

## 不正値・エラーの扱い

| 状況 | 挙動 |
|---|---|
| `apply_log` に非正値 | `DomainError` を投げる |
| `pct_change` で前期値 = 0 | その点を `missing` にする |
| `standardize` で標準偏差 = 0 | `DomainError` を投げる |
| `fill_missing(:forward)` で先頭が欠損 | 先頭の欠損は埋められずに残る |
| `fill_missing(:backward)` で末尾が欠損 | 末尾の欠損は埋められずに残る |
| `moving_average` でウィンドウ内に欠損 | その点を `missing` にする |
| `to_quarterly` / `to_annual` で期間内に欠損 | 欠損を除いて集計（すべて欠損なら `missing`） |
| `trim_period` で存在しない日付ラベル | `KeyError` を投げる |

---

## metadata の保持・変換履歴

すべての関数は `source`・`frequency`（頻度変換関数を除く）・`unit`（変換しない関数のみ）などの metadata フィールドを保持する。
変換履歴は `metadata["transformations"]` に `Vector{String}` として蓄積される。

```julia
r = fill_missing(s; method=:forward)
r.metadata["transformations"]  # ["fill_missing(method=:forward)"]

r2 = apply_log(r)
r2.metadata["transformations"]  # ["fill_missing(method=:forward)", "apply_log"]
```
