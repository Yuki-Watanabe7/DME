# 出力結果の読み方ガイド

DME が返す出力の種類・単位・解釈を横断的にまとめたリファレンスドキュメント。

---

## 目次

1. [出力の種類](#1-出力の種類)
2. [単位と表現形式](#2-単位と表現形式)
3. [Ramsey モデルの出力例](#3-ramsey-モデルの出力例)
4. [RBC モデルの出力例](#4-rbc-モデルの出力例)
5. [SimulationResult 標準型との関係](#5-simulationresult-標準型との関係)
6. [LLM が参照する際の注意点](#6-llm-が参照する際の注意点)
7. [プロット関数の使い分け](#7-プロット関数の使い分け)

---

## 1. 出力の種類

DME の計算関数は、目的に応じて以下の 4 種類の出力を返す。

### 1.1 定常状態（Steady State）

**定義**: すべての変数が一定値に落ち着いた長期均衡。時間インデックスを持たないスカラーの集合。

**概念**:

> 定常状態は経済の「最終的な落ち着き先」であり、移行経路・シミュレーション経路・インパルス応答の基準点となる。

**対応関数**: `steady_state(m)` → `NamedTuple` のスカラー値

```julia
using DME

# Ramsey モデル
m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)
ep.K  # => ≈ 1.226  （定常資本、水準）
ep.C  # => ≈ 0.757  （定常消費、水準）

# RBC モデル
m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
ep = steady_state(m)
ep.K   # 定常資本（水準）
ep.C   # 定常消費（水準）
ep.L   # 定常労働（水準）
ep.Y   # 定常産出（水準）
ep.r   # 定常利子率（水準）
ep.w   # 定常賃金（水準）
ep.A   # 定常 TFP（常に 1.0）
```

---

### 1.2 移行経路（Transition Path）

**定義**: 初期値から定常状態へと収束するまでの変数の時系列。完全予見均衡の概念に基づく。

**概念**:

> 移行経路は「現在の状態から定常状態へどのような経路で向かうか」を表す。NLsolve で T 期間分の均衡条件を一括で解くため、各時点の変数は将来の情報（完全予見）を反映して決まる。ランダムショックは存在せず、外生的に設定した初期値からの決定論的な推移を示す。

**対応関数**: `transition_path(m, ...)` → `NamedTuple` の `Vector{Float64}`

**特徴**:
- 変数の単位は**水準（level）**
- インデックス 1 は初期時点（t=0）、インデックス T+1 が終端（T 期後）
- 終端条件として T+1 期の値が定常値に固定されている（有限期間近似）

---

### 1.3 シミュレーション経路（Simulation Path）

**定義**: ポリシー関数（最適行動関数）を使って初期値から逐次的に計算した変数の時系列。

**概念**:

> シミュレーション経路は「最適行動ルール（ポリシー関数）を適用したとき、状態変数がどのように推移するか」を表す。価値反復法でポリシー関数を事前に求め、それを繰り返し適用する。完全予見経路と異なり、終端条件を明示的に課さない。

**対応関数**: `simulate(m, ...)` → `NamedTuple` の `Vector{Float64}`

**特徴**:
- 変数の単位は**水準（level）**
- Ramsey モデルのみ対応（現バージョン）

---

### 1.4 インパルス応答（Impulse Response Function, IRF）

**定義**: 1 期間だけ外生的なショックが発生したとき、各変数が定常状態からどれだけ乖離するかを表す時系列。

**概念**:

> IRF は「もしショックが起きたとしたら、各変数はどのような動的調整経路をたどるか」という条件付きシミュレーション結果である。未来の予測ではなく、「ショックに対する条件付き反応（conditional response）」を示す。定常状態近傍での線形近似（Blanchard-Kahn 法）によって計算される。

**対応関数**: `impulse_response(m, shock_size)` → `NamedTuple` の `Vector{Float64}`

**特徴**:
- 変数の単位は**対数偏差（log deviation）**
- インデックス 1 は t=0（ショック発生時点）
- RBC モデルのみ対応（現バージョン）

---

## 2. 単位と表現形式

### 2.1 水準系列（Level Series）

**定義**: 変数が実際のスケールで表現された系列。

**用途**: `transition_path`・`simulate`・`steady_state` の出力

**例（Ramsey モデル）**:

```julia
m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)
path = transition_path(m, ep.K / 2)  # K0 = 定常値の半分

path.K[1]   # => ≈ 0.613  （初期資本、水準）
path.K[end] # => ≈ 1.226  （定常状態に収束した資本、水準）
path.C[1]   # => （初期消費、水準）
```

水準系列から定常状態との偏差率（% 偏差）を計算するには手動で変換する:

```julia
# 定常状態からの偏差率（%）
pct_dev_K = (path.K .- ep.K) ./ ep.K .* 100
pct_dev_C = (path.C .- ep.C) ./ ep.C .* 100
```

---

### 2.2 対数偏差（Log Deviation）

**定義**: 変数の自然対数値と定常状態の自然対数値の差。`x̂ = log(x_t) - log(x*)` と定義される。

**用途**: `impulse_response` の出力（RBC モデル）

**なぜ対数偏差を使うか**:
- 小さなショックに対して `x̂ ≈ (x_t - x*) / x*`（相対偏差）と近似できる
- 変数のスケールに依存しないため、資本・消費・賃金・労働など異なる単位の変数を同一の軸で比較できる
- 線形化手法（Blanchard-Kahn 法）の出力と整合する

**例（RBC モデル）**:

```julia
m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(m, 0.01)  # 1% 技術ショック

irf.ŷ[1]  # => ≈ 0.015  （t=0 の産出の対数偏差。約 1.5% の上昇に対応）
irf.k̂[1]  # => 0.0       （資本は先決変数のため t=0 に変化なし）
irf.ĉ[1]  # => （消費の対数偏差）
```

---

### 2.3 パーセント偏差（Percentage Deviation）

**定義**: 対数偏差に 100 を掛けた値。小さなショックの場合に `%` 単位の乖離とほぼ一致する。

**変換方法**:

```julia
# 対数偏差 → パーセント偏差（近似）
pct_dev_y = irf.ŷ * 100   # 例: 0.015 → 1.5%
pct_dev_c = irf.ĉ * 100
pct_dev_k = irf.k̂ * 100
```

> **注意**: この近似が成立するのは偏差が小さい（数 %程度）場合に限る。ショックサイズが大きい（例: ε0 > 0.1）場合は、変換による誤差が無視できなくなる。

---

### 2.4 ベースラインとシナリオの比較（Baseline vs Scenario）

**定義**: 参照となる基準（ベースライン）に対して、異なる条件下でのシナリオを比較する分析手法。

**パターン**:

| 比較の種類 | ベースライン | シナリオ |
|---|---|---|
| 定常状態比較 | 定常状態の値 | 移行経路の各時点の値 |
| パラメータ感度 | 標準パラメータのシミュレーション | 変更後パラメータのシミュレーション |
| 初期値比較 | K0 = ep.K（定常から出発）| K0 = ep.K * 0.8（資本不足から出発） |

**例（Ramsey モデルでの初期値比較）**:

```julia
using DME

m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)

# ベースライン: 定常状態から出発（実際には動かない）
# シナリオ: 資本が定常値の 50% から出発
path_baseline = transition_path(m, ep.K)         # K0 = ep.K
path_scenario  = transition_path(m, ep.K / 2)    # K0 = ep.K / 2

# 各時点での資本の差を確認
diff_K = path_scenario.K .- path_baseline.K
```

---

## 3. Ramsey モデルの出力例

### 3.1 定常状態

```julia
using DME

m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)

ep.K  # => ≈ 1.226  （定常資本）
ep.C  # => ≈ 0.757  （定常消費）
```

**解釈**: `ep.K` と `ep.C` は長期均衡における資本・消費の水準値。移行経路や偏差計算の基準点として使用する。

---

### 3.2 移行経路（transition_path）

```julia
m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)

# K0 が定常値の半分（資本不足の初期状態）
path = transition_path(m, ep.K / 2)

# 出力構造
# path.K: Vector{Float64}（長さ 31 = maxT+1）
# path.C: Vector{Float64}（長さ 31 = maxT+1）
# path.K[1]   = ep.K / 2  （初期値 K0）
# path.K[end] ≈ ep.K      （定常状態に近づく）
```

**典型的なパターン**（K0 < K*（資本不足）の場合）:
- 資本 `K`: 単調に K* へ増加する
- 消費 `C`: 初期は抑制気味に始まり、資本蓄積につれて緩やかに上昇して C* に収束する

---

### 3.3 シミュレーション経路（simulate）

```julia
m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)

result = simulate(m, ep.K / 2)

# result.K: Vector{Float64}（長さ 30 = maxT デフォルト）
# result.C: Vector{Float64}（長さ 30）
```

**`transition_path` との違い**:

| 比較軸 | `transition_path` | `simulate` |
|---|---|---|
| 求解方法 | NLsolve による一括求解（完全予見） | ポリシー関数を逐次適用 |
| 終端条件 | T+1 期の値を定常値に固定 | なし |
| 出力の長さ | `maxT + 1`（初期値込み） | `maxT` |

---

## 4. RBC モデルの出力例

### 4.1 定常状態

```julia
using DME

m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
ep = steady_state(m)

ep.K  # 定常資本（水準）
ep.C  # 定常消費（水準）
ep.L  # 定常労働（水準）
ep.Y  # 定常産出（水準）
ep.r  # 定常利子率（水準）
ep.w  # 定常賃金（水準）
ep.A  # => 1.0（TFP の定常値、常に 1.0 に正規化）
```

---

### 4.2 移行経路（transition_path）

```julia
m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
ep = steady_state(m)

# A0 = 定常値（1.0）、K0 = 定常値の 80%（資本不足）
path = transition_path(m, 1.0, ep.K * 0.8)

# 出力変数（すべて水準・Vector{Float64}、長さ maxT+1 = 151）
path.K  # 資本系列
path.C  # 消費系列
path.L  # 労働系列
path.Y  # 産出系列
path.r  # 利子率系列
path.w  # 賃金系列
path.A  # TFP 系列（A0 = 1.0 から定常値 1.0 へ）
```

**解釈のポイント**: 出力はすべて**水準系列**。定常値 `ep.K` 等と比較することで乖離度を確認する。

---

### 4.3 インパルス応答（impulse_response）

```julia
m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)

# ε0 = 0.01: t=0 に TFP が約 1% 上昇するショック
irf = impulse_response(m, 0.01)

# 出力変数（すべて対数偏差・Vector{Float64}、長さ maxT+1 = 151）
irf.â   # TFP の対数偏差
irf.k̂   # 資本の対数偏差
irf.ĉ   # 消費の対数偏差
irf.l̂   # 労働の対数偏差
irf.ŷ   # 産出の対数偏差
irf.r̂   # 利子率の対数偏差
irf.ŵ   # 賃金の対数偏差
```

**正の技術ショック（ε0 = 0.01）に対する典型的な IRF パターン**:

| 変数 | t=0 の反応 | その後の動き |
|---|---|---|
| `â`（TFP） | +ε0（ショックが直撃） | AR(1) に従い ρ の速度でゼロへ減衰 |
| `k̂`（資本） | 0（先決変数、変化なし） | 投資増により数期にわたって上昇し、遅れてピーク後に収束 |
| `ĉ`（消費） | 正（ジャンプ可能な飛躍変数） | 資本より緩やかなペースで収束（消費平準化） |
| `ŷ`（産出） | 大きく正（TFP ショックに同期） | TFP の減衰とともに縮小 |
| `l̂`（労働） | 正（異時点間代替） | 数期後にゼロへ収束 |
| `r̂`（利子率） | 正（資本の限界生産物上昇） | 資本蓄積が進むにつれて下落 |
| `ŵ`（賃金） | 正（TFP と資本の増加を反映） | 比較的持続的に高い水準を維持 |

**パーセント偏差への変換**:

```julia
irf.ŷ * 100   # 産出の % 偏差（例: 0.015 → 1.5%）
irf.ĉ * 100   # 消費の % 偏差
irf.k̂ * 100   # 資本の % 偏差
```

---

## 5. SimulationResult 標準型との関係

### 5.1 SimulationResult とは

`SimulationResult` はモデルの種類・出力の種類を問わず、シミュレーション結果を統一的に扱うためのコンテナ型である。各モデル関数が返す `NamedTuple` を `SimulationResult` に変換することで、モデル横断的な後処理が可能になる。

```julia
struct SimulationResult
    model_name::String                          # モデル名
    scenario_name::String                       # 計算種別（"transition", "simulate", "shock" など）
    variables::Dict{String, Vector{Float64}}    # 変数名 → 時系列
    metadata::Dict{String, Any}                 # パラメータ等のメタデータ
end
```

### 5.2 NamedTuple から SimulationResult への変換

```julia
using DME

# Ramsey モデルの移行経路を SimulationResult に変換
m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)
path = transition_path(m, ep.K / 2)

sr = to_simulation_result(m, path, "transition")

sr["K"]          # 変数系列の取得（String キーでアクセス）
sr["C"]
nperiods(sr)     # 期間数
variable_names(sr)  # ["K", "C"]
sr.model_name    # "Ramsey Model"
sr.scenario_name # "transition"
sr.metadata["parameters"]  # モデルパラメータ

# RBC モデルの IRF も同様に変換可能
m_rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(m_rbc, 0.01)
sr_irf = to_simulation_result(m_rbc, irf, "impulse_response")

sr_irf["ŷ"]  # 産出の対数偏差系列
```

### 5.3 変数名の規則

`SimulationResult` に格納される変数名は元の `NamedTuple` のシンボル名を文字列化したもの。

| モデル | 計算種別 | 変数名 |
|---|---|---|
| Ramsey | `transition_path` / `simulate` | `"K"`, `"C"` |
| RBC | `transition_path` | `"A"`, `"r"`, `"w"`, `"L"`, `"K"`, `"Y"`, `"C"` |
| RBC | `impulse_response` | `"â"`, `"r̂"`, `"ŵ"`, `"l̂"`, `"k̂"`, `"ŷ"`, `"ĉ"` |

---

## 6. LLM が参照する際の注意点

### 6.1 水準と偏差を混同しない

**よくある誤り**: `transition_path` の出力（水準）と `impulse_response` の出力（対数偏差）を同じ変数として扱う。

**正しい理解**:

| 出力 | 単位 | 「0」の意味 |
|---|---|---|
| `transition_path` の K | 水準（実質） | 資本ストックがゼロ（経済崩壊） |
| `impulse_response` の k̂ | 対数偏差 | 定常値と一致（乖離なし） |

```julia
# 誤り: impulse_response の出力を水準として扱う
irf.ŷ[1]  # 0.015 を「産出 = 0.015」と解釈してはならない

# 正しい: 産出が定常値より約 1.5% 高いという意味
"産出は定常状態より $(irf.ŷ[1] * 100) % 高い"
```

---

### 6.2 実データとモデル変数を直接同一視しない

モデル変数と実際の経済データの対応は直接的ではない。

| モデル変数 | 対応候補データ | 注意事項 |
|---|---|---|
| K（資本） | 固定資本ストック（SNA/BEA） | 無形資産・人的資本は通常含まない |
| C（消費） | 家計最終消費支出（PCE） | 耐久財の扱いに注意 |
| Y（産出） | 実質 GDP | 季節調整・デフレーターの処理が必要 |
| L（労働） | 総実労働時間 | 就業者数 × 平均労働時間 |
| r（利子率） | 実質短期金利 | 名目金利 − インフレ率で実質化が必要 |
| A（TFP） | Solow 残差 | HP フィルタ等で循環成分を抽出 |

特に以下の点に注意:
- モデルの変数は**実質値**。名目値と比較する場合はデフレーターで実質化する
- モデルの定常状態は「長期均衡」の概念であり、特定の実際の年を指すわけではない
- 線形化ベースの IRF はモデルの「条件付き期待値」であり、実データの予測値ではない

---

### 6.3 ショック応答は予測ではなく条件付き反応

**誤解**: インパルス応答を「将来の経済予測」として解釈する。

**正しい解釈**: IRF は「仮にショックが発生したとすれば、モデル内で各変数はどのような経路をたどるか」を示す**条件付きシミュレーション結果**である。

- ショックが実際に発生するかどうかは IRF に含まれない
- 複数のショックが同時に起きる現実の景気循環とは異なる
- 線形化の精度範囲内（小さいショック）でのみ信頼できる近似

---

### 6.4 インデックスの規則

| 出力 | `result[1]` | `result[end]` |
|---|---|---|
| `transition_path` | t=0（初期値 K0, A0） | t=T（終端期） |
| `simulate` | t=1 | t=T |
| `impulse_response` | t=0（ショック発生時点） | t=T |

```julia
# transition_path: K[1] は初期値
path = transition_path(m, ep.K / 2)
path.K[1]  # == ep.K / 2  （設定した初期値）

# impulse_response: 1-indexed (Julia デフォルト)
irf = impulse_response(m, 0.01)
irf.â[1]   # t=0 のショック（≈ 0.01）
irf.â[2]   # t=1 の TFP 偏差（≈ 0.01 * ρ）
irf.k̂[1]   # 0.0（資本は先決変数のため t=0 に変化しない）
```

---

### 6.5 線形化の精度範囲

`impulse_response`（Blanchard-Kahn 法）は**定常状態近傍での一次近似**であるため、以下の場合に精度が低下する:

- ショックサイズが大きい（目安: `|ε0| > 0.05` 程度）
- ρ が 1 に非常に近い（例: ρ = 0.99）
- 複数のショックが累積している状況

大きなショックの分析には `transition_path` による非線形解法を使用すること。

---

## 7. プロット関数の使い分け

DME には `SimulationResult` を可視化する 2 つの関数がある。

| 関数 | 対象データ | ゼロライン | x 軸の起点 | Y 軸デフォルト |
|---|---|---|---|---|
| `plot_result` | 水準系列（`transition_path` / `simulate`） | なし | 1（Period 1） | `""` |
| `plot_irf` | 対数偏差系列（`impulse_response`） | あり（点線） | 0（ショック発生時点） | `"Log deviation from steady state"` |

**`plot_result` を使う場面**:
- `transition_path` や `simulate` の水準系列を確認するとき
- 変数が実際の経済量（資本水準、消費水準など）として解釈できるとき

**`plot_irf` を使う場面**:
- `impulse_response` の出力（対数偏差）を可視化するとき
- 定常状態から各変数がどれだけ乖離しているかを見るとき
- ゼロライン（= 定常状態への収束）が比較基準として重要なとき

### 例

```julia
using DME

m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
ep = steady_state(m)

# 水準系列 → plot_result
path = transition_path(m, 1.0, ep.K * 0.8)
sr_path = to_simulation_result(m, path, "transition")
p1 = plot_result(sr_path; vars = ["K", "Y"])   # 水準が表示される

# IRF（対数偏差）→ plot_irf
irf = impulse_response(m, 0.01)
sr_irf = to_simulation_result(m, irf, "technology_shock")
p2 = plot_irf(sr_irf; vars = ["ŷ", "ĉ", "k̂"], shock_size = 0.01)
# ゼロラインが表示され、x 軸は t=0 始まり
```

### `plot_irf` の追加キーワード引数

```julia
plot_irf(result; vars = ["ŷ", "ĉ"], shock_size = 0.01)
# → タイトル: "RBC Model — technology_shock (IRF, shock = 0.01)"

# metadata にショックサイズを格納する場合
meta = Dict{String, Any}("shock_size" => 0.01)
sr = SimulationResult(model_name, scenario_name, variables, meta)
plot_irf(sr)  # metadata["shock_size"] を自動参照

# New Keynesian モデルにも適用可能
m_nk = NewKeynesianModel(...)
irf_nk = impulse_response(m_nk; shock = :monetary, T = 20)
sr_nk = to_simulation_result(m_nk, irf_nk, "monetary_shock")
p = plot_irf(sr_nk)
```
