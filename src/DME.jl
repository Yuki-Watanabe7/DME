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
    # CCC empirical catalog (Issue #241 / P-1)
    CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
    CAPEX_CC_SERIES_ROLES,
    CAPEX_CC_SOURCE_KINDS,
    CAPEX_CC_METHODOLOGY_KINDS,
    CAPEX_CC_OBSERVABILITY_CLASSES,
    CapexSeriesSpec,
    CAPEX_CC_SERIES_CATALOG,
    capex_series_catalog,
    CapexProviderGap,
    CAPEX_CC_PROVIDER_GAPS,
    validate_capex_series_catalog,
    capex_series_catalog_to_dict,
    save_capex_series_catalog,
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
    SIMModel,
    CapexCreditCycleModel,
    # Model metadata
    model_name,
    state_variables,
    control_variables,
    parameters,
    exogenous_variables,
    # Unified computation API
    steady_state,
    transition_path,
    simulate,
    impulse_response,
    # イベント・シナリオ実行層: version（Issue #197 / `E-1`、src/scenarios/macro_events.jl）
    MACRO_EVENT_CONTRACT_VERSION,
    SCENARIO_TIME_SEMANTICS_VERSION,
    MACRO_EVENT_RUNTIME_VERSION,
    EVENT_RULE_VERSION,
    CAPEX_CC_EVENT_MAPPING_VERSION,
    SCENARIO_ARTIFACT_SCHEMA_VERSION,
    # イベント・シナリオ実行層: 4層レコード型と共通下位構造
    AbstractMacroEvent,
    ObservedEvent,
    InterpretedSignal,
    ScenarioAssumption,
    AppliedModelInput,
    EventSource,
    EventProvenance,
    PersistenceSpec,
    EventTiming,
    # イベント・シナリオ実行層: 語彙
    MACRO_EVENT_TYPES,
    MACRO_EVENT_TARGET_CONCEPTS,
    MACRO_EVENT_SHAPES,
    MACRO_EVENT_APPLICATION_MODES,
    MACRO_EVENT_MAGNITUDE_SOURCES,
    MACRO_EVENT_LAYERS,
    MACRO_EVENT_WARNING_CODES,
    MACRO_EVENT_REJECTION_CODES,
    # イベント・シナリオ実行層: 検証
    validate_event,
    # イベント・シナリオ実行層: シナリオ集合・時間軸型（src/scenarios/scenario_time.jl・
    # scenario_types.jl。`CalendarQuarter`/`TimingRuleSet` は型、規則の実装は Issue #198）
    CalendarQuarter,
    TimingRuleSet,
    Scenario,
    ScenarioWarning,
    EventRejection,
    # イベント・シナリオ実行層: 暦四半期変換・時間形状（src/scenarios/scenario_time.jl、
    # Issue #198 / `E-2`）
    quarter_of,
    quarter_index,
    quarter_label,
    shock_shape_path,
    # イベント・シナリオ実行層: スケジューラ（src/scenarios/event_scheduler.jl、
    # Issue #198 / `E-2`）
    ScheduledEvent,
    EventLogEntry,
    EventSchedule,
    schedule_events,
    compose_exogenous_paths,
    # イベント・シナリオ実行層: イベント型レジストリ・実体経済イベント型5種（Issue #199 /
    # `E-3`）・信用・金融政策側イベント型4種（Issue #200 / `E-4`）（src/scenarios/
    # event_type_registry.jl）
    MacroEventTypeSpec,
    MACRO_EVENT_TYPE_REGISTRY,
    macro_event_type_spec,
    observed_event,
    interpreted_signal,
    scenario_assumption,
    macro_event_dedup_key,
    # CCC: 構築・較正（部門別CAPEX・信用循環モデル、src/models/capex_credit_cycle.jl）
    CAPEX_CREDIT_CYCLE_MODEL_VERSION,
    CapexCreditCycleTargets,
    capex_credit_cycle_default_targets,
    capex_credit_cycle_model,
    CapexSectorSets,
    # CCC: 実行
    CapexCreditCycleOptions,
    CapexCreditCycleRun,
    capex_run,
    capex_steady_state_report,
    CapexSteadyStateReport,
    passed,
    # CCC: シナリオ（src/analysis/capex_credit_cycle_scenarios.jl）
    CAPEX_CC_SCENARIO_IDS,
    CapexShockSpec,
    CapexScenario,
    capex_scenario,
    capex_exogenous_paths,
    # CCC: 会計（src/analysis/capex_credit_cycle_accounting.jl）
    CAPEX_CC_ACCOUNTING_VERSION,
    CAPEX_CC_ACCOUNTING_CHECKS,
    capex_accounting_snapshots,
    validate_capex_accounting,
    # CCC: 診断層（src/analysis/capex_credit_cycle_diagnostics.jl、Issue #183 / `I-5`）
    CapexDiagnosticThresholds,
    CapexDiagnostics,
    CAPEX_CC_FUNDING_PRESSURE_LABELS,
    CAPEX_CC_NL_IDS,
    CAPEX_CC_LOOP_IDS,
    CAPEX_CC_LOOP_GAIN_IDS,
    CAPEX_CC_COUNTERFACTUAL_KINDS,
    capex_diagnostics,
    capex_counterfactual,
    capex_label_sensitivity,
    # CCC: イベント mapping adapter（src/scenarios/adapters/capex_credit_cycle_event_adapter.jl、
    # Issue #201 / `E-5`）
    EventMappingRule,
    CAPEX_CC_EVENT_MAPPING_RULES,
    map_event,
    capex_scenario_assumptions,
    # イベント・シナリオ実行層: 実行 API（src/scenarios/scenario_types.jl・scenario_runner.jl、
    # Issue #202 / `E-6`）
    SCENARIO_EXECUTION_STATUSES,
    ScenarioRunOptions,
    ScenarioProvenance,
    ScenarioRun,
    run_scenario,
    # イベント・シナリオ実行層: 監査・再現（src/scenarios/scenario_provenance.jl・
    # scenario_serialization.jl、Issue #203 / `E-7`）
    scenario_event_log,
    event_set_hash,
    scenario_content_hash,
    scenario_to_dict,
    scenario_from_dict,
    save_scenario_artifact,
    load_scenario,
    replay_scenario,
    # イベント・シナリオ実行層: シナリオ比較診断（src/analysis/scenario_diagnostics.jl、
    # Issue #204 / `E-8`）
    ScenarioDiagnosticThresholds,
    ScenarioComparisonDiagnostics,
    scenario_comparison,
    scenario_timing_sensitivity,
    scenario_magnitude_sensitivity,
    # New Keynesian: 期待インフレ率パス・level 復元（Issue #159）
    nk_expected_inflation_path,
    nk_inflation_level,
    nk_nominal_rate_level,
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
    # Data comparison v2（日付・単位・概念対応・比較可能性を明示）
    ComparisonSpec,
    VariableComparisonMapping,
    AlignmentResult,
    ComparabilityAssessment,
    ComparisonResultV2,
    compare_results_v2,
    # JSON canonicalization (RFC 8785 JCS, src/artifacts/json_canonical.jl)
    canonical_json_bytes,
    canonical_json_string,
    sha256_hex_of_canonical,
    # Real-rate model artifact (Issue #159 / economic-data-provider ADR 006 準拠,
    # src/artifacts/real_rate_model_artifact.jl, real_rate_model_artifact_export.jl)
    REAL_RATE_ARTIFACT_SCHEMA_VERSION,
    ModelIdentity,
    ParameterSet,
    Calibration,
    InputSource,
    InputSnapshot,
    RunIdentity,
    Timing,
    ModelPeriod,
    Horizon,
    horizon_not_applicable,
    horizon_expectation,
    Derivation,
    Provenance,
    ModelObservation,
    RealRateModelArtifact,
    compute_artifact_id,
    real_rate_model_artifact_from_dict,
    real_rate_model_artifact_from_json,
    real_rate_model_artifact,
    save_real_rate_model_artifact,
    load_real_rate_model_artifact,
    # Julia品質Export Contract v1（Issue #207、src/quality/quality_export.jl）
    QUALITY_EXPORT_SCHEMA,
    QUALITY_EXPORT_DEFAULT_PRODUCER_NAME,
    QUALITY_EXPORT_DEFAULT_PRODUCER_VERSION,
    QUALITY_EXPORT_TOOL_STATUSES,
    QUALITY_EXPORT_RESERVED_TOOL_NAMES,
    QualityExportProducer,
    QualityExportPackage,
    QualityExportRepository,
    QualityToolError,
    QualityToolExecution,
    QualityExport,
    quality_tool_not_run,
    quality_export_package_identity,
    quality_export_from_dict,
    quality_export_from_json,
    save_quality_export,
    load_quality_export,
    quality_export_with_tool,
    redact_secrets,
    # Pkg.test/Aqua.jl/JuliaFormatter.jl 実測結果の構造化（Issue #208、src/quality/quality_capture.jl）
    quality_tool_pkgtest_result,
    QualityAquaCheck,
    quality_tool_aqua_result,
    quality_tool_formatter_result,
    # Coverage.jl 実測結果の構造化（Issue #209、src/quality/quality_capture.jl）
    QUALITY_COVERAGE_TARGET_PATHS,
    QUALITY_COVERAGE_EXCLUDED_PATHS,
    quality_tool_coverage_result,
    # JET.jl 実測結果の構造化（Issue #211、src/quality/quality_capture.jl）
    QUALITY_JET_SEVERITIES,
    QUALITY_JET_SEVERITY_MAP,
    QUALITY_JET_ANALYSIS_MODES,
    quality_jet_finding_severity,
    QualityJetFinding,
    quality_jet_stable_finding_ids,
    quality_tool_jet_result,
    # BenchmarkTools.jl 実測結果の構造化（Issue #212、src/quality/quality_capture.jl）
    QUALITY_BENCHMARK_REGRESSION_STATUSES,
    QUALITY_BENCHMARK_UNAVAILABLE_REASONS,
    QUALITY_BENCHMARK_DEFAULT_MARGIN_PERCENT,
    QUALITY_BENCHMARK_BASELINE_SOURCES,
    quality_benchmark_environment_key,
    quality_benchmark_delta_percent,
    quality_benchmark_regression_status,
    QualityBenchmarkResult,
    QualityBenchmarkBaselineRef,
    quality_tool_benchmark_result,
    # Documenter.jl ビルド結果の構造化（Issue #213、src/quality/quality_capture.jl）
    QUALITY_DOCS_BUILD_STATUSES,
    QUALITY_DOCS_MESSAGE_LEVELS,
    QUALITY_DOCS_ERROR_CATEGORIES,
    QUALITY_DOCS_MESSAGE_LIMIT,
    QUALITY_DOCS_MESSAGE_MAX_CHARS,
    QualityDocsMessage,
    quality_docs_build_status,
    quality_tool_documenter_result,
    # Stable orchestration CLI (Issue #220, src/cli.jl)
    dme_main,
    # SFC accounting primitives (src/sfc/)
    SFCSector,
    SFCInstrument,
    BalanceSheetMatrix,
    TransactionFlowMatrix,
    SFCPeriodSnapshot,
    SFCMethodologyMetadata,
    SFCResult,
    holding,
    flow_value,
    net_worth,
    total_assets,
    total_liabilities,
    zero_valuation,
    sfc_result_from_dict,
    sfc_result_from_json,
    save_sfc_result,
    load_sfc_result,
    SFC_CONTRACT_VERSION,
    SFC_SECTOR_TYPES,
    SFC_SIGN_CONVENTIONS,
    SFC_TIME_CONVENTIONS,
    # SFC accounting validation engine (src/analysis/sfc_accounting.jl)
    SFC_ACCOUNTING_METHODOLOGY_VERSION,
    AccountingCheckStatus,
    acc_pass,
    acc_warning,
    acc_fail,
    acc_invalid,
    accounting_status_label,
    AccountingViolation,
    AccountingCheckReport,
    accounting_passed,
    validate_sfc_accounting,
    # SIM 型 SFC モデルの adapter（src/analysis/sfc_sim_adapter.jl）
    SIM_SFC_MODEL_VERSION,
    sfc_result,
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
    # Minsky continuous diagnostics & summary (Keen model)
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
    # Keen 限定キャリブレーション（ODE residual）
    KEEN_CALIBRATION_METHODOLOGY_VERSION,
    KEEN_LITERATURE_PARAMS,
    keen_literature_params,
    KeenCalibrationConfig,
    KeenCalibrationStart,
    KeenCalibrationResult,
    keen_default_calibration_config,
    calibrate_keen,
    keen_calibration_config_to_dict,
    keen_calibration_config_from_dict,
    keen_calibration_to_dict,
    save_keen_calibration,
    save_keen_calibration_config,
    load_keen_calibration_config,
    # Keen 実証バリデーション・感応度分析
    KEEN_VALIDATION_METHODOLOGY_VERSION,
    KEEN_VALIDATION_CAVEATS,
    KeenVariableMetrics,
    KeenSensitivityScenario,
    KeenValidationConfig,
    keen_default_validation_config,
    KeenPeriodEvaluation,
    KeenRegimeComparison,
    KeenSensitivityResult,
    KeenTrajectoryBundle,
    KeenValidationResult,
    validate_keen,
    keen_validation_to_dict,
    save_keen_validation,
    keen_empirical_report,
    save_keen_empirical_report,
    # Keen 実証比較可視化
    plot_keen_empirical_trajectories,
    plot_keen_regime_comparison,
    plot_keen_sensitivity,
    # Minsky visualization (Keen model)
    plot_financing_regimes,
    plot_minsky_diagnostics,
    plot_minsky_scenario_comparison,
    # CCC: 可視化（src/analysis/capex_credit_cycle_visualization.jl、Issue #185 / `I-7`）
    plot_capex_series,
    CAPEX_CC_SECTOR_SERIES_CONCEPTS,
    plot_capex_sector_series,
    CAPEX_CC_SCENARIO_COMPARISON_VARS,
    plot_capex_scenario_comparison,
    plot_capex_diagnostic_label,
    plot_capex_funding_pressure,
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
    # Keen 実証 AI コンテキスト（ADR 0005）
    KEEN_AI_CONTEXT_CONTRACT_VERSION,
    KEEN_AI_PROMPT_VERSION,
    KEEN_EVIDENCE_CATEGORIES,
    DME_EVIDENCE_CATEGORIES,
    EvidenceSource,
    ExplanationWarning,
    AnalysisScope,
    ObservedSeriesSummary,
    MethodologySummary,
    CalibrationSummary,
    ModelOutputSummary,
    ValidationVariableFit,
    ValidationEvaluationSummary,
    ValidationSummary,
    RegimeDiagnosticSummary,
    SensitivitySummary,
    LimitationSummary,
    KeenEmpiricalContext,
    # LLM doc context (軽量RAG)
    build_docs_excerpts,
    # LLM prompt generation
    ExplainResultOutput,
    build_explain_prompt,
    explain_result,
    ExplainDataComparisonOutput,
    build_data_comparison_prompt,
    explain_data_comparison,
    # Keen 実証結果の根拠付き説明 API（ADR 0005 §4）
    KEEN_AI_OUTPUT_CONTRACT_VERSION,
    KEEN_EPISTEMIC_STATUSES,
    KEEN_SECTION_STATUSES,
    KEEN_OUTPUT_SECTION_ORDER,
    EvidenceClaim,
    ExplanationSection,
    KeenEmpiricalExplanationOutput,
    build_keen_empirical_prompt,
    explain_keen_empirical_result,
    parse_keen_empirical_response,
    # クロスモデル推論層（#132 / ADR 0006）
    CROSS_MODEL_CONTEXT_CONTRACT_VERSION,
    CROSS_MODEL_PROMPT_VERSION,
    CROSS_MODEL_OUTPUT_CONTRACT_VERSION,
    CROSS_MODEL_CONCEPTS,
    CROSS_MODEL_TREATMENTS,
    CROSS_MODEL_MAPPING_TYPES,
    CROSS_MODEL_OUTPUT_SECTION_ORDER,
    ModelConceptCoverage,
    ModelConceptMapping,
    derive_concept_mapping,
    MODEL_CONCEPT_REGISTRY,
    model_concept_coverage,
    CrossModelComparisonContext,
    build_cross_model_comparison_context,
    insufficient_comparability_concepts,
    CrossModelReasoningOutput,
    build_cross_model_prompt,
    explain_cross_model_comparison,
    parse_cross_model_response,
    coverage_concept_definitions,
    # Keen–SFC 概念対応・非対応と比較レポート（#151 / Phase 5）
    KEEN_SFC_COMPARISON_CONTRACT_VERSION,
    KEEN_SFC_MODELS,
    KEEN_SFC_CONCEPTS,
    KEEN_SFC_CONCEPT_LABELS,
    KEEN_SFC_SOURCE_IDS,
    KeenSFCConceptCorrespondence,
    KEEN_SFC_CONCEPT_CORRESPONDENCES,
    keen_sfc_correspondences,
    keen_sfc_concept_mapping,
    keen_sfc_concept_mappings,
    keen_sfc_sim_unavailable_indicators,
    keen_sfc_mechanism_diff,
    keen_sfc_suitable_questions,
    keen_sfc_minsky_gaps,
    build_keen_sfc_comparison_context,
    KeenSFCComparisonReport,
    compare_keen_sfc,
    explain_keen_sfc_comparison,
    # モデル能力プロファイル・概念定義 metadata（#149 / Phase 5）
    MODEL_CAPABILITY_CONTRACT_VERSION,
    CAPABILITY_TIME_REPRESENTATIONS,
    CAPABILITY_APIS,
    CAPABILITY_SECTORS,
    CAPABILITY_INSTRUMENTS,
    CAPABILITY_ACCOUNTING_CLOSURES,
    CAPABILITY_TREATMENTS,
    CAPABILITY_EXPECTATIONS,
    CAPABILITY_OPTIMIZATION,
    CAPABILITY_EQUILIBRIUM_CONCEPTS,
    CONCEPT_KINDS,
    CONCEPT_TIMINGS,
    CONCEPT_ENDOGENEITY,
    CONCEPT_OBSERVABILITY,
    ModelCapabilityProfile,
    ModelConceptDefinition,
    supports_api,
    has_sector,
    has_instrument,
    concept_definitions_equivalent,
    model_symbol,
    MODEL_CAPABILITY_REGISTRY,
    MODEL_CONCEPT_DEFINITION_REGISTRY,
    model_capabilities,
    concept_definitions,
    model_capability_profile_from_dict,
    model_capability_profile_from_json,
    model_concept_definition_from_dict,
    model_concept_definition_from_json,
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
#   _keen_build_pairs, _keen_objective, _keen_model_from_params, _nelder_mead,
#   _keen_weights, _keen_invalid_penalty, _keen_lcg, _keen_rand, _keen_dataset_metadata
#   _keen_variable_metrics, _keen_corr, _keen_turning_points, _keen_predict_over,
#   _keen_evaluate_model, _keen_run_sensitivity, _keen_model_diagnostics,
#   _keen_full_trajectory, _keen_json_safe, _keen_series_report,
#   _keen_add_split_marker!
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
using Dates
using SHA

