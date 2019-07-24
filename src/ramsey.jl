include("../util/util.jl")

using LinearAlgebra
using NLsolve
using Plots
using JuMP
using Ipopt

struct RamseyModel
    α::Float64
    β::Float64
    δ::Float64
end

U = C -> log(C)
g = (m, K, C) -> K^m.α + (1-m.δ)K - C

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
    obj = ct -> -U(ct) - m.β*f(g(m, k, ct))
    model = Model(with_optimizer(Ipopt.Optimizer, print_level=0))
    @variable(model, lb <= ct <= ub, start=start)
    register(model, :obj, 1, obj, autodiff=true)
    @NLobjective(model, Min, obj(ct))
    @NLconstraint(model, ct<=(1-m.δ)k+k^m.α)
    optimize!(model)
    value(ct)
end

function solve_by_nlvar(m::RamseyModel)
    n, a, b = 20, 0.5, 3.0
    node = ChebNode(n, a, b)
    niter, ϵ = 1000, 0.0001

    f = x -> -45 + sqrt(x)
    hc = x -> 0.001
    cc = [hc(x) for x in node.node]
    v = [f(x) for x in node.node]

    for iter in 1:niter
        c1 = copy(cc)

        for (i, st) in enumerate(node.node)
            cc[i] = optimize_c(m, st, f, 0.001, 0.99b, 0.001)
        end
        hc_cheb = Cheb(node, cc)
        hc = s -> cheb(s, hc_cheb)

        for (i, st) in enumerate(node.node)
            ct = max(min(hc(st), st), 0.001)
            y = U(ct)
            for k in 1:1000
                st = g(m, st, ct)
                ct = max(min(hc(st), st), 0.001)
                y += m.β^k * U(ct)
            end
            v[i] = y
        end
        if (abs.(cc - c1) .< ϵ) == trues(n)
            @show iter
            break
        end
        f_cheb = Cheb(node, v)
        f = s -> cheb(s, f_cheb)

    end

    return hc
end
