module DME

export
    AbstractMacroModel,
    model_name,
    state_variables,
    control_variables,
    parameters,
    steady_state,
    transition_path,
    simulate,
    impulse_response,
    RamseyModel,
    calc_ep,
    find_path,
    solve_by_nlvar,
    simulate_by_nlvar,
    RBCModel,
    solve_rbc,
    shock,
    SimulationResult,
    variable_names,
    nperiods,
    to_simulation_result

using LinearAlgebra
using NLsolve
using JuMP
using Ipopt
using Plots
using Interpolations
using Logging
using Dates

include("./util.jl")
include("./interface.jl")
include("./ramsey.jl")
include("./RBC.jl")
include("./simulation_result.jl")

end