# Data types: external data standard types
include("./data/data_series.jl")
include("./data/preprocess.jl")
include("./data/fred.jl")
include("./data/estat.jl")
include("./data/capex_credit_cycle_catalog.jl")
include("./data/keen_empirical.jl")

# Numerical utilities: grid types and interpolation
include("./numerics/grids.jl")
include("./numerics/interpolation.jl")

# Core abstractions: model interface, solver options
include("./core/model_interface.jl")
include("./core/solver_options.jl")

# イベント・シナリオ実行層の共通型（Issue #197 / `E-1`。統合設計 §4.1-4.2 の配置決定に従い
# models/ ブロックより前に置く純粋な共通層。stdlib Dates 以外へ依存しない。
# macro_events.jl（4層レコード型・語彙定数・PersistenceSpec・EventTiming）→ scenario_time.jl
# （CalendarQuarter・TimingRuleSet の型・暦四半期変換・時間形状6種。`shock_shape_path`/
# `resolve_t_apply` が macro_events.jl の型に依存するため #198 実装時にこの順へ修正した。
# macro_events.jl は scenario_time.jl の型を参照しないため安全）→ scenario_types.jl（Scenario・
# ScenarioWarning・EventRejection）→ event_scheduler.jl（全順序・固定順合成・schedule_events、
# Issue #198 / `E-2`）→ event_type_registry.jl（イベント型レジストリ・実体経済イベント型5種
# [Issue #199 / `E-3`]・信用・金融政策側イベント型4種 [Issue #200 / `E-4`]・型別 smart
# constructor。macro_events.jl の語彙定数・内部語彙のみに依存する）の順に依存する）
include("./scenarios/macro_events.jl")
include("./scenarios/scenario_time.jl")
include("./scenarios/scenario_types.jl")
include("./scenarios/event_scheduler.jl")
include("./scenarios/event_type_registry.jl")

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
include("./models/sfc_sim.jl")
include("./models/capex_credit_cycle.jl")

