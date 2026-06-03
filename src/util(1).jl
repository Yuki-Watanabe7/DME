abstract type AbstractNode end
abstract type AbstractNode1D <: AbstractNode end
abstract type AbstractNode1DWithParam <: AbstractNode1D end
abstract type AbstractNode2D <: AbstractNode end
abstract type AbstractNode2DWithParam <: AbstractNode2D end

struct Node <: AbstractNode1D
    node::Vector{Float64}
end

struct Node2D <: AbstractNode2D
    node1::Node
    node2::Node
end

function len(n1d::AbstractNode1D)
    length(n1d.node)
end

function lower_bound(n1d::AbstractNode1D)
    n1d.node[1]
end

function upper_bound(n1d::AbstractNode1D)
    n1d.node[end]
end

function node(n1d::AbstractNode1D)
    [x for x in n1d.node]
end

function len(n1d::AbstractNode1DWithParam)
    n1d.n
end

function lower_bound(n1d::AbstractNode1DWithParam)
    n1d.a
end

function upper_bound(n1d::AbstractNode1DWithParam)
    n1d.b
end

function len(n2d::AbstractNode2D)
    len(n2d.node1), len(n2d.node2)
end

function lower_bound(n2d::AbstractNode2D)
    lower_bound(n2d.node1), lower_bound(n2d.node2)
end

function upper_bound(n2d::AbstractNode2D)
    upper_bound(n2d.node1), upper_bound(n2d.node2)
end

function node(n2d::AbstractNode2D)
    node(n2d.node1), node(n2d.node2)
end

struct ChebNode <: AbstractNode1DWithParam
    n::Integer
    a::Float64
    b::Float64
end

function node(nd::ChebNode)
    n, a, b = len(nd), lower_bound(nd), upper_bound(nd)
    z = -cos.(([i for i in 1:n] .- 0.5) .* (pi / n))
    (z.+1) .* ((b-a)/2) .+ a
end

struct RangeNode <: AbstractNode1DWithParam
    n::Integer
    a::Float64
    b::Float64
end

function node(nd::RangeNode)
    n, a, b = len(nd), lower_bound(nd), upper_bound(nd)
    step = (b-a) / (n-1)
    a:step:b
end

struct RangeNode2D <: AbstractNode2DWithParam
    node1::RangeNode
    node2::RangeNode
end

convert(::Type{RangeNode}, node::AbstractNode1D) = RangeNode(node.n, node.a, node.b)
convert(::Type{RangeNode2D}, node::AbstractNode2D) = RangeNode2D(node.node1, node.node2)

@enum Interpo_Type ITPCheb ITPLine ITPCubic

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
    node::ChebNode
    V::Vector{Float64}
    coef::Vector{Float64}
    function Cheb(nd, V)
        function f(F::Vector{Float64}, C::Vector{Float64})
            for (i, s) in enumerate(node(nd))
                F[i] = V[i] - dot(𝛷̂(nd, s), C)
            end
        end
        new(nd, V, nlsolve(f, zeros(len(nd))).zero)
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
    nd::AbstractNode1D
    V::Vector{Float64}
end

struct LinInterpo2D
    nd::AbstractNode2D
    V::Vector{Float64}
end

struct CubicInterpo
    nd::RangeNode
    V::Vector{Float64}
end

struct CubicInterpo2D
    nd::AbstractNode2D
    V::Vector{Float64}
end

function create_itp_param(node::AbstractNode1D, value::Vector{Float64}, itp_type::Interpo_Type)
    if itp_type == ITPCheb
        itp_param = Cheb(node, value)
    elseif itp_type == ITPLine
        itp_param = LinInterpo(node, value)
    elseif itp_type == ITPCubic
        if isa(node, RangeNode)
            itp_param = CubicInterpo(node, value)
        else
            error("$node is not supported for CubicSpline.")
        end
    else
        error("$itp is not supported.")
    end
    return itp_param
end

function create_itp_param(node::AbstractNode2D, value::Vector{Float64}, itp_type::Interpo_Type)
    if itp_type == ITPLine
        itp_param = LinInterpo2D(node, value)
    elseif itp_type == ITPCubic
        if isa(node, RangeNode2D)
            itp_param = CubicInterpo2D(node, value)
        else
            error("$node is not supported for CubicSpline.")
        end
    else
        error("$itp is not supported.")
    end
    return itp_param
end

function interpo(s, param::LinInterpo)
    itp = LinearInterpolation(([x for x in node(param.nd)],), param.V, extrapolation_bc=Flat())
    itp(s)
end

function interpo(s, param::CubicInterpo)
    itp = CubicSplineInterpolation((node(param.nd),), param.V, extrapolation_bc=Flat())
    itp(s)
end

function interpo(s, param::LinInterpo2D)
    itp = extrapolate(interpolate(node(param.nd), param.V, Gridded(Linear())), Flat())
#    itp = LinearInterpolation(node(param.nd), param.V, extrapolation_bc=Flat())
    itp(s)
end

function interpo(s, param::CubicInterpo2D)
    itp = CubicSplineInterpolation(node(param.nd), param.V, extrapolation_bc=Flat())
    itp(s)
end
