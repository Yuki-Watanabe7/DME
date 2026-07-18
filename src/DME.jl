module DME

# === Public API ===
export
    # Data types
    DataFrequency,
    Annual,
    Quarterly,
    Monthly,
    DataSeries,
    MacroDataset,
    series_ids,
    get_series,
    nonmissing_values,
    missing_count,
    # FRED API client
    FredClient,
    fetch_fred_series,
    fetch_fred_dataset,
    # e-Stat API client
    EStatClient,
    fetch_estat_series,
    fetch_estat_dataset,
    # Data preprocessing
    fill_missing,
    drop_missing,
    apply_log,
    difference,
    pct_change,
    moving_average,
    standardize,
    trim_period,
    to_quarterly,
    to_annual,
    # Keen empirical dataset
    KeenSeriesSpec,
    keen_convert_value,
    keen_value_valid,
    KeenEmpiricalDataConfig,
    keen_us_default_config,
    KeenSeriesProvenance,
    KeenEmpiricalDataset,
    build_keen_empirical_dataset,
    KEEN_EMPIRICAL_METHODOLOGY_VERSION,
    # Model type hierarchy
    AbstractMacroModel,
    RamseyModel,
    RBCModel,
    SolowModel,
    ISLMModel,
    ADASModel,
    NewKeynesianModel,
    VARModel,
    MundellFlemingModel,
    KeenModel,
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
    summarize_result,
    # Data comparison
    ComparisonResult,
    compare_with_data,
    to_data_comparison_summary,
    # Visualization
    plot_result,
    plot_irf,
    plot_comparison,
    # Solver options
    SolverOptions,
    ValueIterationOptions,
    ODESolverOptions,
    # Minsky financing regime diagnostics (Keen model)
    FinancingRegime,
    unlevered,
    hedge,
    speculative,
    ponzi,
    invalid,
    FinancingRegimeConfig,
    FinancingRegimeObservation,
    FinancingRegimeTransition,
    FinancingRegimeDiagnostics,
    classify_financing_regime,
    diagnose_financing_regime,
    # Minsky continuous diagnostics & summary (Keen model, Phase 2)
    DivergenceStatus,
    no_divergence,
    divergence_onset,
    divergence_continued,
    MinskyDiagnosticObservation,
    MinskyDiagnosticsResult,
    MinskyDiagnosticsSummary,
    MinskyDiagnosticsComparison,
    minsky_diagnostics,
    minsky_diagnostics_summary,
    minsky_diagnostics_comparison,
    # Minsky visualization (Keen model, Phase 2)
    plot_financing_regimes,
    plot_minsky_diagnostics,
    plot_minsky_scenario_comparison,
    # LLM context types
    ModelMetadata,
    SimulationResultSummary,
    DataComparisonSummary,
    Caveats,
    DocsExcerpts,
    AnalysisContext,
    to_dict,
    to_json,
    to_compact_dict,
    # LLM doc context (軽量RAG)
    build_docs_excerpts,
    # LLM prompt generation
    ExplainResultOutput,
    build_explain_prompt,
    explain_result,
    ExplainDataComparisonOutput,
    build_data_comparison_prompt,
    explain_data_comparison,
    # LLM provider abstraction
    LLMProviderError,
    LLMRequest,
    LLMResponse,
    AbstractLLMProvider,
    MockLLMProvider,
    OpenAIProvider,
    complete,
    create_provider,
    complete_from_prompt
# Internal API (not exported): calc_ep, find_path, solve_by_nlvar,
#   simulate_by_nlvar, solve_rbc, shock,
#   islm_equilibrium, islm_policy_shock,
#   adas_equilibrium, adas_shock_compare,
#   nk_msv_response, nk_irf_compare,
#   mf_equilibrium, mf_policy_shock,
#   keen_rhs, keen_rk4_step, keen_diverged, keen_scenario_comparison
#   _classify_financing_regime, _diagnose_from_series
#   _contiguous_regime_runs, _clip_ratio_for_plot, _minsky_diagnostic_panel,
#   _check_comparable_minsky_configs
#   _load_fred_fixture, _fetch_fred_live, _parse_fred_json,
#   _parse_fred_observations, _fred_date_to_label, _detect_frequency,
#   _build_fred_url, _http_get
#   _load_estat_fixture, _fetch_estat_live, _parse_estat_json,
#   _build_estat_time_map, _parse_estat_values, _estat_code_to_label,
#   _estat_detect_frequency, _estat_parse_value, _build_estat_url, _estat_http_get
# Access via DME.xxx if needed for advanced use.

using LinearAlgebra
using NLsolve
using JuMP
using Ipopt
using Plots
using Interpolations
using Logging
using JSON3
using Downloads

# Data types: external data standard types
include("./data/data_series.jl")
include("./data/preprocess.jl")
include("./data/fred.jl")
include("./data/estat.jl")
include("./data/keen_empirical.jl")

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
include("./models/var.jl")
include("./models/mundell_fleming.jl")
include("./models/keen.jl")

# Cross-model result type (depends on RamseyModel and RBCModel)
include("./core/simulation_result.jl")
include("./core/compare.jl")

# Minsky financing regime diagnostics (depends on KeenModel and SimulationResult)
include("./analysis/minsky_regimes.jl")

# Minsky continuous diagnostics & summary (depends on minsky_regimes.jl)
include("./analysis/minsky_diagnostics.jl")

# Visualization (depends on SimulationResult)
include("./core/visualization.jl")

# Minsky visualization (depends on minsky_diagnostics.jl and Plots, Phase 2)
include("./analysis/minsky_visualization.jl")

# LLM context layer (depends on SimulationResult and model interface)
include("./llm/analysis_context.jl")
include("./llm/doc_context.jl")
include("./llm/prompts.jl")
include("./llm/provider.jl")

end
