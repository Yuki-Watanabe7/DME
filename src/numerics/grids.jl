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
    (z .+ 1) .* ((b-a)/2) .+ a
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

function is_updated(old::Vector{Float64}, new::Vector{Float64}, ϵ::Float64)
    (abs.(old-new) .< ϵ) != trues(length(old))
end
