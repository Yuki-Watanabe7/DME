abstract type AbstractNode end

struct Node <: AbstractNode
    n::Integer
    a::Float64
    b::Float64
    node::Vector{Float64}
    function Node(node)
        new(length(node), node[1], node[end], node)
    end
end

struct ChebNode <: AbstractNode
    n::Integer
    a::Float64
    b::Float64
    node::Vector{Float64}
    function ChebNode(n, a, b)
        z = -cos.(([i for i in 1:n] .- 0.5) .* (pi / n))
        new(n, a, b, (z.+1) .* ((b-a)/2) .+ a)
    end
end

@enum Interpo_Type ITPCheb ITPLine

function 𝛷̂(node::ChebNode, s)
    n, a, b = node.n, node.a, node.b

    function 𝛷(z)
        rtn = Vector()
        push!(rtn, 1, z)
        for j in 3:n
            push!(rtn, 2z*rtn[j-1] - rtn[j-2])
        end
        rtn
    end
    𝛷(2(s-a)/(b-a) - 1)
end

struct Cheb
    node::AbstractNode
    V::Vector{Float64}
    coef::Vector{Float64}
    function Cheb(node, V)
        function f(F::Vector{Float64}, C::Vector{Float64})
            for (i, s) in enumerate(node.node)
                F[i] = V[i] - dot(𝛷̂(node, s), C)
            end
        end
        new(node, V, nlsolve(f, zeros(node.n)).zero)
    end
end

function interpo(s, param::Cheb)
    dot(𝛷̂(param.node, s), param.coef)
end

function is_updated(old::Vector{Float64}, new::Vector{Float64}, ϵ::Float64)
    (abs.(old-new) .< ϵ) != trues(length(old))
end

function plot_f(f, domain::StepRangeLen)
    plt = plot(domain, f.(domain))
    display(plt)
end

struct LinInterpo
    node::AbstractNode
    V::Vector{Float64}
end

function create_itp_param(node::AbstractNode, value::Vector{Float64}, itp_type::Interpo_Type)
    if itp_type == ITPCheb
        itp_param = Cheb(node, value)
    elseif itp_type == ITPLine
        itp_param = LinInterpo(node, value)
    else
        error("$itp is not Supported.")
    end
    return itp_param
end

function interpo(s, param::LinInterpo)
    itp = LinearInterpolation((param.node.node,), param.V, extrapolation_bc=Flat())
    itp(s)
end
