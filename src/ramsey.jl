struct RamseyModel <: AbstractMacroModel
    α::Float64
    β::Float64
    δ::Float64
end

model_name(::RamseyModel) = "Ramsey Model"
state_variables(::RamseyModel) = [:K]
control_variables(::RamseyModel) = [:C]
parameters(m::RamseyModel) = (α = m.α, β = m.β, δ = m.δ)

function steady_state(m::RamseyModel)
    K, C = calc_ep(m)
    (K = K, C = C)
end

function transition_path(m::RamseyModel, K0::Float64)
    find_path(m, K0)
end

function simulate(m::RamseyModel, K0::Float64)
    simulate_by_nlvar(m, K0)
end

function U(m::RamseyModel, C)
    log(C)
end

function g(m::RamseyModel, K, C)
    K^m.α + (1-m.δ)K - C
end

function calc_ep(m::RamseyModel)
    α, β, δ = m.α, m.β, m.δ
    K⃰ = ((1/β + δ - 1) / α)^(1/(α-1))
    C⃰ = K⃰^α - δ*K⃰
    return K⃰, C⃰
end

function find_path(m::RamseyModel, K0::Float64)
    α, β, δ = m.α, m.β, m.δ
    maxT = 30
    K⃰, C⃰ = calc_ep(m)

    function f(F, X)
        c = X[1:maxT]
        push!(c, C⃰)
        k = X[maxT+1:2maxT]
        pushfirst!(k, K0)
        for i in 1:maxT
            F[2i-1] = c[i+1]/c[i] - β*(α*k[i+1]^(α-1)-δ+1)
            F[2i] = k[i+1] - g(m, k[i], c[i])
        end
    end

    ini_c = ones(maxT) * C⃰
    ini_k = ones(maxT) * K⃰
    ini_v = ini_c
    append!(ini_v, ini_k)
    ans = nlsolve(f, ini_v).zero
    C = ans[1:maxT]
    push!(C, C⃰)
    K = ans[maxT+1:2maxT]
    pushfirst!(K, K0)
    (C=C, K=K)
end

function optimize_c(m::RamseyModel, k::Float64, f, lb::Float64, ub::Float64, start::Float64)
    budget_ub = min(ub, (1 - m.δ) * k + k^m.α)
    obj = ct -> -U(m, ct) - m.β * f(g(m, k, ct))
    model = Model(optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0))
    @variable(model, lb <= ct <= budget_ub, start = start)
    @operator(model, op_obj, 1, obj)
    @objective(model, Min, op_obj(ct))
    optimize!(model)
    value(ct)
end

function update_policy(m::RamseyModel, nd::AbstractNode, old_hc, f, ϵ::Float64, itp_type::Interpo_Type)
    ub = 0.99 * upper_bound(nd)
    old_cc = [old_hc(x) for x in node(nd)]
    new_cc = [optimize_c(m, st, f, 0.001, ub, 0.001) for st in node(nd)]
    @debug new_cc
    itp_param = create_itp_param(nd, new_cc, itp_type)
    new_hc = s -> interpo(s, itp_param)
    (hc=new_hc, updated=is_updated(old_cc, new_cc, ϵ))
end

function V(m::RamseyModel, st::Float64, hc)
    y = 0
    for k in 0:1000
        ct = max(min(hc(st), st), 0.001)
        y += m.β^k * U(m, ct)
        st = g(m, st, ct)
    end
    y
end

function update_value(m::RamseyModel, nd::AbstractNode, hc, itp_type::Interpo_Type)
    v = [V(m, st, hc) for st in node(nd)]
    @debug v
    itp_param = create_itp_param(nd, v, itp_type)
    s -> interpo(s, itp_param)
end

function solve_by_nlvar(m::RamseyModel)
    n, a, b = 20, 0.5, 3.0
    node = RangeNode(n, a, b)
    niter, ϵ = 100, 0.0001
    itp_param = ITPCubic

    f = x -> -45 + sqrt(x)
    hc = x -> 0.001

    dt = Dates.format(now(), "yyyymmdd_HHMMSS")
    io = open("solve_by_nlvar(RamseyModel)_$dt.log", "w+")
    logger = SimpleLogger(io, Logging.Debug)

    with_logger(logger) do
        converged = -1

        for iter in 1:niter
            hc, updated = update_policy(m, node, hc, f, ϵ, itp_param)
            f = update_value(m, node, hc, itp_param)
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

function simulate_by_nlvar(m::RamseyModel, K0::Float64)
    maxT = 30

    hc = solve_by_nlvar(m)

    K = zeros(maxT)
    C = zeros(maxT)
    K[1] = K0
    C[1] = hc(K[1])

    for i in 2:maxT
        K[i] = g(m, K[i-1], C[i-1])
        C[i] = hc(K[i])
    end
    (C=C, K=K)
end