# Cross-model result type (depends on RamseyModel and RBCModel)
include("./core/simulation_result.jl")
include("./core/compare.jl")

# モデル能力プロファイル・概念定義 metadata（#149 / Phase 5。全モデル型に依存。
# llm 層より前に定義し cross_model_reasoning.jl から参照できるようにする）
include("./core/model_capabilities.jl")

# 比較 API v2（#150 / Phase 5。日付・単位・概念対応・比較可能性を明示。
# model_capabilities.jl の概念定義 registry に依存。v1 compare.jl は非破壊）
include("./core/compare_v2.jl")

# DME real-rate model artifact（Issue #159 / economic-data-provider ADR 006 準拠。
# depends on NewKeynesianModel, JSON3, SHA）
include("./artifacts/json_canonical.jl")
include("./artifacts/real_rate_model_artifact.jl")
include("./artifacts/real_rate_model_artifact_export.jl")

# Julia品質Export Contract v1（Issue #207 / software-quality-dashboard 連携。
# depends on canonical_json_bytes（json_canonical.jl）と _detect_git_commit_sha
# （real_rate_model_artifact_export.jl）。他のモデル層とは独立した CI/tooling メタデータ）
include("./quality/quality_export.jl")

# Pkg.test/Aqua.jl/JuliaFormatter.jl の実測結果を quality export の result へ組み立てる
# 純粋関数群（Issue #208）。Test.jl オブジェクトへの依存は test/ 側に限定する設計
# （quality_capture.jl 冒頭コメント参照）。depends on quality_export.jl（redact_secrets 等）
include("./quality/quality_capture.jl")

