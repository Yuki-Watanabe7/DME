# モデル共通インターフェース設計方針

> Phase 1 / P0  
> 対象ブランチ: `main`  
> 関連Issue: #4

---

## 1. 背景と目的

現在の DME パッケージは `RamseyModel` と `RBCModel` を独立した `struct` として実装している。
関数名（`calc_ep`, `find_path` など）は共通しているものの、戻り値の型・シグネチャ・メタ情報の扱いはモデルごとに異なる。

今後 Solow・New Keynesian・VAR/SVAR などを追加する前に、**モデル追加時の共通ルール**を定める。

---

## 2. 現状の整理

### 2.1 既存モデルと関数一覧

| 関数 | `RamseyModel` | `RBCModel` | 戻り値の型 |
|---|---|---|---|
| `calc_ep` | ✅ | ✅ | Ramsey: `Tuple{Float64,Float64}` / RBC: `Tuple{Float64,...}` (7要素) |
| `find_path` | ✅ | ✅ | Ramsey: `NamedTuple (C, K)` / RBC: `Dict{String, Vector{Float64}}` |
| `simulate_by_nlvar` | ✅ | ❌ | `NamedTuple (C, K)` |
| `solve_by_nlvar` | ✅ | ❌ | Policy function (closure) |
| `solve_rbc` | ❌ | ✅ | `Tuple{Matrix{Float64}, Matrix{Float64}}` |
| `shock` | ❌ | ✅ | `Dict{String, Vector{Float64}}` |

### 2.2 課題

- **抽象型なし**: モデルをまとめて扱う型がなく、可視化・LLM接続で分岐が増える
- **戻り値の不一致**: `find_path` が Ramsey は NamedTuple、RBC は Dict を返す
- **メタ情報なし**: モデル名・変数一覧・パラメータ一覧を取得する方法がない
- **関数名の揺れ**: `simulate_by_nlvar` / `shock` は役割が類似するが名前が異なる

---

## 3. 抽象型階層

### 3.1 導入する型

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

struct RBCModel <: AbstractMacroModel
    α::Float64
    β::Float64
    γ::Float64
    δ::Float64
    μ::Float64
    ρ::Float64
end
```

型の追加を避け、Phase 1 では `AbstractMacroModel` の一層のみとする。
将来的に `AbstractDSGEModel <: AbstractMacroModel` 等を追加することは妨げない。

---

## 4. 共通関数の命名方針

### 4.1 推奨命名と既存関数の対応

| 新しい推奨名 | 既存の関数名 | 役割 |
|---|---|---|
| `steady_state` | `calc_ep` | 定常状態の解析的計算 |
| `transition_path` | `find_path` | 完全予見均衡経路（NLsolve） |
| `simulate` | `simulate_by_nlvar` | 初期値からの動学シミュレーション |
| `impulse_response` | `shock` | インパルス応答関数 |
| `solve` (モデル固有) | `solve_rbc` / `solve_by_nlvar` | 線形化・価値反復など求解処理 |

### 4.2 共通関数の最低限シグネチャ

新規モデル追加時に実装が**必須**なのは `steady_state` のみ。
その他は該当するモデルにのみ実装する。

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

### 4.3 戻り値の型方針

**新しい共通関数はすべて `NamedTuple` を返す**。キーには変数名の `Symbol` を使用する。

```julia
# steady_state の戻り値例
steady_state(RamseyModel(0.3, 0.99, 0.25))
# -> (K = 1.226..., C = 0.756...)

steady_state(RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9))
# -> (A = 1.0, r = 0.0351, w = 1.7557, L = 0.6672, K = 14.301, Y = 1.6733, C = 1.3158)
```

`Dict` は廃止予定。`Tuple` の位置依存参照も新しいAPIでは使わない。

---

## 5. モデルメタ情報

可視化・LLM要約・実データ接続で共通して必要になるメタ情報を関数として提供する。

### 5.1 関数シグネチャ

```julia
model_name(m::AbstractMacroModel)         -> String
state_variables(m::AbstractMacroModel)    -> Vector{Symbol}
control_variables(m::AbstractMacroModel)  -> Vector{Symbol}
parameters(m::AbstractMacroModel)         -> NamedTuple
```

### 5.2 既存モデルへの実装例

```julia
model_name(::RamseyModel) = "Ramsey Model"
state_variables(::RamseyModel) = [:K]
control_variables(::RamseyModel) = [:C]
parameters(m::RamseyModel) = (α = m.α, β = m.β, δ = m.δ)

