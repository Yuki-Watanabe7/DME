struct RBCModel
    α::Float64
    β::Float64
    γ::Float64
    δ::Float64
    μ::Float64
    ρ::Float64
end

function U(m::RBCModel, C, L)
    log(C) - m.μ * L^(m.γ+1)
end

function g(m::RBCModel, K, A, C, L, ϵ)
    w = (1-m.α) * K^m.α / L^α * A
    r = m.α * L^(1-m.α) / K^(1-m.α) * A
    new_K = L*w + K*r + (1-m.δ)*K - C
    new_A = exp(m.ρ * log(A) + ϵ)
    (K=new_K, A=new_A)
end

function calc_ep(m::RBCModel)::Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64}
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

function find_path(m::RBCModel, A0::Float64, K0::Float64)::Dict{String, Vector{Float64}}
    α, β, γ, δ, μ, ρ = m.α, m.β, m.γ, m.δ, m.μ, m.ρ
    maxT = 150
    A⃰, r⃰, w⃰, L⃰, K⃰, Y⃰, C⃰ = calc_ep(m)

    function f(F, X)
        a = X[1:maxT]
        pushfirst!(a, A0)
        r = X[maxT+1:2maxT]
        push!(r, r⃰)
        w = X[2maxT+1:3maxT]
        push!(w, w⃰)
        l = X[3maxT+1:4maxT]
        push!(l, L⃰)
        k = X[4maxT+1:5maxT]
        pushfirst!(k, K0)
        y = X[5maxT+1:6maxT]
        push!(y, Y⃰)
        c = X[6maxT+1:7maxT]
        push!(c, C⃰)
        for i in 1:maxT
            F[7i-6] = -w[i]/c[i] + (γ+1)*μ*l[i]^γ
            F[7i-5] = c[i+1]/c[i] - β*(r[i+1]-δ+1)
            F[7i-4] = y[i] - a[i]*k[i]^α*l[i]^(1-α)
            F[7i-3] = w[i] - (1-α)a[i]*k[i]^α*l[i]^(-α)
            F[7i-2] = k[i+1] - y[i] - (1-δ)k[i] + c[i]
            F[7i-1] = r[i] - α*a[i]*k[i]^(α-1)*l[i]^(1-α)
            F[7i] = log(a[i+1]) - ρ*log(a[i])
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
    r = ans[maxT+1:2maxT]
    push!(r, r⃰)
    w = ans[2maxT+1:3maxT]
    push!(w, w⃰)
    L = ans[3maxT+1:4maxT]
    push!(L, L⃰)
    K = ans[4maxT+1:5maxT]
    pushfirst!(K, K0)
    Y = ans[5maxT+1:6maxT]
    push!(Y, Y⃰)
    C = ans[6maxT+1:7maxT]
    push!(C, C⃰)

    return Dict("A" => A, "r" => r, "w" => w, "L" => L,
                "K" => K, "Y" => Y, "C" => C)
end

function solve_rbc(m::RBCModel)::Tuple{Matrix{Float64}, Matrix{Float64}}
    α, β, γ, δ, μ, ρ = m.α, m.β, m.γ, m.δ, m.μ, m.ρ
    A⃰, r⃰, w⃰, L⃰, K⃰, Y⃰, C⃰ = calc_ep(m)
    B = [0 0 0 0 0 0 0
         1 0 0 0 -(r⃰+1)β 0 0
         0 0 0 0 0 0 0
         0 0 0 0 0 0 0
         0 0 0 0 0 0 0
         0 0 0 0 0 K⃰ 0
         0 0 0 0 0 0 1]
    C = [1 γ 0 -1 0 0 0
         1 0 0 0 0 0 0
         0 1-α -1 0 0 α 1
         0 -α 0 -1 0 α 1
         0 1-α 0 0 -(r⃰+1)/r⃰ α-1 1
         -C⃰ 0 Y⃰ 0 0 -(δ-1)K⃰ 0
         0 0 0 0 0 0 ρ]
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

