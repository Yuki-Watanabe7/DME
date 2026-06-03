module DME

export
    RamseyModel,
    calc_ep,
    find_path,
    solve_by_nlvar,
    simulate_by_nlvar,
    RBCModel,
    solve_rbc,
    shock

using LinearAlgebra
using NLsolve
using JuMP
using Ipopt
using Plots
using Interpolations
using Logging
using Dates

include("./util.jl")
include("./ramsey.jl")
include("./RBC.jl")

end
