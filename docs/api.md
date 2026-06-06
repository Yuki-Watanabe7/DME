# DME API リファレンス

## Public API と Internal API の分離方針

DME では関数・型を **Public API** と **Internal API** に分類しています。

| 分類 | 定義 |
|---|---|
| **Public API** | `using DME` でエクスポートされる。後方互換性を保って維持される。 |
| **Internal API** | エクスポートされない。`DME.func()` でアクセス可能だが、将来変更・削除される可能性がある。 |

---

## Public API 一覧

### モデル型

```julia
abstract type AbstractMacroModel end
struct RamseyModel <: AbstractMacroModel  # RamseyModel(α, β, δ)
struct RBCModel    <: AbstractMacroModel  # RBCModel(α, β, γ, δ, μ, ρ)
```

### モデルメタ情報

```julia
model_name(m::AbstractMacroModel)        -> String
state_variables(m::AbstractMacroModel)   -> Vector{Symbol}
control_variables(m::AbstractMacroModel) -> Vector{Symbol}
parameters(m::AbstractMacroModel)        -> NamedTuple
```

### 計算 API

すべての計算関数は `NamedTuple` を返します。キーは変数名の `Symbol` です。

```julia
# 定常状態
steady_state(m::RamseyModel)                              -> (K, C)
steady_state(m::RBCModel)                                 -> (A, r, w, L, K, Y, C)

# 完全予見均衡経路
transition_path(m::RamseyModel, K0::Float64; maxT=30)     -> (C, K)
transition_path(m::RBCModel, A0::Float64, K0::Float64; maxT=150) -> (A, r, w, L, K, Y, C)

# 動学シミュレーション（Ramsey のみ）
simulate(m::RamseyModel, K0::Float64; maxT=30, vi_opts=ValueIterationOptions()) -> (C, K)

# インパルス応答（RBC のみ）
impulse_response(m::RBCModel, shock_size::Float64; maxT=150) -> (â, r̂, ŵ, l̂, k̂, ŷ, ĉ)
```

### 結果型

```julia
struct SimulationResult
    model_name::String
    scenario_name::String
    variables::Dict{String, Vector{Float64}}
    metadata::Dict{String, Any}
end

# コンストラクタ（metadata 省略可）
SimulationResult(model_name, scenario_name, variables)
SimulationResult(model_name, scenario_name, variables, metadata)

# NamedTuple / Dict → SimulationResult 変換
to_simulation_result(m::AbstractMacroModel, result::NamedTuple, scenario::String) -> SimulationResult
to_simulation_result(m::RBCModel, result::Dict{String, Vector{Float64}}, scenario::String) -> SimulationResult

# ユーティリティ
result["K"]              # 変数系列の取得
haskey(result, "K")      # 変数の存在確認
variable_names(result)   # 変数名リスト -> Vector{String}
nperiods(result)         # 期間数 -> Int

# サマリー抽出
summarize_result(result) -> Dict{String, Any}
```

#### `summarize_result` の戻り値構造

```julia
Dict{String, Any}(
    "model_name"    => String,   # モデル名
    "scenario_name" => String,   # シナリオ名
    "nperiods"      => Int,      # 期間数
    "variables"     => Dict{String, NamedTuple}  # 変数名 → 変数サマリー
)
```

変数サマリー (`NamedTuple`) のフィールド:

| フィールド | 型 | 説明 |
|---|---|---|
| `initial` | Float64 | 初期値（第1期） |
| `final` | Float64 | 最終値（最終期） |
| `max` | Float64 | 最大値 |
| `min` | Float64 | 最小値 |
| `range` | Float64 | 変化幅（max - min） |
| `argmax` | Int | 最大値の時点（1始まり） |
| `argmin` | Int | 最小値の時点（1始まり） |
| `peak_response` | Float64 | 絶対値最大の値（符号付き）。IRF結果で有用。 |
| `sign_reversal` | Bool | 系列が正と負の両方を取るか。IRF結果で有用。 |

**例**:

```julia
m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(m, 0.01)
sr = to_simulation_result(m, irf, "technology_shock")
summary = summarize_result(sr)

summary["model_name"]                     # "RBC Model"
summary["nperiods"]                       # 150
summary["variables"]["ŷ"].max             # ŷ の最大値
summary["variables"]["ŷ"].argmax          # ŷ が最大になる期
summary["variables"]["k̂"].sign_reversal   # 資本が符号反転するか
```

### 可視化API

```julia
# SimulationResult の変数系列を時系列プロットとして描画（水準系列向け）
plot_result(result::SimulationResult;
    vars    = nothing,   # String / Symbol 単体か配列。省略時は全変数
    title   = "モデル名 — シナリオ名",
    xlabel  = "Period",
    ylabel  = "",
    kwargs...            # Plots.jl に直接渡す追加オプション
) -> Plots.Plot

# IRF（インパルス応答）をゼロラインつきで描画（対数偏差系列向け）
plot_irf(result::SimulationResult;
    vars       = nothing,   # String / Symbol 単体か配列。省略時は全変数
    shock_size = nothing,   # 数値。タイトルに表示。metadata["shock_size"] も参照
    title      = nothing,   # 省略時: "モデル名 — シナリオ名 (IRF)"
    xlabel     = "Period",
    ylabel     = "Log deviation from steady state",
    kwargs...               # Plots.jl に直接渡す追加オプション
) -> Plots.Plot
```

