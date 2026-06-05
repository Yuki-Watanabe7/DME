struct RBCModel <: AbstractMacroModel
    α::Float64
    β::Float64
    γ::Float64
    δ::Float64
    μ::Float64
    ρ::Float64
end

model_name(::RBCModel) = "RBC Model"
state_variables(::RBCModel) = [:K, :A]
control_variables(::RBCModel) = [:C, :L, :Y, :r, :w]
parameters(m::RBCModel) = (α = m.α, β = m.β, γ = m.γ, δ = m.δ, μ = m.μ, ρ = m.ρ)

function steady_state(m::RBCModel)
    A, r, w, L, K, Y, C = calc_ep(m)
    (A = A, r = r, w = w, L = L, K = K, Y = Y, C = C)
end

function transition_path(m::RBCModel, A0::Float64, K0::Float64; maxT::Int = 150)
    d = find_path(m, A0, K0; maxT = maxT)
    (A = d["A"], r = d["r"], w = d["w"], L = d["L"], K = d["K"], Y = d["Y"], C = d["C"])
end

function impulse_response(m::RBCModel, shock_size::Float64; maxT::Int = 150)
    d = shock(m, shock_size; maxT = maxT)
    (
        â = d["â"],
        r̂ = d["r̂"],
        ŵ = d["ŵ"],
        l̂ = d["l̂"],
        k̂ = d["k̂"],
        ŷ = d["ŷ"],
        ĉ = d["ĉ"],
    )
end

function U(m::RBCModel, C, L)
    log(C) - m.μ * L^(m.γ+1)
end

function g(m::RBCModel, K, A, C, L, ϵ)
    w = (1-m.α) * K^m.α / L^m.α * A
    r = m.α * L^(1-m.α) / K^(1-m.α) * A
    new_K = L*w + K*r + (1-m.δ)*K - C
    new_A = exp(m.ρ * log(A) + ϵ)
    (K = new_K, A = new_A)
end

function calc_ep(
    m::RBCModel,
)::Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64}
    α, β, γ, δ, μ, ρ = m.α, m.β, m.γ, m.δ, m.μ, m.ρ
    A⃰ = 1
    r⃰ = 1/β + δ - 1
    K_L = (r⃰/(A⃰*α))^(1/(α-1))
    Y_L = A⃰*K_L^α
    C_L = Y_L - δ*K_L
    w⃰ = (1-α)A⃰*K_L^α
    L⃰ = (w⃰/(γ+1)μ)^(1/(γ+1))*C_L^(-1/(γ+1))
    K⃰ = K_L * L⃰
    Y⃰ = Y_L * L⃰
    C⃰ = C_L * L⃰
    return A⃰, r⃰, w⃰, L⃰, K⃰, Y⃰, C⃰
end

function find_path(
    m::RBCModel,
    A0::Float64,
    K0::Float64;
    maxT::Int = 150,
)::Dict{String, Vector{Float64}}
    α, β, γ, δ, μ, ρ = m.α, m.β, m.γ, m.δ, m.μ, m.ρ
    A⃰, r⃰, w⃰, L⃰, K⃰, Y⃰, C⃰ = calc_ep(m)

    function f(F, X)
        a = X[1:maxT]
        pushfirst!(a, A0)
        r = X[(maxT + 1):2maxT]
        push!(r, r⃰)
        w = X[(2maxT + 1):3maxT]
        push!(w, w⃰)
        l = X[(3maxT + 1):4maxT]
        push!(l, L⃰)
        k = X[(4maxT + 1):5maxT]
        pushfirst!(k, K0)
        y = X[(5maxT + 1):6maxT]
        push!(y, Y⃰)
        c = X[(6maxT + 1):7maxT]
        push!(c, C⃰)
        for i in 1:maxT
            F[7i - 6] = -w[i]/c[i] + (γ+1)*μ*l[i]^γ
            F[7i - 5] = c[i + 1]/c[i] - β*(r[i + 1]-δ+1)
            F[7i - 4] = y[i] - a[i]*k[i]^α*l[i]^(1-α)
            F[7i - 3] = w[i] - (1-α)a[i]*k[i]^α*l[i]^(-α)
            F[7i - 2] = k[i + 1] - y[i] - (1-δ)k[i] + c[i]
            F[7i - 1] = r[i] - α*a[i]*k[i]^(α-1)*l[i]^(1-α)
            F[7i] = log(a[i + 1]) - ρ*log(a[i])
        end
    end

    ini_a = ones(maxT) * A⃰
    ini_r = ones(maxT) * r⃰
    ini_w = ones(maxT) * w⃰
    ini_l = ones(maxT) * L⃰
    ini_k = ones(maxT) * K⃰
    ini_y = ones(maxT) * Y⃰
    ini_c = ones(maxT) * C⃰
    ini_v = ini_a
    for ini in [ini_r, ini_w, ini_l, ini_k, ini_y, ini_c]
        append!(ini_v, ini)
    end
    ans = nlsolve(f, ini_v).zero
    A = ans[1:maxT]
    pushfirst!(A, A0)
    r = ans[(maxT + 1):2maxT]
    push!(r, r⃰)
    w = ans[(2maxT + 1):3maxT]
    push!(w, w⃰)
    L = ans[(3maxT + 1):4maxT]
    push!(L, L⃰)
    K = ans[(4maxT + 1):5maxT]
    pushfirst!(K, K0)
    Y = ans[(5maxT + 1):6maxT]
    push!(Y, Y⃰)
    C = ans[(6maxT + 1):7maxT]
    push!(C, C⃰)

    return Dict("A" => A, "r" => r, "w" => w, "L" => L, "K" => K, "Y" => Y, "C" => C)
