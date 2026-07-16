"""
    KeenModel <: AbstractMacroModel

Keen モデル（Grasselli & Costa Lima 2012 定式化）。賃金シェア・雇用率・民間債務比率の
3変数連続時間 ODE 系による Minsky 系金融不安定性モデル。

## 状態変数（連続時間, 年率）
- `ω` : 賃金シェア `wL/Y`（想定域: `0 < ω < 1` 近傍。崩壊経路では 0 へ）
- `λ` : 雇用率 `L/N`（想定域: `0 < λ < 1`。`λ = 1` で Phillips 曲線が発散）
- `d` : 民間債務比率 `D/Y`（想定域: `d ≥ 0` 近傍。崩壊経路では発散）

## パラメータ（デフォルトは Grasselli & Costa Lima (2012) の数値例）
- `α`  : 労働生産性成長率（デフォルト 0.025）
- `β`  : 労働人口成長率（デフォルト 0.02）
- `δ`  : 資本減耗率（デフォルト 0.01）
- `ν`  : 資本産出比率（デフォルト 3.0）
- `r`  : 貸出金利（実質・一定、デフォルト 0.03）
- `φ0` : Phillips曲線の定数項（デフォルト 0.0400641、Keen 1995）
- `φ1` : Phillips曲線の感応度（デフォルト 6.41e-5）
- `κ0` : 投資関数の定数項（デフォルト -0.0065）
- `κ1` : 投資関数のスケール（デフォルト exp(-5) ≈ 0.00674）
- `κ2` : 投資関数の利潤感応度（デフォルト 20.0）

## モデル方程式

```
ω' = ω [Φ(λ) - α]
λ' = λ [κ(π)/ν - δ - α - β]
d' = κ(π) - π - d [κ(π)/ν - δ]

Φ(λ) = φ1 / (1 - λ)^2 - φ0     （Phillips 曲線）
κ(π) = κ0 + κ1 exp(κ2 π)       （投資関数）
π    = 1 - ω - r d              （利潤シェア、派生変数）
```

## 均衡

閉鎖経済・政府部門なし・物価と名目金利は固定（実質モデル）の決定論的 ODE であり、
双安定性を持つ（良い均衡と、`ω → 0, λ → 0, d → ∞` の崩壊経路である悪い均衡）。
`steady_state` は**良い均衡のみ**を閉形式で返す。悪い均衡は座標が無限遠にあるため対象外。

## 出典
Grasselli, M. R., & Costa Lima, B. (2012). An analysis of the Keen model for credit
expansion, asset price bubbles and financial fragility. Mathematics and Financial
Economics, 6(3), 191-210.
"""
struct KeenModel <: AbstractMacroModel
    α::Float64
    β::Float64
    δ::Float64
    ν::Float64
    r::Float64
    φ0::Float64
    φ1::Float64
    κ0::Float64
    κ1::Float64
    κ2::Float64
end

model_name(::KeenModel) = "Keen Model"
state_variables(::KeenModel) = [:ω, :λ, :d]
control_variables(::KeenModel) = Symbol[]
parameters(m::KeenModel) = (
    α = m.α,
    β = m.β,
    δ = m.δ,
    ν = m.ν,
    r = m.r,
    φ0 = m.φ0,
    φ1 = m.φ1,
    κ0 = m.κ0,
    κ1 = m.κ1,
    κ2 = m.κ2,
)

"""
    keen_rhs(m::KeenModel, ω::Float64, λ::Float64, d::Float64) -> (dω, dλ, dd)

Keen モデルの ODE 右辺 `(ω', λ', d')` を状態 `(ω, λ, d)` から計算する。

Phillips 曲線 `Φ(λ) = φ1 / (1 - λ)^2 - φ0` と投資関数 `κ(π) = κ0 + κ1 exp(κ2 π)` を
内部で評価する（`π = 1 - ω - r d`）。
"""
function keen_rhs(m::KeenModel, ω::Float64, λ::Float64, d::Float64)
    π = 1 - ω - m.r * d
    κ_π = m.κ0 + m.κ1 * exp(m.κ2 * π)
    Φ_λ = m.φ1 / (1 - λ)^2 - m.φ0
    g = κ_π / m.ν - m.δ

    dω = ω * (Φ_λ - m.α)
    dλ = λ * (g - m.α - m.β)
    dd = κ_π - π - d * g

    return dω, dλ, dd
end

"""
    steady_state(m::KeenModel) -> NamedTuple

Keen モデルの**良い均衡** `(ω, λ, d, π, g)` を閉形式で返す。

```
π̄ = ln((ν(α + β + δ) - κ0) / κ1) / κ2      （κ(π̄) = ν(α + β + δ) を逆算）
λ̄ = 1 - sqrt(φ1 / (α + φ0))                 （Φ(λ̄) = α を逆算）
d̄ = (κ(π̄) - π̄) / (α + β)
ω̄ = 1 - π̄ - r d̄
ḡ = α + β
```

悪い均衡（`ω → 0, λ → 0, d → ∞` の崩壊経路）は座標が無限遠にあるため対象外。
"""
function steady_state(m::KeenModel)
    α, β, δ, ν, r = m.α, m.β, m.δ, m.ν, m.r
    φ0, φ1, κ0, κ1, κ2 = m.φ0, m.φ1, m.κ0, m.κ1, m.κ2

    κ_target = ν * (α + β + δ)
    π = log((κ_target - κ0) / κ1) / κ2
    λ = 1 - sqrt(φ1 / (α + φ0))
    d = (κ_target - π) / (α + β)
    ω = 1 - π - r * d
    g = α + β

    (ω = ω, λ = λ, d = d, π = π, g = g)
end
