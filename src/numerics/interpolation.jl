@enum Interpo_Type ITPCheb ITPLine ITPCubic

function 𝛷̂(node::ChebNode, s)
    n, a, b = node.n, node.a, node.b

    function 𝛷(z)
        rtn = Vector()
        push!(rtn, 1, z)
        for j in 3:n
            push!(rtn, 2z*rtn[j - 1] - rtn[j - 2])
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

function create_itp_param(
    node::AbstractNode1D,
    value::Vector{Float64},
    itp_type::Interpo_Type,
)
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

function create_itp_param(
    node::AbstractNode2D,
    value::Vector{Float64},
    itp_type::Interpo_Type,
)
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
    knots = collect(node(param.nd))
    itp = extrapolate(interpolate((knots,), param.V, Gridded(Linear())), Flat())
    itp(s)
end

function interpo(s, param::CubicInterpo)
    itp = cubic_spline_interpolation((node(param.nd),), param.V, extrapolation_bc = Flat())
    itp(s)
end

function interpo(s, param::LinInterpo2D)
    nd1_nodes, nd2_nodes = node(param.nd)
    n1, n2 = len(param.nd)
    # Reshape flat V into matrix[i,j] where i indexes nd1, j indexes nd2
    # V is stored row-major: V[(i-1)*n2+j] → permutedims(reshape(V, n2, n1))
    V_matrix = permutedims(reshape(param.V, n2, n1))
    itp = extrapolate(
        interpolate((collect(nd1_nodes), collect(nd2_nodes)), V_matrix, Gridded(Linear())),
        Flat(),
    )
    itp(s[1], s[2])
end

function interpo(s, param::CubicInterpo2D)
    nd1_nodes, nd2_nodes = node(param.nd)
    n1, n2 = len(param.nd)
    V_matrix = permutedims(reshape(param.V, n2, n1))
    itp = cubic_spline_interpolation(
        (nd1_nodes, nd2_nodes),
        V_matrix,
        extrapolation_bc = Flat(),
    )
    itp(s[1], s[2])
end
