module DME

# === Public API ===
export
    # Model type hierarchy
    AbstractMacroModel,
    RamseyModel,
    RBCModel,
    # Model metadata
    model_name,
    state_variables,
    control_variables,
    parameters,
    # Unified computation API
    steady_state,
    transition_path,
    simulate,
    impulse_response,
    # Result type
    SimulationResult,
    variable_names,
    nperiods,
    to_simulation_result,
    # Solver options
    SolverOptions,
    ValueIterationOptions
# Internal API (not exported): calc_ep, find_path, solve_by_nlvar,
#   simulate_by_nlvar, solve_rbc, shock
# Access via DME.calc_ep etc. if needed for advanced use.

using LinearAlgebra
using NLsolve
using JuMP
using Ipopt
using Plots
using Interpolations
using Logging

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
