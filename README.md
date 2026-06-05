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

# 定常状態（NamedTuple で返す）
ep = steady_state(m)
ep.K  # 定常資本
ep.C  # 定常消費

# 完全予見経路（K0 から定常状態への移行）
path = transition_path(m, ep.K / 2)
path.K  # 資本系列
path.C  # 消費系列

# 価値反復法でポリシー関数を求め、シミュレーション
result = simulate(m, ep.K / 2)
result.K  # 資本系列
result.C  # 消費系列

# SimulationResult 型に変換（汎用的な後処理に便利）
sr = to_simulation_result(m, result, "simulate")
sr["K"]  # 変数系列の取得
nperiods(sr)  # 期間数
```

### RBC モデル

```julia
using DME

m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)  # α, β, γ, δ, μ, ρ

# 定常状態（NamedTuple で返す）
ep = steady_state(m)
ep.K   # 定常資本
ep.C   # 定常消費
ep.L   # 定常労働
ep.Y   # 定常産出

# 完全予見経路
path = transition_path(m, 1.0, ep.K)  # A0, K0

# インパルス応答（技術ショック ε₀ = 0.01）
irf = impulse_response(m, 0.01)
irf.ĉ  # 消費の対数偏差
irf.k̂  # 資本の対数偏差
```

### モデルメタ情報

すべてのモデルは共通のメタ情報 API を持ちます。

```julia
using DME

m = RamseyModel(0.3, 0.99, 0.25)

model_name(m)          # "Ramsey Model"
state_variables(m)     # [:K]
control_variables(m)   # [:C]
parameters(m)          # (α = 0.3, β = 0.99, δ = 0.25)
```

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [API リファレンス](docs/api.md) | Public/Internal API の一覧・シグネチャ・移行ガイド |
| [モデル共通インターフェース](docs/architecture/model_interface.md) | 抽象型階層・命名方針・新規モデル追加ルール |
| [Ramsey モデル解説](docs/models/ramsey.md) | Ramsey 最適成長モデルの目的・変数・パラメータ・出力・限界 |
| [モデル解説テンプレート](docs/models/template.md) | 新規モデルの解説ドキュメントを作成する際のテンプレート |

## テスト

```bash
julia --project=. -e "using Pkg; Pkg.test()"
```

## Public API

以下の関数・型がパッケージの公開インターフェースです。

### モデル型

| 型 | 説明 |
|---|---|
| `AbstractMacroModel` | すべてのモデルの抽象基底型 |
| `RamseyModel` | Ramsey 最適成長モデル |
| `RBCModel` | リアル・ビジネス・サイクルモデル |

### モデルメタ情報

| 関数 | 戻り値 | 説明 |
|---|---|---|
| `model_name(m)` | `String` | モデル名 |
| `state_variables(m)` | `Vector{Symbol}` | 状態変数名 |
| `control_variables(m)` | `Vector{Symbol}` | 操作変数名 |
| `parameters(m)` | `NamedTuple` | パラメータ一覧 |

### 計算 API

| 関数 | 戻り値 | 説明 |
|---|---|---|
| `steady_state(m)` | `NamedTuple` | 定常状態の計算 |
| `transition_path(m, ...)` | `NamedTuple` | 完全予見均衡経路 |
| `simulate(m, ...)` | `NamedTuple` | 動学シミュレーション |
| `impulse_response(m, shock_size)` | `NamedTuple` | インパルス応答 |

### 結果型

| 型 / 関数 | 説明 |
|---|---|
| `SimulationResult` | モデル横断的な結果コンテナ |
| `to_simulation_result(m, result, scenario)` | NamedTuple / Dict → SimulationResult への変換 |
| `variable_names(r)` | 変数名リスト |
| `nperiods(r)` | 期間数 |

### オプション型

| 型 | 説明 |
|---|---|
| `SolverOptions` | 数値計算の共通オプション |
| `ValueIterationOptions` | 価値反復法のオプション（Ramsey モデル） |

## Internal API（非エクスポート関数）

以下の関数は内部実装であり、エクスポートされていません。
将来のバージョンで変更・削除される可能性があります。
必要な場合は `DME.calc_ep(m)` のようにモジュール修飾でアクセスできます。

| 関数 | 推奨代替 |
|---|---|
| `DME.calc_ep(m)` | `steady_state(m)` |
| `DME.find_path(m, ...)` | `transition_path(m, ...)` |
| `DME.simulate_by_nlvar(m, ...)` | `simulate(m, ...)` |
| `DME.solve_by_nlvar(m; opts)` | （高度な用途：ポリシー関数の取得） |
| `DME.solve_rbc(m)` | （高度な用途：線形化行列の取得） |
| `DME.shock(m, ε)` | `impulse_response(m, ε)` |

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
