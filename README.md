# DME — Dynamic Macroeconomic Models in Julia

動学的マクロ経済モデルを Julia で実装したパッケージです。
[rhasumi/dynamicmodels](https://github.com/rhasumi/dynamicmodels) の R 実装を参考に Julia へ移植しています。

## モデル一覧

| モデル | 概要 |
|---|---|
| **Ramsey モデル** | 無限期間最適成長モデル。価値反復法と完全予見経路の計算をサポート |
| **RBC モデル** | リアル・ビジネス・サイクルモデル。線形化（Blanchard-Kahn 法）によるインパルス応答計算をサポート |

## セットアップ

Julia 1.x が必要です。

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

## 使い方

### Ramsey モデル

```julia
using DME

m = RamseyModel(0.3, 0.99, 0.25)  # α, β, δ

# 定常状態
K_star, C_star = calc_ep(m)

# 完全予見経路（K0 から定常状態への移行）
path = find_path(m, K_star / 2)
path.K  # 資本系列
path.C  # 消費系列

# 価値反復法でポリシー関数を求め、シミュレーション
result = simulate_by_nlvar(m, K_star / 2)
```

### RBC モデル

```julia
using DME

m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)  # α, β, γ, δ, μ, ρ

# 定常状態 (A*, r*, w*, L*, K*, Y*, C*)
ep = calc_ep(m)

# 完全予見経路
path = find_path(m, 1.0, ep[5])  # A0, K0

# 線形化モデルでインパルス応答
irf = shock(m, 0.01)  # 技術ショック ε₀ = 0.01
irf["ĉ"]  # 消費の対数偏差
irf["k̂"]  # 資本の対数偏差
```

## テスト

```bash
julia --project=. -e "using Pkg; Pkg.test()"
```

## パラメータ説明

### RamseyModel(α, β, δ)

| パラメータ | 意味 |
|---|---|
| α | 資本分配率 |
| β | 割引因子 |
| δ | 資本減耗率 |

### RBCModel(α, β, γ, δ, μ, ρ)

| パラメータ | 意味 |
|---|---|
| α | 資本分配率 |
| β | 割引因子 |
| γ | 労働の逆弾力性（フリッシュ弾力性の逆数） |
| δ | 資本減耗率 |
| μ | 労働不効用パラメータ |
| ρ | 技術ショックの持続性 |