# Stable non-interactive CLI for orchestrators.  It is included after the quality
# export API because `dme quality-export` delegates persistence to that API.
include("./cli.jl")

# SFC 会計プリミティブ（会計表現をモデル方程式から分離。depends on SimulationResult）
include("./sfc/types.jl")
include("./sfc/serialization.jl")

# SFC 会計恒等式の検証エンジン（depends on sfc/types.jl。読み取り専用）
include("./analysis/sfc_accounting.jl")

# SIM 型 SFC モデルの adapter（depends on SIMModel・sfc/types.jl・sfc_accounting.jl。
# 水準系列 → SFCResult 構成 + 会計検証）
include("./analysis/sfc_sim_adapter.jl")

# 部門別CAPEX・信用循環モデルの会計層（depends on CapexCreditCycleModel・sfc/types.jl・
# sfc_accounting.jl。会計表構築 + 会計恒等式検証 12 項目。`SFCResult` は返さない）
include("./analysis/capex_credit_cycle_accounting.jl")

# 部門別CAPEX・信用循環モデルのシナリオ層（Issue #182 / `I-4`。depends on CapexCreditCycleModel
# のみ。Sc0–Sc4 の定義と外生パス合成。イベント実行層（Phase 2）との接続点は
# `capex_exogenous_paths` が返す `Dict{Symbol,Vector{Float64}}` の1点に限定する）
include("./analysis/capex_credit_cycle_scenarios.jl")

