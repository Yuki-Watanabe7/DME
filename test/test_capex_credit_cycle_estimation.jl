# CCC 実証推定層の契約テスト（Issue #246 / P-6）。
# 受け入れ条件は docs/architecture/capex_credit_cycle_empirical_integration.md §12.5
# （項目 43–49）と Issue #246 本文の受け入れ条件。
#
# well-identified の回復テストと二重実装統制（§12.5-48）は **モデル生成データ** で行う
# （観測方程式の残差関数がモデル 1 期実行の中間値と一致することを、同一パラメータの回復で確認）。

using DME:
    capex_credit_cycle_default_targets,
    capex_credit_cycle_model,
    capex_run,
    build_capex_empirical_dataset,
    calibrate_capex_credit_cycle,
    diagnose_capex_identification,
    estimate_capex_block,
    capex_estimation_block,
    validate_capex_estimation_blocks,
    capex_parameter_set,
    capex_equation_residual,
    capex_estimation_config_to_dict,
    capex_estimation_config_from_dict,
    capex_block_estimate_to_dict,
    capex_parameter_set_to_dict,
    save_capex_parameter_set,
    save_capex_block_estimate,
    capex_est_param_bounds,
    CapexEstimationConfig,
    CapexBlockEstimate,
    CapexParameterSet,
    CapexEstimationBlockSpec,
    CAPEX_CC_ESTIMATION_STATUSES,
    CAPEX_CC_ESTIMATION_VERSION,
    CAPEX_CC_PARAMETER_SET_KINDS,
    CAPEX_CC_EST_PARAM_BOUNDS,
    CAPEX_CC_ESTIMATION_BLOCKS,
    CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
    CapexSeriesSpec,
    CapexRawObservation,
    CapexRawDataset,
    DataSeries,
    Quarterly

# ---------------------------------------------------------------------------
# fixture ヘルパ
# ---------------------------------------------------------------------------

function _estq_dates(start_label::String, n::Int)
    y0, q0 =
        parse(Int, split(start_label, "-Q")[1]), parse(Int, split(start_label, "-Q")[2])
    base = y0 * 4 + (q0 - 1)
    return [string(idx ÷ 4, "-Q", idx % 4 + 1) for idx in base:(base + n - 1)]
end

function _est_spec(
    key::Symbol;
    role::Symbol = :calibration_required,
    observability::Symbol = :D,
    methodology::Symbol = :direct,
    model_vars::Vector{Symbol} = [key],
)
    scope_bias = methodology === :proxy ? :over : :none
    ak = methodology === :allocation ? :sector_sales_share : nothing
    return CapexSeriesSpec(
        key = key,
        model_vars = model_vars,
        provider_series_id = uppercase(string(key)),
        provider = "TEST",
        source_kind = :official_statistic,
        role = role,
        observability = observability,
        methodology = methodology,
        declared_unit = "unit",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :real,
        declared_base_year = nothing,
        annualized = false,
        level_form = :level,
        anchor = nothing,
        sector_scope = "test scope",
        scope_bias = scope_bias,
        aggregation = :sum,
        model_timing = :SUM,
        allocation_key = ak,
        availability_start = "2000-Q1",
        notes = "estimation fixture entry",
    )
end

_est_obs(spec::CapexSeriesSpec, series::DataSeries) = CapexRawObservation(
    spec.key,
    spec,
    :ok,
    series,
    "unit",
    Quarterly,
    "SA",
    missing,
    String[],
    nothing,
    :fixture,
    "",
)

_est_series(key::Symbol, values::Vector{Float64}, dates::Vector{String}) = DataSeries(
    uppercase(string(key)),
    string(key),
    "TEST",
    Quarterly,
    "unit",
    dates,
    Vector{Union{Float64, Missing}}(values),
)

# entries: key => (values::Vector{Float64}, kwargs NamedTuple for _est_spec)
function _est_dataset(entries::Vector; start::String = "2010-Q1")
    n = maximum(length(v[1]) for v in (e[2] for e in entries))
    dates = _estq_dates(start, n)
    obs = CapexRawObservation[]
    for (k, payload) in entries
        vals, kw = payload
        length(vals) == n || error("fixture 系列 $k の長さが不揃いです")
        push!(obs, _est_obs(_est_spec(k; kw...), _est_series(k, vals, dates)))
    end
    raw = CapexRawDataset(
        Dict(o.key => o for o in obs),
        "test-catalog-v1",
        CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "",
        Dict{String, Any}(),
        Dict{String, Any}(),
    )
    return build_capex_empirical_dataset(raw; min_valid_obs = 8)
end

