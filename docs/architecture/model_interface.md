# モデル共通インターフェース

DME の全モデルが従う抽象型階層・共通関数・命名方針・新規モデル追加ルールを定める。

> 本ドキュメントはもともと共通インターフェース導入前の設計方針メモ（Issue #4）として作成され、現在は実装済みインターフェースの規約として維持している。

---

## 1. 目的

すべてのモデルを共通の型と関数シグネチャで扱えるようにすることで、可視化・実データ比較・LLM 接続がモデルごとの分岐なしに動作する状態を保つ。新規モデルを追加する際は本ドキュメントのルールに従うこと。

---

## 2. 抽象型階層

```julia
abstract type AbstractMacroModel end
```

すべてのモデル `struct` はこの型を継承する。

```julia
struct RamseyModel <: AbstractMacroModel
    α::Float64
    β::Float64
    δ::Float64
end
```

現在の実装モデル: `RamseyModel` / `SolowModel` / `RBCModel` / `ISLMModel` / `ADASModel` / `NewKeynesianModel` / `MundellFlemingModel` / `VARModel`（`src/models/`）。

型階層は `AbstractMacroModel` の一層のみとする。将来的に `AbstractDSGEModel <: AbstractMacroModel` 等を追加することは妨げない。

---

## 3. 共通関数

### 3.1 計算 API

新規モデル追加時に実装が**必須**なのは `steady_state` のみ。その他は該当するモデルにのみ実装する。

```julia
# 必須: 定常状態の計算
steady_state(m::AbstractMacroModel) -> NamedTuple

# 任意: 完全予見均衡経路
transition_path(m::AbstractMacroModel, initial_state...; T::Int) -> NamedTuple

# 任意: 動学シミュレーション
simulate(m::AbstractMacroModel, initial_state...; T::Int) -> NamedTuple

# 任意: インパルス応答
impulse_response(m::AbstractMacroModel, shock::Float64; T::Int) -> NamedTuple
```

### 3.2 戻り値の型方針

**共通関数はすべて `NamedTuple` を返す**。キーには変数名の `Symbol` を使用する。

```julia
steady_state(RamseyModel(0.3, 0.99, 0.25))
# -> (K = 1.226..., C = 0.756...)

steady_state(RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9))
# -> (A = 1.0, r = 0.0351, w = 1.7557, L = 0.6672, K = 14.301, Y = 1.6733, C = 1.3158)
```

- `Dict` を共通関数の戻り値に使わない
- `Tuple` の位置依存参照を外部 API として公開しない
- 外部向けの後処理には `to_simulation_result` で `SimulationResult` に変換する

### 3.3 数値計算オプション

数値計算のパラメータはモデルの `struct` に含めず、`SolverOptions` / `ValueIterationOptions`（`src/core/solver_options.jl`）で受け取る。

---

## 4. モデルメタ情報

可視化・LLM要約・実データ接続で共通して必要になるメタ情報を関数として提供する。全モデルで実装必須。

```julia
model_name(m::AbstractMacroModel)         -> String
state_variables(m::AbstractMacroModel)    -> Vector{Symbol}
control_variables(m::AbstractMacroModel)  -> Vector{Symbol}
parameters(m::AbstractMacroModel)         -> NamedTuple
```

実装例:

```julia
model_name(::RamseyModel) = "Ramsey Model"
state_variables(::RamseyModel) = [:K]
control_variables(::RamseyModel) = [:C]
parameters(m::RamseyModel) = (α = m.α, β = m.β, δ = m.δ)
```

---

## 5. 旧 Internal API との対応

共通インターフェース導入前の関数は Internal API として残っており、`DME.` 修飾でアクセスできる（エクスポートされない）。

| Public API | 旧 Internal API | 役割 |
|---|---|---|
| `steady_state` | `calc_ep` | 定常状態の計算 |
| `transition_path` | `find_path` | 完全予見均衡経路（NLsolve） |
| `simulate` | `simulate_by_nlvar` | 初期値からの動学シミュレーション |
| `impulse_response` | `shock` | インパルス応答関数 |
| （モデル固有） | `solve_rbc` / `solve_by_nlvar` | 線形化・価値反復など求解処理 |

移行状況の詳細は [API リファレンス](../api.md) の「旧 Internal API の移行状況」を参照。

---

## 6. 新規モデル追加時の最低限のI/F

新しいモデル `FooModel` を追加する際は以下を守ること。

### 必須

1. `struct FooModel <: AbstractMacroModel` を定義する（`src/models/foo.jl`）
2. `model_name`, `state_variables`, `control_variables`, `parameters` を実装する
3. `steady_state(m::FooModel) -> NamedTuple` を実装する
4. テストを `test/test_foo.jl` に追加し `test/runtests.jl` から include する
5. モデル解説ドキュメントを `docs/models/foo.md` に作成する（[テンプレート](../models/template.md)）

### 推奨（該当する場合）

6. `transition_path` を実装する（完全予見均衡が存在する場合）
7. `simulate` を実装する（動学シミュレーションが可能な場合）
8. `impulse_response` を実装する（ショック分析が可能な場合）

### 禁止

- `Dict` を共通関数の戻り値に使わない
- `Tuple` の位置依存参照を外部APIとして公開しない
- モデル層からのデータ取得・可視化・LLM 呼び出し（[層の境界](ai_economist.md)を参照）