# 部門別CAPEX・信用循環モデルの診断層（Issue #183 / `I-5`。depends on CapexCreditCycleModel・
# capex_credit_cycle_accounting.jl（会計違反の併記）・capex_credit_cycle_scenarios.jl
# （delayed_containment の延長再実行）。診断ラベル・funding_pressure_s・ループ利得・非線形性近傍・
# 反実仮想。読み取り専用でモデル本体の動学に影響しない）
include("./analysis/capex_credit_cycle_diagnostics.jl")

# 部門別CAPEX・信用循環モデルのイベント mapping adapter（Issue #201 / `E-5`。depends on
# CapexCreditCycleModel・scenarios/macro_events.jl・scenario_time.jl・scenario_types.jl・
# analysis/capex_credit_cycle_scenarios.jl（`CapexShockSpec`・`capex_scenario`・
# `_ccc_persistence_spec`）。ScenarioAssumption（L3）→ AppliedModelInput（L4）変換と
# capex_scenario_assumptions（Sc0–Sc4 の L3 表現）を提供する）
include("./scenarios/adapters/capex_credit_cycle_event_adapter.jl")

# イベント・シナリオ実行層の再現契約・監査 dict・manifest 構築（Issue #203 / `E-7`。depends
# on artifacts/json_canonical.jl（canonical_json_bytes）・scenarios/scenario_types.jl
# （ScenarioProvenance）のみ。`ScenarioRun` 型へは依存しない。`event_set_hash`・
# `scenario_content_hash`・`params_hash`・`initial_state_id`・`solver_settings_hash`・
# `scenario_event_log`・型写像 encoder（`_scenario_hash_encode`）を提供する）
include("./scenarios/scenario_provenance.jl")

