"""
    SolowModel <: AbstractMacroModel

Solow成長モデル。効率労働単位あたりの変数で分析する。

## パラメータ
- `α` : 資本分配率 (0 < α < 1)
- `s` : 貯蓄率 (0 < s < 1)
- `δ` : 資本減耗率 (0 < δ < 1)
- `n` : 人口成長率 (n ≥ 0)
- `g` : 技術進歩率 (g ≥ 0)
"""
struct SolowModel <: AbstractMacroModel
    α::Float64
    s::Float64
    δ::Float64
    n::Float64
    g::Float64
end

model_name(::SolowModel) = "Solow Model"
state_variables(::SolowModel) = [:k]
control_variables(::SolowModel) = [:c]
parameters(m::SolowModel) = (α = m.α, s = m.s, δ = m.δ, n = m.n, g = m.g)

"""
    solow_ep(m::SolowModel) -> (k_star, y_star, c_star)

効率労働単位あたりの定常状態 (k*, y*, c*) を解析的に計算する。

定常状態条件:  k* = (s / (δ + n + g + n·g))^(1/(1-α))
"""
function solow_ep(m::SolowModel)
    α, s, δ, n, g = m.α, m.s, m.δ, m.n, m.g
    denom = δ + n + g + n * g
    k_star = (s / denom)^(1 / (1 - α))
    y_star = k_star^α
    c_star = (1 - s) * y_star
    return k_star, y_star, c_star
end

"""
    solow_next_k(m::SolowModel, k::Float64) -> Float64

効率労働単位あたり資本の1期先の値を返す（離散時間の資本蓄積方程式）。
"""
function solow_next_k(m::SolowModel, k::Float64)
    y = k^m.α
    (m.s * y + (1 - m.δ) * k) / ((1 + m.n) * (1 + m.g))
end

"""
    steady_state(m::SolowModel) -> NamedTuple

解析解に基づく定常状態を NamedTuple で返す。
"""
function steady_state(m::SolowModel)
    k, y, c = solow_ep(m)
    (k = k, y = y, c = c)
end

"""
    transition_path(m::SolowModel, k0::Float64; T::Int = 100) -> NamedTuple

初期資本 `k0` から始めて `T` 期の移行経路を前向き反復で計算する。
返り値の変数はすべて効率労働単位あたりの値。
"""
function transition_path(m::SolowModel, k0::Float64; T::Int = 100)
    k = zeros(T)
    y = zeros(T)
    c = zeros(T)
    inv = zeros(T)

    k[1] = k0
    for t in 1:T
        y[t] = k[t]^m.α
        c[t] = (1 - m.s) * y[t]
        inv[t] = m.s * y[t]
        if t < T
            k[t + 1] = solow_next_k(m, k[t])
        end
    end

    (k = k, y = y, c = c, inv = inv)
end

"""
    simulate(m::SolowModel, k0::Float64; T::Int = 100) -> NamedTuple

`transition_path` の別名。Solowモデルでは最適化なしの前向き反復で計算する。
"""
simulate(m::SolowModel, k0::Float64; T::Int = 100) = transition_path(m, k0; T = T)
