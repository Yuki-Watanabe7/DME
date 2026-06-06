module DME

# === Public API ===
export
    # Model type hierarchy
    AbstractMacroModel,
    RamseyModel,
    RBCModel,
    SolowModel,
    ISLMModel,
    ADASModel,
    NewKeynesianModel,
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
    # Visualization
    plot_result,
    plot_comparison,
    # Solver options
    SolverOptions,
    ValueIterationOptions
# Internal API (not exported): calc_ep, find_path, solve_by_nlvar,
#   simulate_by_nlvar, solve_rbc, shock,
#   islm_equilibrium, islm_policy_shock,
#   adas_equilibrium, adas_shock_compare,
#   nk_msv_response, nk_irf_compare
# Access via DME.nk_msv_response etc. if needed for advanced use.

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
include("./models/solow.jl")
include("./models/islm.jl")
include("./models/adas.jl")
include("./models/new_keynesian.jl")

# Cross-model result type (depends on RamseyModel and RBCModel)
include("./core/simulation_result.jl")

# Visualization (depends on SimulationResult)
include("./core/visualization.jl")

end
