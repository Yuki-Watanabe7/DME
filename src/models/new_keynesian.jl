"""
    NewKeynesianModel <: AbstractMacroModel

New Keynesian 3方程式モデル。IS曲線・New Keynesian Phillips Curve (NKPC)・
Taylor rule の線形連立方程式系として定常状態とインパルス応答を計算する。

## IS曲線パラメータ
- `σ`       : 異時点間代替弾力性（σ > 0, IS曲線の傾きの逆数）
- `r_n`     : 自然実質利子率（r_n > 0）

## Phillips Curveパラメータ
- `β`       : 割引因子（0 < β < 1）
- `κ`       : NKPC傾き（κ > 0, 産出ギャップ→インフレの感応度）

## Taylor Ruleパラメータ
- `φ_π`     : インフレ反応係数（φ_π > 1: Taylor principle を満たす）
- `φ_x`     : 産出ギャップ反応係数（φ_x ≥ 0）
- `π_star`  : インフレ目標（π_star ≥ 0）

## ショック持続性パラメータ
- `ρ_x`     : 需要ショックの持続性（0 ≤ ρ_x < 1）
- `ρ_c`     : コストプッシュショックの持続性（0 ≤ ρ_c < 1）
- `ρ_m`     : 金融政策ショックの持続性（0 ≤ ρ_m < 1）
"""
struct NewKeynesianModel <: AbstractMacroModel
    σ::Float64
    r_n::Float64
    β::Float64
    κ::Float64
    φ_π::Float64
    φ_x::Float64
    π_star::Float64
    ρ_x::Float64
    ρ_c::Float64
    ρ_m::Float64
end

model_name(::NewKeynesianModel) = "New Keynesian Model"
state_variables(::NewKeynesianModel) = Symbol[]
control_variables(::NewKeynesianModel) = [:x, :π, :i]
parameters(m::NewKeynesianModel) = (
    σ = m.σ,
    r_n = m.r_n,
    β = m.β,
    κ = m.κ,
    φ_π = m.φ_π,
    φ_x = m.φ_x,
    π_star = m.π_star,
    ρ_x = m.ρ_x,
    ρ_c = m.ρ_c,
    ρ_m = m.ρ_m,
)

"""
    steady_state(m::NewKeynesianModel) -> NamedTuple

New Keynesian モデルの定常状態を返す。

すべてのショックがゼロのとき:
  x* = 0    （産出はポテンシャルに一致）
  π* = π_star（インフレは目標値）
  i* = r_n + π_star（名目利子率 = 自然実質利子率 + インフレ目標）
"""
function steady_state(m::NewKeynesianModel)
    (x = 0.0, π = m.π_star, i = m.r_n + m.π_star)
end

"""
    simulate(m::NewKeynesianModel) -> NamedTuple

定常状態を長さ1のベクトルとして返す。`to_simulation_result` との互換性のために提供する。
"""
function simulate(m::NewKeynesianModel)
    ss = steady_state(m)
    (x = [ss.x], π = [ss.π], i = [ss.i])
end

"""
    nk_msv_response(m::NewKeynesianModel, ρ::Float64, d::Vector{Float64})
        -> Vector{Float64}

Minimum State Variable (MSV) 解を求める内部関数。

モデルの行列表現（定常状態からの乖離）:

  A * [x̃_t, π̃_t]' = B * E_t[[x̃_{t+1}, π̃_{t+1}]'] + d * ε_t

  A = [[1 + φ_x/σ,  φ_π/σ],
       [-κ,          1    ]]
  B = [[1,  1/σ],
       [0,  β  ]]

AR(1) ショック ε_t = ρ * ε_{t-1} に対して MSV 解は:

  [x̃, π̃]' = (A - ρ*B)^{-1} * d * ε_t
"""
function nk_msv_response(m::NewKeynesianModel, ρ::Float64, d::Vector{Float64})
    A = [
        (1.0 + m.φ_x / m.σ) (m.φ_π / m.σ);
        (-m.κ) 1.0
    ]
    B = [
        1.0 (1.0 / m.σ);
        0.0 m.β
    ]
    M = A - ρ .* B
    return M \ d
end

