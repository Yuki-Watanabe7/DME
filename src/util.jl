using LinearAlgebra
using NLsolve

struct ChebNode
    n::Integer
    a::Float64
    b::Float64
    node::Vector{Float64}
    function ChebNode(n, a, b)
        z = -cos.(([i for i in 1:n] .- 0.5) .* (pi / n))
        new(n, a, b, (z.+1) .* ((b-a)/2) .+ a)
    end
end

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
    function Cheb(node, V)
        function f(F::Vector{Float64}, C::Vector{Float64})
            for (i, s) in enumerate(node.node)
                F[i] = V[i] - dot(𝛷̂(node, s), C)
            end
        end
        new(node, V, nlsolve(f, zeros(node.n)).zero)
    end
end

function cheb(s, param::Cheb)
    dot(𝛷̂(param.node, s), param.coef)
end