function shock(m::RBCModel, ϵ0::Float64)
    α, β, γ, δ, μ, ρ = m.α, m.β, m.γ, m.δ, m.μ, m.ρ
    A⃰, r⃰, w⃰, L⃰, K⃰, Y⃰, C⃰ = calc_ep(m)
    maxT = 150
    A_A, P = solve_rbc(m)

    S = zeros(maxT+1, 2)
    S[1, 1:2] = [0 ϵ0]
    for i in 1:maxT
        S[i+1, 1:2] = A_A * S[i, 1:2]
    end
    X = (P * S')'

    â = S[1:end, 2]
    r̂ = X[1:end, 5]
    ŵ = X[1:end, 4]
    l̂ = X[1:end, 2]
    k̂ = S[1:end, 1]
    ŷ = X[1:end, 3]
    ĉ = X[1:end, 1]

    return Dict("â" => â, "r̂" => r̂, "ŵ" => ŵ, "l̂" => l̂,
                "k̂" => k̂, "ŷ" => ŷ, "ĉ" => ĉ)
end

function optimize_c(m::RBCModel, k::Float64, f, lb::Float64, ub::Float64, start::Float64)
    obj = ct -> -U(m, ct, lt) - m.β*f(g(m, k, a, ct, lt, 0)...)
    model = Model(with_optimizer(Ipopt.Optimizer, print_level=0))
    @variable(model, lb <= ct <= ub, start=start)
    register(model, :obj, 1, obj, autodiff=true)
    @NLobjective(model, Min, obj(ct))
    @NLconstraint(model, ct<=(1-m.δ)k)
    optimize!(model)
    value(ct)
end

function update_policy(m::RBCModel, node::AbstractNode, old_hc, f, ϵ::Float64, itp_type::Interpo_Type)
    ub = 0.99 * node.b
    old_cc = [old_hc(x) for x in node.node]
    new_cc = [optimize_c(m, k, f, 0.001, ub, 0.001) for k in node.node]
    @debug new_cc
    itp_param = create_itp_param(node, new_cc, itp_type)
    new_hc = s -> interpo(s, itp_param)
    (hc=new_hc, updated=is_updated(old_cc, new_cc, ϵ))
end

function V(m::RBCModel, kt::Float64, at::Float64, hc, hl)
    y = 0
    for t in 0:500
        ct = max(min(hc(kt), kt), 0.001)
        lt = hl(ct, kt, at)
        y += m.β^t * U(m, ct, lt)
        kt, at = g(m, kt, at, ct, lt, 0)
    end
    y
end

function update_value(m::RBCModel, node::AbstractNode, hc, hl, itp_type::Interpo_Type)
    v = [V(m, kt, at, hc, hl) for (kt, at) in node.node]
    @debug v
    itp_param = create_itp_param(node, v, itp_type)
    s -> interpo(s, itp_param)
end

function solve_by_nlvar(m::RBCModel)
    n, a, b = 15, [1.0, 0.9], [30.0, 1.1]
    node = RangeNode(n, a, b)
    niter, ϵ = 100, 0.0001
    itp_param = ITPCubic

    f = (k, a) -> -45 + sqrt(k) + sqrt(a)
    hc = x -> 0.001
    hl = (ct, k, a) -> ((1-m.α)a*k^m.α/((m.γ+1)m.μ*ct))^(1/(m.α+m.γ))

    dt = Dates.format(now(), "yyyymmdd_HHMMSS")
    io = open("solve_by_nlvar(RBCModel)_$dt.log", "w+")
    logger = SimpleLogger(io, Logging.Debug)

    with_logger(logger) do
        converged = -1

        for iter in 1:niter
            hc, updated = update_policy(m, node, hc, f, ϵ, itp_param)
            f = update_value(m, node, hc, hl, itp_param)
            if !updated
                converged = iter
                break
            end
        end

        if converged > 0
            @info "Result is converged($converged)."
        else
            @warn "Result is not converged($niter)."
        end
    end

    close(io)
    return hc
end