# イベント・シナリオ実行層の実行 API（Issue #202 / `E-6`。depends on CapexCreditCycleModel・
# scenarios/macro_events.jl・scenario_time.jl・scenario_types.jl・event_scheduler.jl・
# scenarios/adapters/capex_credit_cycle_event_adapter.jl（map_event）・
# analysis/capex_credit_cycle_accounting.jl（validate_capex_accounting）・
# analysis/capex_credit_cycle_diagnostics.jl（capex_diagnostics）・core/simulation_result.jl
# （to_simulation_result）・scenarios/scenario_provenance.jl（再現契約 hash）。
# Scenario → SimulationResult までを決定的な順序で実行する run_scenario を提供する)
include("./scenarios/scenario_runner.jl")

# イベント・シナリオ実行層の JSON シリアライズ・成果物保存・replay（Issue #203 / `E-7`。
# depends on scenarios/scenario_provenance.jl（hash・型写像 encoder）・
# scenarios/scenario_runner.jl（ScenarioRun・run_scenario）・artifacts/json_canonical.jl。
# `scenario_to_dict`/`scenario_from_dict`・`save_scenario_artifact`・`load_scenario`・
# `replay_scenario` を提供する)
include("./scenarios/scenario_serialization.jl")

# シナリオ比較診断（Issue #204 / `E-8`。depends on scenarios/scenario_types.jl・
# scenarios/scenario_runner.jl（ScenarioRun・run_scenario・ScenarioRunOptions）・
# scenarios/macro_events.jl（ScenarioAssumption・EventTiming）・core/simulation_result.jl
# （SimulationResult）・analysis/capex_credit_cycle_diagnostics.jl（CapexDiagnostics・
# CAPEX_CC_LOOP_IDS を任意引数としてのみ参照。capex_diagnostics 自体は変更しない）。
# `scenario_comparison`・`scenario_timing_sensitivity`・`scenario_magnitude_sensitivity` を
# 提供する読み取り専用層)
include("./analysis/scenario_diagnostics.jl")

