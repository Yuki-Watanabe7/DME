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
    to_simulation_result,
    SolverOptions,
    ValueIterationOptions

using LinearAlgebra
using NLsolve
using JuMP
using Ipopt
using Plots
using Interpolations
using Logging
using Dates

# Numerical utilities: grid types and interpolation
include("./numerics/grids.jl")
include("./numerics/interpolation.jl")

# Core abstractions: model interface, solver options
include("./core/model_interface.jl")
include("./core/solver_options.jl")

# Model implementations
include("./models/ramsey.jl")
include("./models/rbc.jl")

# Cross-model result type (depends on RamseyModel and RBCModel)
include("./core/simulation_result.jl")

end
