# DME — Dynamic Macroeconomic Models in Julia

動学的マクロ経済モデルを Julia で実装したパッケージです。

## モデル一覧

| モデル | 概要 |
|---|---|
| **Ramsey モデル** | 無限期間最適成長モデル。価値反復法と完全予見経路の計算をサポート |
| **RBC モデル** | リアル・ビジネス・サイクルモデル。線形化（Blanchard-Kahn 法）によるインパルス応答計算をサポート |
| **Solow モデル** | 外生的貯蓄率による長期成長モデル。解析的定常状態と収束経路の計算をサポート |

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

### Solow モデル

```julia
using DME

m = SolowModel(0.3, 0.2, 0.1, 0.01, 0.02)  # α, s, δ, n, g

# 定常状態（解析解: 効率労働単位あたり）
ep = steady_state(m)
ep.k  # 定常資本
ep.y  # 定常産出
ep.c  # 定常消費

# 収束経路（k0 から定常状態へ T=100 期の前向き反復）
path = transition_path(m, ep.k / 2; T=100)
path.k    # 資本系列
path.y    # 産出系列
path.c    # 消費系列
path.inv  # 投資系列

# SimulationResult に変換してプロット
sr = to_simulation_result(m, path, "convergence")
p = plot_result(sr; vars=["k", "y", "c"], title="Solow 収束経路")
```

### プロット

`SimulationResult` を直接プロットできます。

```julia
using DME

m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)
sr = to_simulation_result(m, simulate(m, ep.K / 2), "simulate")

# すべての変数をプロット
p = plot_result(sr)

# 特定の変数を指定してプロット
p = plot_result(sr; vars = ["K", "C"], title = "Ramsey 移行経路")

# Symbol でも指定可能
p = plot_result(sr; vars = :K, xlabel = "Period", ylabel = "Capital")
```

存在しない変数を指定すると、利用可能な変数名を含むエラーが返ります。

```julia
plot_result(sr; vars = "Z")
# ArgumentError: 次の変数が見つかりません: Z. 利用可能な変数: C, K
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

## サンプルスクリプト

`examples/` ディレクトリにモデルの使い方を示すサンプルスクリプトがあります。

| スクリプト | 内容 |
|---|---|
| [examples/growth_models.jl](examples/growth_models.jl) | Ramsey / RBC / Solow の比較デモ。定常状態・移行経路・IRF・プロット API の使い方を示す。 |
| [examples/policy_analysis.jl](examples/policy_analysis.jl) | IS-LM / AD-AS / New Keynesian の短期政策分析デモ。財政・金融・需要・供給ショックの比較と各モデルの使い分けを示す。 |

```bash
julia --project=. examples/growth_models.jl
julia --project=. examples/policy_analysis.jl
```

## テスト

```bash
julia --project=. -e "using Pkg; Pkg.test()"
```

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [モデル選択ガイド](docs/model_selection_guide.md) | 問い・現象からモデルを選ぶためのリファレンス。比較表・決定木・各モデルの限界 |
| [API リファレンス](docs/api.md) | Public/Internal API の一覧・シグネチャ・移行ガイド |
| [モデル共通インターフェース](docs/architecture/model_interface.md) | 抽象型階層・命名方針・新規モデル追加ルール |
| [パッケージ構成とアーキテクチャ概要](docs/architecture/package_structure.md) | ソースツリー・include 順序・Node 型階層・補間・モデル内部関数 |
| [AIエコノミスト化アーキテクチャ](docs/architecture/ai_economist.md) | Phase 3 以降の層構成・データフロー・設計方針 |
| [Ramsey モデル解説](docs/models/ramsey.md) | Ramsey 最適成長モデルの目的・変数・パラメータ・出力・限界 |
| [RBC モデル解説](docs/models/rbc.md) | リアル・ビジネス・サイクルモデルの目的・変数・パラメータ・IRF・限界 |
| [出力結果の読み方](docs/simulation_outputs.md) | 定常状態・移行経路・IRF・水準/対数偏差の概念と Ramsey/RBC の出力例 |
| [品質チェックとローカル検証手順](docs/development/quality_checks.md) | Aqua.jl・JuliaFormatter・テスト実行方法・フォーマット確認 |
| [依存パッケージ管理と注意点](docs/development/dependency_management.md) | JuMP・Interpolations・NLsolve の注意点・Manifest.toml 管理 |
| [モデル解説テンプレート](docs/models/template.md) | 新規モデルの解説ドキュメントを作成する際のテンプレート |

## 開発ロードマップ

| Phase | 状態 | 内容 |
|---|---|---|
| Phase 1 | 完了 | Public/Internal API の分離 |
| Phase 2 | 進行中 | ドキュメント整備・`@deprecated` マーク追加 |
| Phase 3 | 予定 | 旧 Internal API（`calc_ep` 等）の削除 |

詳細は [API リファレンス](docs/api.md) を参照。