end

function solve_rbc(m::RBCModel)::Tuple{Matrix{Float64}, Matrix{Float64}}
    α, β, γ, δ, μ, ρ = m.α, m.β, m.γ, m.δ, m.μ, m.ρ
    A⃰, r⃰, w⃰, L⃰, K⃰, Y⃰, C⃰ = calc_ep(m)
    B = [
        0 0 0 0 0 0 0
        1 0 0 0 -(r⃰+1)β 0 0
        0 0 0 0 0 0 0
        0 0 0 0 0 0 0
        0 0 0 0 0 0 0
        0 0 0 0 0 K⃰ 0
        0 0 0 0 0 0 1
    ]
    C = [
        1 γ 0 -1 0 0 0
        1 0 0 0 0 0 0
        0 1-α -1 0 0 α 1
        0 -α 0 -1 0 α 1
        0 1-α 0 0 -(r⃰+1)/r⃰ α-1 1
        -C⃰ 0 Y⃰ 0 0 -(δ-1)K⃰ 0
        0 0 0 0 0 0 ρ
    ]
    A = C \ B
    eig_A = eigen(A)
    λ = [(eig_A.values[i], eig_A.vectors[:, i]) for i in 1:7]
    sort!(λ, by = x -> abs(x[1]), rev = true)
    V = zeros(2, 2)
    S = zeros(7, 7)
    for i in 1:7
        if i <= 2
            V[i, i] = 1 / λ[i][1]
        end
        S[:, i] = λ[i][2]
    end
    Q = inv(S)
    Q_A = Q[3:7, 1:5]
    Q_B = Q[3:7, 6:7]
    Q_C = Q[1:2, 1:5]
    Q_D = Q[1:2, 6:7]
    P = -Q_A \ Q_B
    Q_E = Q_C * P + Q_D
    A_A = Q_E \ V * Q_E
    return A_A, P
end

function shock(m::RBCModel, ϵ0::Float64; maxT::Int = 150)
    α, β, γ, δ, μ, ρ = m.α, m.β, m.γ, m.δ, m.μ, m.ρ
    A⃰, r⃰, w⃰, L⃰, K⃰, Y⃰, C⃰ = calc_ep(m)
    A_A, P = solve_rbc(m)

    S = zeros(maxT+1, 2)
    S[1, 1:2] = [0 ϵ0]
    for i in 1:maxT
        S[i + 1, 1:2] = A_A * S[i, 1:2]
    end
    X = (P * S')'

    â = S[1:end, 2]
    r̂ = X[1:end, 5]
    ŵ = X[1:end, 4]
    l̂ = X[1:end, 2]
    k̂ = S[1:end, 1]
    ŷ = X[1:end, 3]
    ĉ = X[1:end, 1]

    return Dict("â" => â, "r̂" => r̂, "ŵ" => ŵ, "l̂" => l̂, "k̂" => k̂, "ŷ" => ŷ, "ĉ" => ĉ)
end