_wig(n; amp = 1.0, base = 100.0, phase = 0.0, slope = 0.3) =
    Float64[base + slope * t + amp * sinpi((t + phase) / 3.7) for t in 1:n]

# 既定ターゲットの定常水準から、逆較正が既定モデルと一致する定常 dataset を作る。
function _est_calibration()
    b = capex_credit_cycle_default_targets().values
    vals = Dict{Symbol, Float64}(
        :y_s1 => b.y_s1,
        :y_s2 => b.y_s2,
        :y_s3 => b.y_s3,
        :y_tot => b.y_s5 + b.va_s1 + b.va_s2 + b.va_s3,
        :util_s2 => b.util_s2,
        :util_s3 => b.util_s3,
        :emp_s1 => b.emp_s1,
        :emp_s2 => b.emp_s2,
        :emp_s3 => b.emp_s3,
        :emp_tot => b.emp_s5 + b.emp_s1 + b.emp_s2 + b.emp_s3,
        :cap_s1 => b.cap_s1,
        :cap_s2 => b.cap_s2,
        :cap_s3 => b.cap_s3,
        :dep_s1 => b.dep_s1,
        :dep_s2 => b.dep_s2,
        :dep_s3 => b.dep_s3,
        :order_cap_s2 => b.order_cap_s2,
        :order_cap_s3 => b.order_cap_s3,
        :order_inv_s3 => b.order_inv_s3,
        :order_s2 => b.y_s2 - b.order_cap_s2 - b.ext_demand_s2,
        :order_s3 => b.y_s3 - b.order_cap_s3 - b.order_inv_s3 - b.ext_demand_s3,
        :backlog_s2 => b.backlog_s2,
        :backlog_s3 => b.backlog_s3,
        :inv_s2 => b.inv_s2,
        :inv_s3 => b.inv_s3,
        :va_s1 => b.va_s1,
        :va_s2 => b.va_s2,
        :va_s3 => b.va_s3,
        :wagebill_s1 => b.wagebill_s1,
        :wagebill_s2 => b.wagebill_s2,
        :wagebill_s3 => b.wagebill_s3,
        :wagebill_tot => b.wagebill_s5 + b.wagebill_s1 + b.wagebill_s2 + b.wagebill_s3,
        :spread => b.spread,
        :policy_rate => b.policy_rate,
        :cons => b.cons,
        :debt_s1 => b.debt_s1,
        :debt_s2 => b.debt_s2,
        :debt_s3 => b.debt_s3,
        :cash_s1 => b.cash_s1,
        :cash_s2 => b.cash_s2,
        :cash_s3 => b.cash_s3,
        :capex_exec_s1 => b.dep_s1,
    )
    entries = Any[k => (fill(v, 12), (;)) for (k, v) in vals]
    ds = _est_dataset(entries; start = "2010-Q1")
    cal = calibrate_capex_credit_cycle(
        ds;
        baseline_start = "2010-Q1",
        baseline_end = "2012-Q4",
        literature = (
            cost_capital_intercept_s1 = b.cost_capital_s1 - b.spread / 100,
            cost_capital_intercept_s2 = b.cost_capital_s2 - b.spread / 100,
            cost_capital_intercept_s3 = b.cost_capital_s3 - b.spread / 100,
        ),
        assumptions = (cons_s1 = b.cons_s1,),
    )
    return cal
end

# モデルを既定ターゲットで構築し、評価区間で外生を揺らして run を得る。
# `demand` を true にすると ext_demand も揺らし、受注と出荷を脱共線化する（EB-3 の識別用）。
# `demand_amp` を大きくすると部門産出・雇用の変動も増える（EB-6 の識別用）。
function _est_model_run(;
    bump::Float64 = 1.5,
    demand::Bool = false,
    demand_amp::Float64 = 0.10,
)
    m = capex_credit_cycle_model(capex_credit_cycle_default_targets())
    n = 28
    exog = DME._ccc_baseline_exog(m, n)
    b2 = exog[:ext_demand_s2][1]
    b3 = exog[:ext_demand_s3][1]
    for i in 9:28
        exog[:policy_rate][i] += bump * sinpi(i / 5.0)
        if demand
            exog[:ext_demand_s2][i] = b2 * (1 + demand_amp * sinpi(i / 3.0))
            exog[:ext_demand_s3][i] = b3 * (1 + demand_amp * 0.8 * sinpi(i / 4.0 + 0.7))
        end
    end
    run = capex_run(m; exog = exog, validate_accounting = false, diagnostics = false)
    return m, run
end