# Minsky financing regime diagnostics (depends on KeenModel and SimulationResult)
include("./analysis/minsky_regimes.jl")

# Minsky continuous diagnostics & summary (depends on minsky_regimes.jl)
include("./analysis/minsky_diagnostics.jl")

# Keen 限定キャリブレーション（depends on KeenModel と KeenEmpiricalDataset）
include("./analysis/keen_calibration.jl")

# Keen 実証バリデーション・感応度分析（depends on keen_calibration.jl と minsky_diagnostics.jl）
include("./analysis/keen_validation.jl")

# Visualization (depends on SimulationResult)
include("./core/visualization.jl")

# Minsky visualization (depends on minsky_diagnostics.jl and Plots)
include("./analysis/minsky_visualization.jl")

# Keen 実証比較可視化（depends on keen_validation.jl と minsky_visualization.jl）
include("./analysis/keen_empirical_visualization.jl")

# 部門別CAPEX・信用循環モデルの可視化（Issue #185 / `I-7`。depends on capex_credit_cycle.jl・
# capex_credit_cycle_diagnostics.jl・core/visualization.jl の `_categorical_bands`）
include("./analysis/capex_credit_cycle_visualization.jl")

# Keen 実証コンテキスト（depends on keen_validation.jl と minsky_diagnostics.jl。
# AnalysisContext の optional field 型を提供するため analysis_context.jl より前に include）
include("./llm/keen_empirical_context.jl")