model_name(::RBCModel) = "RBC Model"
state_variables(::RBCModel) = [:K, :A]
control_variables(::RBCModel) = [:C, :L, :Y, :r, :w]
parameters(m::RBCModel) = (α = m.α, β = m.β, γ = m.γ, δ = m.δ, μ = m.μ, ρ = m.ρ)
```

---

## 6. 既存APIとの関係・移行方針

既存のAPIは**即座には破壊しない**。以下の方針で段階的に移行する。

### Phase 1（本 Issue の実装範囲）

- `AbstractMacroModel` 型を導入し、既存モデルに継承させる
- メタ情報関数（`model_name`, `state_variables`, `control_variables`, `parameters`）を追加
- `steady_state`, `transition_path`, `simulate`, `impulse_response` を**既存関数のラッパー**として実装する
- 既存の `calc_ep`, `find_path`, `simulate_by_nlvar`, `shock` はそのまま残す

```julia
# 例: ラッパーの実装方針
steady_state(m::RamseyModel) = (K = calc_ep(m)[1], C = calc_ep(m)[2])
```

### Phase 2（後続 Issue）

- `SimulationResult` 型の導入（`transition_path`, `simulate`, `impulse_response` の戻り値を統一）
- `SolverOptions` 型の導入（数値計算パラメータを分離）
- 旧関数を `@deprecated` でマーク

### Phase 3（将来）

- 旧関数（`calc_ep`, `find_path`, `simulate_by_nlvar`, `shock`）を削除

---

## 7. 可視化・LLM要約・実データ接続のAPI境界

### 7.1 可視化（Phase 2 以降）

共通関数が `NamedTuple` を返すため、呼び出し側は変数名を使ってプロットできる。
`SimulationResult` 型導入後に汎用プロット関数を追加する。

```julia
# 将来のAPI案
plot_result(result, vars=[:K, :C]; title="") -> Plots.Plot
```

### 7.2 LLM要約（Phase 2 以降）

メタ情報関数を使えば、モデルの説明文を自動生成できる。

```julia
# 将来のAPI案
describe(m::AbstractMacroModel) -> String
summarize_result(result::NamedTuple, m::AbstractMacroModel) -> String
```

### 7.3 実データ接続（Phase 3 以降）

```julia
# 将来のAPI案
calibrate(m::AbstractMacroModel, data; target_vars=[]) -> AbstractMacroModel
```

---

## 8. ファイル構成案

### 現状

```
src/
  DME.jl
  util.jl
  ramsey.jl
  RBC.jl
```

### Phase 1 後（本 Issue の成果物）

```
src/
  DME.jl          ← interface.jl の include・export を追加
  util.jl
  interface.jl    ← AbstractMacroModel と共通関数シグネチャ（新規）
  ramsey.jl       ← struct に `<: AbstractMacroModel` を追加
  RBC.jl          ← struct に `<: AbstractMacroModel` を追加
docs/
  architecture/
    model_interface.md  ← 本ドキュメント
```

### Phase 1-G 以降（ファイル構成整理 Issue）

```
src/
  DME.jl
  util.jl
  interface.jl
  models/
    ramsey.jl
    rbc.jl
  solvers/        ← SolverOptions 等（Phase 2以降）
```

---

## 9. 新規モデル追加時の最低限のI/F

新しいモデル `FooModel` を追加する際は以下を守ること。

### 必須

1. `struct FooModel <: AbstractMacroModel` を定義する
2. `model_name`, `state_variables`, `control_variables`, `parameters` を実装する
3. `steady_state(m::FooModel) -> NamedTuple` を実装する
4. テストを `test/runtests.jl` の `@testset "FooModel"` ブロックに追加する

### 推奨（該当する場合）

5. `transition_path` を実装する（完全予見均衡が存在する場合）
6. `simulate` を実装する（動学シミュレーションが可能な場合）
7. `impulse_response` を実装する（ショック分析が可能な場合）

### 禁止

- `Dict` を共通関数の戻り値に使わない
- `Tuple` の位置依存参照を外部APIとして公開しない

---

## 10. 後続Issueタスク分解

| Issue | タイトル | 依存 | 優先度 |
|---|---|---|---|
| Phase 1-A | `AbstractMacroModel` の実装と既存モデルへの適用 | 本 Issue | P0 |
| Phase 1-B | `steady_state` / `transition_path` の実装（ラッパー） | Phase 1-A | P0 |
| Phase 1-C | `simulate` / `impulse_response` の実装（ラッパー） | Phase 1-A | P1 |
| Phase 1-D | メタ情報関数の実装 | Phase 1-A | P1 |
| Phase 1-E | `SimulationResult` 型の導入 | Phase 1-B, C | P1 |
| Phase 1-F | `SolverOptions` 型の導入 | Phase 1-B, C | P1 |
| Phase 1-G | ファイル構成整理（`src/models/`, `src/solvers/`） | Phase 1-A〜F | P2 |

---

## 11. 受け入れ条件チェック

- [x] 既存2モデルを前提に、共通化すべき点とモデル固有に残す点が整理されている
- [x] 新規モデル追加時に守るべき最低限のI/Fが明文化されている（セクション9）
- [x] 既存APIをすぐ破壊しない移行方針が記載されている（セクション6）
- [x] Phase 1の後続Issue（SimulationResult、SolverOptions、ファイル構成整理）との関係が明記されている（セクション10）