"""
    impulse_response(m::NewKeynesianModel, shock_size::Float64 = 1.0;
                     shock::Symbol = :demand, T::Int = 20) -> NamedTuple

指定したショックに対するインパルス応答関数 (IRF) を計算する。

返り値はすべて**定常状態からの乖離**:
- `x[t]` : t 期の産出ギャップ（定常状態 x*=0 からの乖離）
- `π[t]` : t 期のインフレ率（インフレ目標 π_star からの乖離）
- `i[t]` : t 期の名目利子率（定常状態 i*=r_n+π_star からの乖離）

## ショックの種類（`shock` キーワード）

| シンボル       | 意味                                      |
|---------------|-------------------------------------------|
| `:demand`     | 需要ショック（IS曲線への正のショック）       |
| `:cost_push`  | コストプッシュショック（NKPC への正のショック）|
| `:monetary`   | 金融政策ショック（Taylor rule の正のショック、予期せぬ利上げ）|

## MSV 解法

ショック ε_t = shock_size * ρ^(t-1) に対して:

  [x̃_t, π̃_t]' = (A - ρ*B)^{-1} * d * ε_t
  ĩ_t = φ_π * π̃_t + φ_x * x̃_t [+ ε_t（金融政策ショックのみ）]
"""
function impulse_response(
    m::NewKeynesianModel,
    shock_size::Float64 = 1.0;
    shock::Symbol = :demand,
    T::Int = 20,
)
    if shock === :demand
        ρ = m.ρ_x
        d = [1.0, 0.0]
        is_monetary = false
    elseif shock === :cost_push
        ρ = m.ρ_c
        d = [0.0, 1.0]
        is_monetary = false
    elseif shock === :monetary
        ρ = m.ρ_m
        d = [-1.0 / m.σ, 0.0]
        is_monetary = true
    else
        throw(
            ArgumentError(
                "不明なショック種別: $(shock)。:demand, :cost_push, :monetary のいずれかを指定してください。",
            ),
        )
    end

    Ψ = nk_msv_response(m, ρ, d)

    x_irf = Vector{Float64}(undef, T)
    π_irf = Vector{Float64}(undef, T)
    i_irf = Vector{Float64}(undef, T)

    for t in 1:T
        ε_t = shock_size * ρ^(t - 1)
        x_irf[t] = Ψ[1] * ε_t
        π_irf[t] = Ψ[2] * ε_t
        i_irf[t] = m.φ_π * π_irf[t] + m.φ_x * x_irf[t]
        if is_monetary
            i_irf[t] += ε_t
        end
    end

    (x = x_irf, π = π_irf, i = i_irf)
end

"""
    nk_irf_compare(m_base, m_alt; shock, shock_size, T, scenario_names)
        -> SimulationResult

2つのパラメータ設定のIRFを比較する SimulationResult を返す。

Taylor ruleパラメータ（φ_π, φ_x）の変更が経済変数の応答に与える影響を
可視化・定量化するために使用する。

変数名は `"x_base"`, `"π_base"`, `"i_base"`, `"x_alt"`, `"π_alt"`, `"i_alt"` の形式。

## 例

```julia
m_base = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)
m_hawk = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 2.0, 0.5, 0.02, 0.8, 0.5, 0.5)
result = DME.nk_irf_compare(m_base, m_hawk; shock=:cost_push)
```
"""
function nk_irf_compare(
    m_base::NewKeynesianModel,
    m_alt::NewKeynesianModel;
    shock::Symbol = :demand,
    shock_size::Float64 = 1.0,
    T::Int = 20,
    scenario_names::Tuple{String, String} = ("baseline", "alternative"),
)
    irf_base = impulse_response(m_base, shock_size; shock = shock, T = T)
    irf_alt = impulse_response(m_alt, shock_size; shock = shock, T = T)

    vars = Dict{String, Vector{Float64}}(
        "x_base" => irf_base.x,
        "π_base" => irf_base.π,
        "i_base" => irf_base.i,
        "x_alt" => irf_alt.x,
        "π_alt" => irf_alt.π,
        "i_alt" => irf_alt.i,
    )
    meta = Dict{String, Any}(
        "scenario_names" => collect(scenario_names),
        "shock" => String(shock),
        "shock_size" => shock_size,
        "parameters_base" => parameters(m_base),
        "parameters_alt" => parameters(m_alt),
    )
    SimulationResult("New Keynesian Model", "irf_comparison", vars, meta)
end
