# 簡易 VAR モデル

## 目的

VAR（Vector Autoregression）モデルは、複数の経済変数の動学を線形回帰によって記述するデータ駆動型のモデルです。

本実装（`VARModel`）は **係数行列を手入力する簡易 VAR(1)** として提供します。これにより、Ramsey・RBC などの理論モデルとは異なるアプローチで、複数変数の線形動学シミュレーションと簡易 IRF を扱えます。

実データからの係数推定（OLS/Bayesian VAR）は将来対応予定です。詳細は [非対象項目](#非対象項目) を参照してください。

## 変数

`VARModel` では変数名を任意に設定できます。コンストラクタ引数 `var_names` で指定してください。

```julia
# GDP (y) とインフレ率 (π) の例
var_names = [:y, :π]
```

## モデルの構造

VAR(1) は以下の方程式で記述されます。

```
y_t = c + A * y_{t-1}
```

| 記号 | 型 | 説明 |
|------|-----|------|
| `y_t` | `Vector{Float64}` (長さ n) | t 期の内生変数ベクトル |
| `c`   | `Vector{Float64}` (長さ n) | 定数項ベクトル |
| `A`   | `Matrix{Float64}` (n×n) | 係数行列（ラグ係数） |

現在の実装は **1 期ラグのみ** に対応しています。高次ラグへの対応は将来 Issue にて実施予定です。

## パラメータ

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `var_names` | `Vector{Symbol}` | 変数名リスト（長さ n） |
| `A` | `Matrix{Float64}` (n×n) | 係数行列 |
| `c` | `Vector{Float64}` (長さ n) | 定数項ベクトル |

## 定常状態

VAR(1) の定常状態 `y*` は以下の固定点方程式の解です。

```
y* = c + A * y*
(I - A) * y* = c
y* = (I - A)^{-1} * c
```

`(I - A)` が正則であること（すべての固有値が 1 でないこと）が必要です。
VAR が**定常**（`A` の spectral radius が 1 未満）の場合に一意の定常状態が存在します。

## 出力

### `steady_state`

変数名をキーとする NamedTuple（各値は `Float64`）を返します。

```julia
ss = steady_state(m)
# ss.y → y の定常値
# ss.π → π の定常値
```

### `simulate`

t=0（初期値）から t=T までの T+1 期間の経路を返します。

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `(var_names[i])` | `Vector{Float64}` (長さ T+1) | 各変数の時系列（t=0 を含む） |

```julia
path = simulate(m, y0; T = 40)
# path.y → y の経路（長さ 41）
# path.π → π の経路（長さ 41）
```

### `impulse_response`

t=1 でのショックに対する定常状態からの乖離を T 期間返します。

IRF の計算式：
```
irf[1] = shock
irf[t] = A^(t-1) * shock
```

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `(var_names[i])` | `Vector{Float64}` (長さ T) | 各変数の IRF（水準偏差） |

```julia
irf = impulse_response(m, shock; T = 20)
# irf.y[1] → y の衝撃時の応答（= shock[1]）
# irf.π[2] → π の 1 期後の応答（= A[2,:] * shock）
```

## 基本的な使い方

```julia
using DME

# 2変数 VAR(1): GDP (y) とインフレ率 (π)
var_names = [:y, :π]
A = [0.8 0.1; 0.2 0.7]   # 係数行列
c = [0.5, 0.3]            # 定数項

m = VARModel(var_names, A, c)

# 定常状態
ss = steady_state(m)
println("y* = ", ss.y)   # ≈ 4.5
println("π* = ", ss.π)   # ≈ 4.0

# 初期値からのシミュレーション
y0 = [1.0, 0.5]
path = simulate(m, y0; T = 40)
sr_sim = to_simulation_result(m, path, "from_y0")
p_sim = plot_result(sr_sim; title = "VAR シミュレーション")

# y への1単位ショックに対する IRF
shock = [1.0, 0.0]
irf = impulse_response(m, shock; T = 20)
sr_irf = to_simulation_result(m, irf, "irf_y_shock")
p_irf = plot_irf(sr_irf; title = "VAR IRF（y ショック）")
```

## 係数行列の解釈

```
A = [a11 a12]   →   y_t = c1 + a11*y_{t-1} + a12*π_{t-1}
    [a21 a22]       π_t = c2 + a21*y_{t-1} + a22*π_{t-1}
```

- 対角要素 `a11`, `a22`: 各変数の自己回帰係数（持続性）
- 非対角要素 `a12`, `a21`: 変数間の交差ラグ係数（スピルオーバー効果）

VAR が定常であるためには `A` の固有値がすべて単位円の内側にある必要があります（spectral radius < 1）。

## 他モデルとの比較

| 項目 | IS-LM | AD-AS | New Keynesian | VAR |
|------|-------|-------|---------------|-----|
| 時間軸 | 静学 | 静学 | 動学 | 動学 |
| 変数数 | 固定 (2) | 固定 (2) | 固定 (3) | 任意 (n) |
| 係数の根拠 | 経済理論 | 経済理論 | 経済理論（線形化） | 手入力 or 実データ推定 |
| 期待 | なし | 適応的 | 合理的（前向き） | なし |
| 主な用途 | 政策分析（静学） | 価格・産出分析 | 金融政策分析 | 動学分析・予測 |

## 限界と非対象項目

本実装は簡易 VAR です。以下の項目は対象外です。

### ラグ次数

- 現在の実装は **1 期ラグのみ** に対応
- VAR(p)（p > 1）への対応は将来 Issue にて実施予定

### 係数推定

- **実データからの係数推定は対象外**
- OLS による推定、ベイズ VAR（BVAR）などは将来対応予定
- 現在は係数行列 `A` と定数項 `c` をユーザーが手入力する

### 識別・構造分析

- SVAR（構造 VAR）識別は対象外
- Cholesky 分解による構造ショック識別は対象外
- 歴史的分解・予測誤差分散分解は対象外

### その他

- IRF の信頼区間（confidence band）は対象外
- ラグ次数選択（AIC/BIC など）は対象外
- Granger 因果性検定は対象外
- 共和分・誤差修正モデル（VECM）は対象外