# LLM context layer (depends on SimulationResult, model interface, keen_empirical_context.jl)
include("./llm/analysis_context.jl")
include("./llm/doc_context.jl")
include("./llm/prompts.jl")
include("./llm/provider.jl")

# Keen 実証結果の根拠付き説明 API・専用 prompt（depends on keen_empirical_context.jl,
# prompts.jl の _DISCLAIMER_JA, provider.jl の complete_from_prompt）
include("./llm/keen_empirical_prompts.jl")

# クロスモデル推論層（#132 / ADR 0006。depends on keen_empirical_context.jl の EvidenceSource 等,
# keen_empirical_prompts.jl の EvidenceClaim/ExplanationSection/_KEEN_SEVERITY_RANK/_keen_fmt,
# analysis_context.jl の ModelMetadata, provider.jl の complete_from_prompt）
include("./llm/cross_model_reasoning.jl")

# Keen–SFC 概念対応・非対応と比較レポート層（#151 / Phase 5。depends on
# core/model_capabilities.jl（能力・概念定義 metadata）, core/compare_v2.jl（比較可能性判定）,
# analysis/sfc_accounting.jl（会計 check）, llm/cross_model_reasoning.jl（ADR 0006 の型・context））
include("./analysis/keen_sfc_comparison.jl")

end