`plot_result` は水準系列（`transition_path` / `simulate`）、`plot_irf` は対数偏差系列（`impulse_response`）に使用する。
`plot_irf` はゼロライン（定常状態基準）を自動描画し、x 軸はショック発生時点 t=0 始まりで表示する。

**エラー**: 存在しない変数名を指定した場合は `ArgumentError` が発生し、
利用可能な変数名を含むメッセージが表示される。

**例**:

```julia
sr = to_simulation_result(m, simulate(m, K0), "simulate")

plot_result(sr)                              # 全変数
plot_result(sr; vars = "K")                  # 単一変数（String）
plot_result(sr; vars = :K)                   # 単一変数（Symbol）
plot_result(sr; vars = ["K", "C"])           # 複数変数
plot_result(sr; vars = ["K", "C"],
            title = "Ramsey 移行経路",
            xlabel = "Period", ylabel = "Level")

# IRF プロット
m_rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(m_rbc, 0.01)
sr_irf = to_simulation_result(m_rbc, irf, "technology_shock")

plot_irf(sr_irf)                             # 全変数、ゼロラインつき
plot_irf(sr_irf; vars = ["ŷ", "ĉ", "k̂"])   # 特定変数のみ
plot_irf(sr_irf; vars = "ŷ", shock_size = 0.01)  # ショックサイズをタイトルに表示
```

### オプション型

```julia
Base.@kwdef struct SolverOptions
    horizon::Int       = 30
    max_iter::Int      = 1000
    tolerance::Float64 = 1e-8
end

Base.@kwdef struct ValueIterationOptions
    n::Int             = 20      # グリッドサイズ
    a::Float64         = 0.5     # グリッド下限
    b::Float64         = 3.0     # グリッド上限
    max_iter::Int      = 100
    tolerance::Float64 = 0.0001
    itp_type           = ITPCubic
end
```

---

## Internal API 一覧

以下はエクスポートされない内部関数です。`DME.func()` でアクセスできますが、
将来のバージョンで変更・削除される可能性があります。

| 関数 | 役割 | 推奨代替 |
|---|---|---|
| `DME.calc_ep(m)` | 定常状態の解析的計算 | `steady_state(m)` |
| `DME.find_path(m, ...)` | NLsolve による完全予見経路 | `transition_path(m, ...)` |
| `DME.simulate_by_nlvar(m, ...)` | 価値反復法+シミュレーション | `simulate(m, ...)` |
| `DME.solve_by_nlvar(m; opts)` | 価値反復法（ポリシー関数を返す） | 高度な用途専用 |
| `DME.solve_rbc(m)` | 線形化（Blanchard-Kahn 法）の行列計算 | 高度な用途専用 |
| `DME.shock(m, ε)` | インパルス応答の計算 | `impulse_response(m, ε)` |

---

## 移行ガイド

### `calc_ep` → `steady_state`

```julia
# 旧 (Internal API)
K_star, C_star = DME.calc_ep(m)

# 新 (Public API)
ep = steady_state(m)
ep.K  # K_star に相当
ep.C  # C_star に相当
```

### `find_path` → `transition_path`

```julia
# 旧 (Internal API) — Ramsey
result = DME.find_path(m, K0)
result.K  # 資本系列
result.C  # 消費系列

# 新 (Public API)
result = transition_path(m, K0)
result.K
result.C

# 旧 (Internal API) — RBC (Dict を返す)
result = DME.find_path(m, A0, K0)
result["K"]

# 新 (Public API) — RBC (NamedTuple を返す)
result = transition_path(m, A0, K0)
result.K
```

### `simulate_by_nlvar` → `simulate`

```julia
# 旧 (Internal API)
result = DME.simulate_by_nlvar(m, K0)

# 新 (Public API)
result = simulate(m, K0)
```

### `shock` → `impulse_response`

```julia
# 旧 (Internal API) — Dict を返す
irf = DME.shock(m, 0.01)
irf["ĉ"]

# 新 (Public API) — NamedTuple を返す
irf = impulse_response(m, 0.01)
irf.ĉ
```

---

## 今後のロードマップ

| Phase | 内容 |
|---|---|
| **Phase 1（現在）** | Public/Internal API の分離。旧関数は `DME.` 修飾でアクセス可能。 |
| **Phase 2** | 旧関数に `@deprecated` マークを追加。`SolverOptions` を計算APIに組み込み。 |
| **Phase 3** | 旧関数（`calc_ep`, `find_path`, `simulate_by_nlvar`, `solve_rbc`, `shock`）を削除。 |

### 新規モデル追加時のルール

新しいモデル `FooModel` を追加する際は以下を実装すること。

**必須**:
1. `struct FooModel <: AbstractMacroModel`
2. `model_name`, `state_variables`, `control_variables`, `parameters` を実装
3. `steady_state(m::FooModel) -> NamedTuple` を実装
4. テストを `test/runtests.jl` に追加

**推奨**（該当する場合）:
5. `transition_path` を実装（完全予見均衡がある場合）
6. `simulate` を実装（動学シミュレーションがある場合）
7. `impulse_response` を実装（ショック分析がある場合）

**禁止**:
- 共通関数の戻り値に `Dict` を使わない（新APIでは NamedTuple を使うこと）
- `Tuple` の位置依存参照を外部APIとして公開しない