# run.series の一部を CapexEmpiricalDataset にする（idx 範囲・モデル変数群を指定）。
function _est_dataset_from_run(run, mvars; rng::UnitRange{Int} = 5:28)
    n = length(rng)
    entries = Any[]
    for mv in mvars
        vals = Float64[run.series[mv][i] for i in rng]
        push!(entries, mv => (vals, (;)))
    end
    return _est_dataset(entries; start = "2010-Q1")
end

@testset "CCC 実証推定層（Issue #246 / P-6）" begin
    cal = _est_calibration()

    # -----------------------------------------------------------------------
    # config バリデーション（invalid initial value を含む）
    # -----------------------------------------------------------------------
    @testset "CapexEstimationConfig バリデーション" begin
        @test CapexEstimationConfig() isa CapexEstimationConfig
        @test_throws ArgumentError CapexEstimationConfig(; optimizer = :bfgs)
        @test_throws ArgumentError CapexEstimationConfig(; weight_mode = :inv_var)
        @test_throws ArgumentError CapexEstimationConfig(; n_starts = 0)
        @test_throws ArgumentError CapexEstimationConfig(; max_iterations = 0)
        @test_throws ArgumentError CapexEstimationConfig(; holdout_frac = 1.0)
        @test_throws ArgumentError CapexEstimationConfig(; standard_errors_supported = true)
        # invalid initial value（bounds 外）
        @test_throws ArgumentError CapexEstimationConfig(;
            initial_overrides = Dict(:bh_fc_pol => 999.0),
        )
        # invalid initial value（EST でないキー）
        @test_throws ArgumentError CapexEstimationConfig(;
            initial_overrides = Dict(:bh_util_max_s2 => 0.9),
        )
        # bounds 内は通る
        @test CapexEstimationConfig(; initial_overrides = Dict(:bh_fc_pol => 0.4)) isa
              CapexEstimationConfig
        # roundtrip
        c = CapexEstimationConfig(; seed = 123, n_starts = 3, range_grid = 11)
        c2 = capex_estimation_config_from_dict(capex_estimation_config_to_dict(c))
        @test c2.seed == 123
        @test c2.n_starts == 3
        @test c2.range_grid == 11
        @test capex_est_param_bounds(:bh_inv_adj_s2) == (0.0, 1.0)
        @test_throws ArgumentError capex_est_param_bounds(:bh_util_max_s2)
    end

    # -----------------------------------------------------------------------
    # §12.5-48: 残差関数の右辺がモデル 1 期実行の中間値と一致する（Z-15 二重実装統制）
    # -----------------------------------------------------------------------
    @testset "§12.5-48 二重実装統制: 残差関数 == モデル 1 期実行の中間値" begin
        m, run = _est_model_run()
        p = m.params
        S = run.series
        idx = 18
        cur = Dict(k => S[k][idx] for k in keys(S))
        lag = Dict(k => S[k][idx - 1] for k in keys(S))
        lag3 = Dict(:emp_tot => S[:emp_tot][idx - 3])

        @test isapprox(
            capex_equation_residual("E5-01", cur, lag, p),
            S[:fin_cond][idx];
            atol = 1e-9,
        )
        @test isapprox(
            capex_equation_residual("E5-06", cur, lag, p),
            S[:lend_stance][idx];
            atol = 1e-9,
        )
        @test isapprox(
            capex_equation_residual("E5-04", cur, lag, p),
            S[:spread_endo][idx];
            atol = 1e-9,
        )
        @test isapprox(
            capex_equation_residual("E5-02", cur, lag, p),
            S[:equity_val][idx];
            atol = 1e-9,
        )
        @test isapprox(
            capex_equation_residual("E5-03", cur, lag, p),
            S[:collateral][idx];
            atol = 1e-7,
        )
        @test isapprox(
            capex_equation_residual("E5-07", cur, lag, p),
            S[:rollover][idx];
            atol = 1e-9,
        )
        @test isapprox(
            capex_equation_residual("E9-16", cur, lag, p; sector = "s2"),
            S[:price_s2][idx];
            atol = 1e-9,
        )
        @test isapprox(
            capex_equation_residual("E10-09", cur, lag, p; lag3 = lag3),
            S[:wage][idx];
            atol = 1e-9,
        )
        @test isapprox(
            capex_equation_residual("E10-13", cur, lag, p),
            S[:cons][idx];
            atol = 1e-9,
        )

        # EB-3 の合成生産式（供給・能力制約が非拘束の期）
        if !run.binding[:capacity_binding_s2][idx] && !run.binding[:supply_binding_s2][idx]
            ypred = DME._ccc_resid_E9_06_07(
                S[:ship_s2][idx],
                S[:inv_s2][idx - 1],
                S[:inv_ratio_s2][idx - 1],
                p,
                "s2",
            )
            @test isapprox(ypred, S[:y_s2][idx]; atol = 1e-6)
        end

        @test_throws ArgumentError capex_equation_residual("E6-04", cur, lag, p)
    end

    # -----------------------------------------------------------------------
    # §12.5-43: :not_identified / :insufficient_data の推定要求は ArgumentError
    # -----------------------------------------------------------------------
    @testset "§12.5-43 推定不可ブロックの推定要求を拒否" begin
        n = 16
        # inv_s2 を欠く → EB-3 は :insufficient_data
        miss = _est_dataset([
            :inv_s3 => (_wig(n; amp = 3.0, base = 55.0), (;)),
            :ship_s2 => (_wig(n; amp = 5.0, base = 120.0, phase = 2.1), (;)),
            :ship_s3 => (_wig(n; amp = 6.0, base = 110.0, phase = 3.0), (;)),
            :order_s2 => (_wig(n; amp = 7.0, base = 125.0, phase = 0.7), (;)),
            :backlog_s2 => (_wig(n; amp = 8.0, base = 200.0, phase = 1.9), (;)),
        ])
        d_miss =
            first(d for d in diagnose_capex_identification(miss, cal) if d.block === :EB3)
        @test d_miss.status == :insufficient_data
        @test_throws ArgumentError estimate_capex_block(:EB3, miss, cal, d_miss)

        # 定数系列 → :not_identified
        const_ds = _est_dataset([
            :inv_s2 => (_wig(n; amp = 4.0, base = 60.0), (;)),
            :inv_s3 => (_wig(n; amp = 3.0, base = 55.0, phase = 1.3), (;)),
            :ship_s2 => (_wig(n; amp = 5.0, base = 120.0, phase = 2.1), (;)),
            :ship_s3 => (_wig(n; amp = 6.0, base = 110.0, phase = 3.0), (;)),
            :order_s2 => (fill(125.0, n), (;)),
            :backlog_s2 => (_wig(n; amp = 8.0, base = 200.0, phase = 1.9), (;)),
        ])
        d_const = first(
            d for d in diagnose_capex_identification(const_ds, cal) if d.block === :EB3
        )
        @test d_const.status == :not_identified
        @test_throws ArgumentError estimate_capex_block(:EB3, const_ds, cal, d_const)

        # diag.block ミスマッチ
        ok = _est_dataset([
            :inv_s2 => (_wig(n; amp = 4.0, base = 60.0), (;)),
            :inv_s3 => (_wig(n; amp = 3.0, base = 55.0, phase = 1.3), (;)),
            :ship_s2 => (_wig(n; amp = 5.0, base = 120.0, phase = 2.1), (;)),
            :ship_s3 => (_wig(n; amp = 6.0, base = 110.0, phase = 3.0), (;)),
            :order_s2 => (_wig(n; amp = 7.0, base = 125.0, phase = 0.7), (;)),
            :backlog_s2 => (_wig(n; amp = 8.0, base = 200.0, phase = 1.9), (;)),
        ])
        diags_ok = diagnose_capex_identification(ok, cal)
        eb1d = first(d for d in diags_ok if d.block === :EB1)
        @test_throws ArgumentError estimate_capex_block(:EB3, ok, cal, eb1d)
    end

    # -----------------------------------------------------------------------
    # §12.5-46: 非 EST を est_params に入れると validator が拒否（estimate 入口が呼ぶ）
    # -----------------------------------------------------------------------
    @testset "§12.5-46 パラメータ区分違反を validator が拒否" begin
        eb3 = capex_estimation_block(:EB3)
        bad = CapexEstimationBlockSpec(
            eb3.id,
            eb3.order,
            vcat(eb3.est_params, [:bh_util_max_s2]),  # CAL-OBS
            eb3.fixed_params,
            eb3.required_keys,
            eb3.supporting_keys,
            eb3.equation_ids,
            eb3.identification_risks,
            eb3.preassigned_actions,
        )
        @test_throws ArgumentError validate_capex_estimation_blocks([bad]; full = false)
    end

    # -----------------------------------------------------------------------
    # well-identified: EB-1 の金融パラメータをモデル生成データから点推定で回復する
    # （EB-1 は required 系列が金融系列のみで、単一方程式ごとに逐次識別できる。#170 §7.4）
    # -----------------------------------------------------------------------
    @testset "well-identified: EB-1 点推定回復（モデル生成データ）" begin
        m, run = _est_model_run(; bump = 1.5)
        eds = _est_dataset_from_run(
            run,
            [:fin_cond, :policy_rate, :spread, :lend_stance, :coverage_agg],
        )
        diags = diagnose_capex_identification(eds, cal)
        eb1d = first(d for d in diags if d.block === :EB1)
        est = estimate_capex_block(:EB1, eds, cal, eb1d)
        @test est isa CapexBlockEstimate
        @test est.status in CAPEX_CC_ESTIMATION_STATUSES
        @test est.status in (:converged, :boundary_solution)
        @test est.standard_errors_supported == false
        @test !isempty(est.starts)
        @test est.n_obs_used > 0
        # bh_fc_pol（E5-01）・bh_lend_spread（E5-06）は直接観測から識別 → モデル真値を回復
        @test haskey(est.estimated, :bh_fc_pol)
        @test haskey(est.estimated, :bh_lend_spread)
        @test isapprox(est.estimated[:bh_fc_pol], m.params.bh_fc_pol; atol = 0.05)
        @test isapprox(
            est.estimated[:bh_lend_spread],
            m.params.bh_lend_spread;
            atol = 0.005,
        )
        # bounds 制約の結果であって post-hoc クリップではない
        for (p, v) in est.estimated
            b = CAPEX_CC_EST_PARAM_BOUNDS[p]
            @test b[1] - 1e-9 <= v <= b[2] + 1e-9
        end
        # objective 改善は経済的妥当性と分けて報告する（ADR 0018 決定11）
        @test est.objective_value <= est.literature_objective + 1e-6
    end

    # -----------------------------------------------------------------------
    # EB-3: 定常近傍では required 系列が共線的で弱識別 → W2 範囲へ降格。
    # 範囲報告のグリッド走査が真値へ収束することを確認する（点推定を捏造しない）。
    # -----------------------------------------------------------------------
    @testset "EB-3: 弱識別 → W2 範囲（範囲が真値へ収束する）" begin
        m, run = _est_model_run(; bump = 1.0, demand = true)
        eds = _est_dataset_from_run(
            run,
            [:inv_s2, :inv_s3, :ship_s2, :ship_s3, :order_s2, :backlog_s2],
        )
        diags = diagnose_capex_identification(eds, cal)
        eb3d = first(d for d in diags if d.block === :EB3)
        est = estimate_capex_block(:EB3, eds, cal, eb3d)
        @test est.status in (:demoted, :converged, :boundary_solution)
        for p in (:bh_inv_adj_s2, :bh_inv_adj_s3, :bh_prod_cut_s2, :bh_prod_cut_s3)
            @test haskey(est.estimated, p) || haskey(est.ranges, p)
        end
        # bh_inv_adj_s は在庫変動から識別可能 → 点推定 or W2 範囲が真値（0.3）を含む
        for (p, tv) in (
            (:bh_inv_adj_s2, m.params.bh_inv_adj_s2),
            (:bh_inv_adj_s3, m.params.bh_inv_adj_s3),
        )
            if haskey(est.estimated, p)
                @test isapprox(est.estimated[p], tv; atol = 0.05)
            else
                lo, hi = est.ranges[p]
                @test lo - 0.05 <= tv <= hi + 0.05
            end
        end
    end

    # -----------------------------------------------------------------------
    # EB-6: bh_wage_slope（E10-09）は点推定、emp 調整速度 8 個は W4（感応度のみ）
    # -----------------------------------------------------------------------
    @testset "EB-6: bh_wage_slope 点推定 + emp パラメータは W4" begin
        m, run = _est_model_run(; bump = 1.0, demand = true, demand_amp = 0.25)
        eds = _est_dataset_from_run(run, [:emp_s1, :emp_s2, :emp_s3, :emp_tot, :wage])
        diags = diagnose_capex_identification(eds, cal)
        eb6d = first(d for d in diags if d.block === :EB6)
        if eb6d.status in (:not_identified, :insufficient_data)
            # 雇用が動かない regime では推定を拒否する（§12.5-43）
            @test_throws ArgumentError estimate_capex_block(:EB6, eds, cal, eb6d)
        else
            est = estimate_capex_block(:EB6, eds, cal, eb6d)
            @test est.status in CAPEX_CC_ESTIMATION_STATUSES
            # bh_wage_slope は emp_tot[t-3] と wage の関係から識別
            @test haskey(est.estimated, :bh_wage_slope) ||
                  haskey(est.ranges, :bh_wage_slope)
            # emp 上下調整速度は EB-6 の required 集合外の系列を要する → W4
            for s in ("s1", "s2", "s3", "s5")
                for pre in ("bh_emp_up_", "bh_emp_down_")
                    p = Symbol(pre, s)
                    @test est.demoted[p] == :W4
                    @test haskey(est.ranges, p)
                end
            end
        end
    end

    # -----------------------------------------------------------------------
    # EB-1: 3 本の金融パラメータを点推定、bh_spread_cov は W2 範囲報告
    # -----------------------------------------------------------------------
    @testset "EB-1: 点推定 3 本 + bh_spread_cov は W2 範囲" begin
        m, run = _est_model_run(; bump = 2.0)
        eds = _est_dataset_from_run(
            run,
            [:fin_cond, :policy_rate, :spread, :lend_stance, :coverage_agg],
        )
        diags = diagnose_capex_identification(eds, cal)
        eb1d = first(d for d in diags if d.block === :EB1)
        est = estimate_capex_block(:EB1, eds, cal, eb1d)
        @test :bh_fc_pol in keys(est.estimated)
        @test :bh_lend_spread in keys(est.estimated)
        @test !haskey(est.estimated, :bh_spread_cov)       # W2 armed → 点推定しない
        @test haskey(est.ranges, :bh_spread_cov)
        @test est.demoted[:bh_spread_cov] == :W2
        lo, hi = est.ranges[:bh_spread_cov]
        @test lo <= hi
        # bh_fc_pol の真値は 0.5。回復は緩い許容で確認（proxy なし・直接観測）
        @test isapprox(est.estimated[:bh_fc_pol], m.params.bh_fc_pol; atol = 0.15)
    end

    # -----------------------------------------------------------------------
    # §12.5-47: 境界張り付き・非収束・非有限 objective が別 status（post-hoc クリップなし）
    # -----------------------------------------------------------------------
    @testset "§12.5-47 boundary solution（合成データで下限に張り付く）" begin
        n = 20
        # モデル機構に従わない wiggly データ → bh_inv_adj は 0 付近へ
        eds = _est_dataset([
            :inv_s2 => (_wig(n; amp = 4.0, base = 60.0, phase = 0.0), (;)),
            :inv_s3 => (_wig(n; amp = 3.0, base = 55.0, phase = 1.3), (;)),
            :ship_s2 =>
                (_wig(n; amp = 5.0, base = 120.0, phase = 2.1, slope = 0.5), (;)),
            :ship_s3 =>
                (_wig(n; amp = 6.0, base = 110.0, phase = 3.0, slope = 0.4), (;)),
            :order_s2 =>
                (_wig(n; amp = 7.0, base = 125.0, phase = 0.7, slope = 0.6), (;)),
            :backlog_s2 =>
                (_wig(n; amp = 8.0, base = 200.0, phase = 1.9, slope = 0.2), (;)),
        ])
        diags = diagnose_capex_identification(eds, cal)
        eb3d = first(d for d in diags if d.block === :EB3)
        est = estimate_capex_block(:EB3, eds, cal, eb3d)
        @test est.status == :boundary_solution
        @test !isempty(est.boundary_hits)
        # 端の値が bounds を超えていない（クリップではなく制約の結果）
        for (p, v) in est.estimated
            b = CAPEX_CC_EST_PARAM_BOUNDS[p]
            @test b[1] - 1e-9 <= v <= b[2] + 1e-9
        end
    end

    @testset "§12.5-47 非収束（max_iterations=1）" begin
        m, run = _est_model_run(; bump = 1.5)
        eds = _est_dataset_from_run(
            run,
            [:fin_cond, :policy_rate, :spread, :lend_stance, :coverage_agg],
        )
        diags = diagnose_capex_identification(eds, cal)
        eb1d = first(d for d in diags if d.block === :EB1)
        est = estimate_capex_block(
            :EB1,
            eds,
            cal,
            eb1d;
            config = CapexEstimationConfig(;
                max_iterations = 1,
                n_starts = 1,
                initial_overrides = Dict(
                    :bh_fc_pol => 3.0,
                    :bh_lend_spread => 0.5,
                    :bh_spread_fc => 200.0,
                ),
            ),
        )
        @test est.status in (:not_converged, :boundary_solution)
        est.status == :not_converged && @test !est.converged
    end

    # -----------------------------------------------------------------------
    # 降格ブロック（EB-2 / EB-4 / EB-5 / EB-7）: status :demoted・点推定なし・範囲あり
    # -----------------------------------------------------------------------
    @testset "降格: EB-4（util proxy）は :demoted で W2 範囲を返す" begin
        n = 20
        eds = _est_dataset([
            :price_s2 =>
                (_wig(n; amp = 0.05, base = 1.0, phase = 0.2, slope = 0.0), (;)),
            :price_s3 =>
                (_wig(n; amp = 0.04, base = 1.0, phase = 1.7, slope = 0.0), (;)),
            :util_s2 => (
                _wig(n; amp = 0.06, base = 0.8, phase = 0.9),
                (observability = :P, methodology = :proxy),
            ),
            :util_s3 => (
                _wig(n; amp = 0.05, base = 0.78, phase = 2.6),
                (observability = :P, methodology = :proxy),
            ),
        ])
        diags = diagnose_capex_identification(eds, cal)
        eb4d = first(d for d in diags if d.block === :EB4)
        @test eb4d.status == :weakly_identified
        est = estimate_capex_block(:EB4, eds, cal, eb4d)
        @test est.status == :demoted
        @test isempty(est.estimated)
        for p in eb4d.est_params
            @test haskey(est.ranges, p)
            @test est.demoted[p] == :W2
        end
    end

    @testset "降格: EB-2（潜在 LHS）は :demoted・範囲は bounds" begin
        n = 20
        eds = _est_dataset([
            :spread => (_wig(n; amp = 30.0, base = 250.0), (;)),
            :equity_val => (_wig(n; amp = 0.1, base = 1.0, phase = 1.4), (;)),
            :policy_rate => (_wig(n; amp = 0.6, base = 2.0, phase = 3.1), (;)),
        ])
        diags = diagnose_capex_identification(eds, cal)
        eb2d = first(d for d in diags if d.block === :EB2)
        est = estimate_capex_block(:EB2, eds, cal, eb2d)
        @test est.status == :demoted
        @test isempty(est.estimated)
        for p in (:bh_ev_elas, :bh_coll_elas, :bh_roll_slope)
            @test est.ranges[p] == CAPEX_CC_EST_PARAM_BOUNDS[p]
            @test est.demoted[p] == :W2
        end
        # fixed_params 上の W1 は reasons に残る（est_params ではない）
        @test any(r -> occursin("bh_cc_lend", r), est.reasons)
    end

    @testset "降格: EB-5（ai_exp）は W3 複数仕様を返す" begin
        n = 20
        eds = _est_dataset([
            :capex_exec_s1 => (_wig(n; amp = 1.0, base = 15.0, phase = 0.4), (;)),
            :spread => (_wig(n; amp = 30.0, base = 250.0, phase = 1.1), (;)),
            :lend_stance => (_wig(n; amp = 0.4, base = 0.0, phase = 2.3), (;)),
            :fin_cond => (_wig(n; amp = 0.5, base = 0.0, phase = 0.0), (;)),
        ])
        diags = diagnose_capex_identification(eds, cal)
        eb5d = first(d for d in diags if d.block === :EB5)
        est = estimate_capex_block(:EB5, eds, cal, eb5d)
        @test est.status == :demoted
        @test haskey(est.alternate_specs, :bh_alpha_capex_s1)
        @test length(est.alternate_specs[:bh_alpha_capex_s1]) == 3
        @test haskey(est.ranges, :bh_cc_elas_s1)
    end

    # -----------------------------------------------------------------------
    # §12.5-49: 同一 fixture / config から同一 parameter_set_hash（seed を含む決定性）
    # -----------------------------------------------------------------------
    @testset "§12.5-49 決定的再実行" begin
        m, run = _est_model_run(; bump = 1.5)
        eds = _est_dataset_from_run(
            run,
            [:fin_cond, :policy_rate, :spread, :lend_stance, :coverage_agg],
        )
        diags = diagnose_capex_identification(eds, cal)
        eb1d = first(d for d in diags if d.block === :EB1)

        e1 = estimate_capex_block(:EB1, eds, cal, eb1d)
        e2 = estimate_capex_block(:EB1, eds, cal, eb1d)
        @test e1.estimated == e2.estimated
        @test isequal(e1.objective_value, e2.objective_value)
        @test e1.ranges == e2.ranges
        @test e1.block_spec_hash == e2.block_spec_hash

        ps1 = capex_parameter_set(cal, diags, [e1]; kind = :estimated)
        ps2 = capex_parameter_set(cal, diags, [e2]; kind = :estimated)
        @test ps1.parameter_set_hash == ps2.parameter_set_hash

        # config を変えると parameter_set_hash も変わる（config は hash 対象。§11.3）
        ps3 = capex_parameter_set(
            cal,
            diags,
            [e1];
            kind = :estimated,
            config = CapexEstimationConfig(; seed = 999),
        )
        @test ps3.parameter_set_hash != ps1.parameter_set_hash
    end

    # -----------------------------------------------------------------------
    # CapexParameterSet: 由来別フィールドの分離と serialization
    # -----------------------------------------------------------------------
    @testset "parameter set: literature/default・calibrated・estimated の分離" begin
        m, run = _est_model_run(; bump = 1.5, demand = true)
        eds1 = _est_dataset_from_run(
            run,
            [:fin_cond, :policy_rate, :spread, :lend_stance, :coverage_agg],
        )
        eds3 = _est_dataset_from_run(
            run,
            [:inv_s2, :inv_s3, :ship_s2, :ship_s3, :order_s2, :backlog_s2],
        )
        diags1 = diagnose_capex_identification(eds1, cal)
        diags3 = diagnose_capex_identification(eds3, cal)
        eb1d = first(d for d in diags1 if d.block === :EB1)
        eb3d = first(d for d in diags3 if d.block === :EB3)
        e1 = estimate_capex_block(:EB1, eds1, cal, eb1d)
        e3 = estimate_capex_block(:EB3, eds3, cal, eb3d)

        # kind = :estimated には estimates が必須
        @test_throws ArgumentError capex_parameter_set(cal, diags1; kind = :estimated)
        @test_throws ArgumentError capex_parameter_set(
            cal,
            diags1,
            CapexBlockEstimate[];
            kind = :estimated,
        )
        @test_throws ArgumentError capex_parameter_set(cal, diags1, [e1]; kind = :bogus)
        # 同一 block 重複は拒否
        @test_throws ArgumentError capex_parameter_set(
            cal,
            diags1,
            [e1, e1];
            kind = :estimated,
        )

        ps_lit = capex_parameter_set(cal, diags1; kind = :literature_default)
        ps_cal = capex_parameter_set(cal, diags1; kind = :calibrated)
        ps_est = capex_parameter_set(cal, diags1, [e1, e3]; kind = :estimated)

        @test ps_lit.kind == :literature_default
        @test isempty(ps_lit.estimated)
        @test haskey(ps_lit.literature_default, :bh_inv_adj_s2)
        @test haskey(ps_lit.calibrated, :st_delta_s2)

        @test ps_est.kind == :estimated
        @test haskey(ps_est.estimated, :bh_fc_pol)          # EB-1 点推定
        # literature/default と estimated は別フィールド（由来不明の混在を作らない）
        @test ps_est.literature_default[:bh_fc_pol] ==
              DME._ccc_default_behavioral().bh_fc_pol
        @test ps_est.parameter_source[:bh_fc_pol] == :estimated
        @test ps_est.parameter_source[:st_delta_s2] == :calibrated
        @test ps_est.parameter_source[:pl_tau] == :fixed
        # 推定不能な EST は既定/較正のまま残り、由来で区別できる
        @test ps_est.parameter_source[:bh_spread_cov] in
              (:demoted_W2, :demoted_W4, :literature_default)
        @test ps_est.parameter_source[:bh_inv_adj_s2] in
              (:estimated, :demoted_W2, :demoted_W4)

        # serialization
        d = capex_parameter_set_to_dict(ps_est)
        @test d["kind"] == "estimated"
        @test haskey(d, "literature_default")
        @test haskey(d, "calibrated")
        @test haskey(d, "estimated")
        @test haskey(d, "parameter_source")
        @test startswith(d["parameter_set_hash"], "sha256:")
        @test length(d["block_estimates"]) == 2

        de = capex_block_estimate_to_dict(e1)
        @test de["standard_errors_supported"] == false
        @test haskey(de, "curvature")

        mktempdir() do dir
            p1 = save_capex_parameter_set(joinpath(dir, "ps.json"), ps_est)
            @test isfile(p1)
            g = DME.JSON3.read(read(p1, String))
            @test g["estimation_version"] == CAPEX_CC_ESTIMATION_VERSION
            p2 = save_capex_block_estimate(joinpath(dir, "eb1.json"), e1)
            @test isfile(p2)
        end
    end

    # -----------------------------------------------------------------------
    # holdout_frac: 末尾を objective から除外し metadata に残す
    # -----------------------------------------------------------------------
    @testset "holdout_frac は末尾を objective から除外する" begin
        m, run = _est_model_run(; bump = 1.5)
        eds = _est_dataset_from_run(
            run,
            [:fin_cond, :policy_rate, :spread, :lend_stance, :coverage_agg],
        )
        diags = diagnose_capex_identification(eds, cal)
        eb1d = first(d for d in diags if d.block === :EB1)
        est_full = estimate_capex_block(:EB1, eds, cal, eb1d)
        est_hold = estimate_capex_block(
            :EB1,
            eds,
            cal,
            eb1d;
            config = CapexEstimationConfig(; holdout_frac = 0.3),
        )
        @test est_hold.n_obs_used < est_full.n_obs_used
        @test est_hold.metadata["holdout_frac"] == 0.3
    end
end
