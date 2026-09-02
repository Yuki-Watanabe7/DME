# CCC 実証較正層の契約テスト（Issue #244 / P-4）。
# 受け入れ条件は docs/architecture/capex_credit_cycle_empirical_integration.md §12.4（項目 29–38）
# と Issue #244 本文の受け入れ条件。

using DME:
    build_capex_empirical_dataset,
    build_capex_steady_state_targets,
    calibrate_capex_credit_cycle,
    capex_parameter_class,
    capex_parameter_provenance,
    capex_calibration_to_dict,
    save_capex_calibration,
    CapexEmpiricalCalibration,
    CapexTargetSpec,
    CAPEX_CC_TARGET_SOURCE_KINDS,
    CAPEX_CC_PARAMETER_CLASSES,
    CAPEX_CC_PARAMETER_DICT_PLACEHOLDERS,
    CAPEX_CC_STRUCTURAL_OVERRIDABLE,
    CAPEX_CC_TARGET_KEYS,
    CAPEX_CC_PARAMETER_NAMES,
    CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
    CapexSeriesSpec,
    CapexRawObservation,
    CapexRawDataset,
    DataSeries,
    Quarterly,
    capex_credit_cycle_default_targets,
    capex_credit_cycle_model,
    CapexCreditCycleTargets,
    parameters,
    passed

# ---------------------------------------------------------------------------
# fixture: 定常水準ターゲットを再現する合成 observation dataset
# ---------------------------------------------------------------------------

function _calibq_dates(start_label::String, n::Int)
    y0, q0 =
        parse(Int, split(start_label, "-Q")[1]), parse(Int, split(start_label, "-Q")[2])
    base = y0 * 4 + (q0 - 1)
    return [string(idx ÷ 4, "-Q", idx % 4 + 1) for idx in base:(base + n - 1)]
end

function _calib_spec(
    key::Symbol;
    role::Symbol = :calibration_required,
    model_vars::Vector{Symbol} = [key],
    methodology::Symbol = :direct,
    observability::Symbol = :D,
    scope_bias::Symbol = :none,
    allocation_key::Union{Symbol, Nothing} = nothing,
)
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
        allocation_key = allocation_key,
        availability_start = "2000-Q1",
        notes = "calibration fixture entry",
    )
end

function _calib_obs(spec::CapexSeriesSpec, series::Union{DataSeries, Nothing}; status = :ok)
    return CapexRawObservation(
        spec.key,
        spec,
        status,
        series,
        series === nothing ? missing : "unit",
        series === nothing ? missing : Quarterly,
        "SA",
        missing,
        String[],
        nothing,
        :fixture,
        "",
    )
end

function _calib_series(key::Symbol, values::Vector{Float64}, dates::Vector{String})
    return DataSeries(
        uppercase(string(key)),
        string(key),
        "TEST",
        Quarterly,
        "unit",
        dates,
        Vector{Union{Float64, Missing}}(values),
    )
end

# key => constant value（16 四半期一定）または key => Vector{Float64}（可変）
function _calib_dataset(
    values::AbstractDict;
    n_quarters::Int = 16,
    start::String = "2014-Q1",
    specs_override::AbstractDict = Dict{Symbol, CapexSeriesSpec}(),
)
    dates = _calibq_dates(start, n_quarters)
    obs = CapexRawObservation[]
    for (k, v) in values
        spec = get(specs_override, k, _calib_spec(k))
        series =
            v isa AbstractVector ? _calib_series(k, Float64.(collect(v)), dates) :
            _calib_series(k, fill(Float64(v), n_quarters), dates)
        push!(obs, _calib_obs(spec, series))
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

# capex_credit_cycle_default_targets を再現する observation 値・literature・assumptions
function _calib_roundtrip_inputs()
    b = capex_credit_cycle_default_targets().values
    values = Dict{Symbol, Float64}(
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
    literature = (
        cost_capital_intercept_s1 = b.cost_capital_s1 - b.spread / 100,
        cost_capital_intercept_s2 = b.cost_capital_s2 - b.spread / 100,
        cost_capital_intercept_s3 = b.cost_capital_s3 - b.spread / 100,
    )
    assumptions = (cons_s1 = b.cons_s1,)
    return values, literature, assumptions
end

const _CALIB_BSTART = "2015-Q1"
const _CALIB_BEND = "2016-Q4"

@testset "CCC 実証較正層（Issue #244 / P-4）" begin
    rt_values, rt_lit, rt_asm = _calib_roundtrip_inputs()
    ds = _calib_dataset(rt_values)
    cal = calibrate_capex_credit_cycle(
        ds;
        baseline_start = _CALIB_BSTART,
        baseline_end = _CALIB_BEND,
        literature = rt_lit,
        assumptions = rt_asm,
    )

    @testset "§12.4-29 48 キーすべてに CapexTargetSpec と source_kind" begin
        @test Set(keys(cal.target_specs)) == Set(CAPEX_CC_TARGET_KEYS)
        for k in CAPEX_CC_TARGET_KEYS
            s = cal.target_specs[k]
            @test s isa CapexTargetSpec
            @test s.key == k
            @test s.source_kind in CAPEX_CC_TARGET_SOURCE_KINDS
            @test s.timing in (:SUM, :AVG, :EOP)
        end
        # 分類の帰結（§8.2）
        @test cal.target_specs[:y_s5].source_kind == :derived
        @test cal.target_specs[:capex_pipe_s1].source_kind == :literature
        @test cal.target_specs[:cost_capital_s1].source_kind == :literature
        @test cal.target_specs[:cons_s1].source_kind == :assumption
        @test cal.target_specs[:spread].source_kind == :observed
        @test occursin("RESIDUAL", cal.target_specs[:ext_demand_s2].formula)
    end

    @testset "§12.4-30 literature に reference が無ければ default_unattributed" begin
        # pipelag は既定（literature 未指定）→ default_unattributed
        @test cal.target_specs[:capex_pipe_s1].reference == "default_unattributed"
        @test cal.target_specs[:capex_pipe_s3].reference == "default_unattributed"
        # cost_capital は intercept を literature で与えた → reference 非空
        @test !isempty(cal.target_specs[:cost_capital_s1].reference)
        @test cal.target_specs[:cost_capital_s1].reference != "default_unattributed"
    end

    @testset "§12.4-31 structural に非上書きキーを渡すと ArgumentError" begin
        t = capex_credit_cycle_default_targets()
        @test_throws ArgumentError capex_credit_cycle_model(
            t;
            structural = (st_delta_s1 = 0.05,),
        )
        @test_throws ArgumentError capex_credit_cycle_model(
            t;
            structural = (st_va_share_s1 = 0.5,),
        )
        err = try
            capex_credit_cycle_model(t; structural = (st_cor_s2 = 3.0,))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("structural_override_conflict", err.msg)
        # 上書き可能キーは通る
        m = capex_credit_cycle_model(t; structural = (st_cor_s1 = 2.5, st_cshare_s3 = 0.28))
        @test parameters(m).st_cor_s1 == 2.5
        @test parameters(m).st_cshare_s3 == 0.28
        # CAL-SS は上書き集合に含まれない
        for k in (:st_cor_s2, :st_delta_s1, :st_va_share_s1, :st_gen_share_s2, :st_cc0_s1)
            @test !(k in CAPEX_CC_STRUCTURAL_OVERRIDABLE)
        end
    end

    @testset "§12.4-32 structural を渡さないと非破壊" begin
        t = capex_credit_cycle_default_targets()
        m0 = capex_credit_cycle_model(t)
        m1 = capex_credit_cycle_model(t; structural = NamedTuple())
        @test parameters(m0) == parameters(m1)
        @test length(parameters(m0)) == 147
    end

    @testset "§12.4-33 synthetic 互換 fixture で #179 の逆較正結果と一致" begin
        # build したターゲットが default と一致
        for k in CAPEX_CC_TARGET_KEYS
            @test isapprox(
                getproperty(cal.targets.values, k),
                getproperty(capex_credit_cycle_default_targets().values, k);
                rtol = 1e-9,
                atol = 1e-9,
            )
        end
        # 逆較正パラメータが既存経路と一致
        ref = capex_credit_cycle_model(capex_credit_cycle_default_targets())
        got = parameters(cal.model)
        @test Set(keys(got)) == Set(keys(parameters(ref)))
        for k in keys(parameters(ref))
            @test isapprox(got[k], parameters(ref)[k]; rtol = 1e-6, atol = 1e-9)
        end
        # 合成互換なら structural override は空（実装既定・閉形式に任せる）
        @test isempty(cal.structural_overrides)
        @test passed(cal.steady_state_report)
        @test isempty(cal.ss_inconsistent)
    end

    @testset "§12.4-34 SS 違反は ss_inconsistent へ構造化・自動補正しない" begin
        bad = copy(rt_values)
        for k in (:va_s1, :va_s2, :va_s3, :wagebill_s1, :wagebill_s2, :wagebill_s3)
            bad[k] = rt_values[k] * 2
        end
        bad[:wagebill_tot] =
            capex_credit_cycle_default_targets().values.wagebill_s5 +
            bad[:wagebill_s1] +
            bad[:wagebill_s2] +
            bad[:wagebill_s3]
        ds_bad = _calib_dataset(bad)
        cal_bad = calibrate_capex_credit_cycle(
            ds_bad;
            baseline_start = _CALIB_BSTART,
            baseline_end = _CALIB_BEND,
            literature = rt_lit,
            assumptions = rt_asm,
        )
        @test !passed(cal_bad.steady_state_report)
        @test !isempty(cal_bad.ss_inconsistent)
        @test all(startswith(c, "SS-") for c in cal_bad.ss_inconsistent)
        # 破れた条件が report にそのまま残る（補正されていない）
        for c in cal_bad.ss_inconsistent
            @test cal_bad.steady_state_report.checks[c].passed == false
        end
        @test any(occursin("ss_inconsistent", w) for w in cal_bad.warnings)
    end

    @testset "§12.4-35 自由度なし整合条件の乖離が ss_residual へ" begin
        perturbed = copy(rt_values)
        perturbed[:capex_exec_s1] = rt_values[:capex_exec_s1] + 1.5   # dep_s1 とずらす
        ds_p = _calib_dataset(perturbed)
        cal_p = calibrate_capex_credit_cycle(
            ds_p;
            baseline_start = _CALIB_BSTART,
            baseline_end = _CALIB_BEND,
            literature = rt_lit,
            assumptions = rt_asm,
        )
        @test haskey(cal_p.ss_residual, "capex_exec_s1")
        @test isapprox(cal_p.ss_residual["capex_exec_s1"], 1.5; atol = 1e-9)
        # baseline 一致 fixture では乖離ゼロ
        @test isapprox(cal.ss_residual["capex_exec_s1"], 0.0; atol = 1e-9)
    end

    @testset "§12.4-36 SCN / SENS パラメータは較正で上書きされない" begin
        p = parameters(cal.model)
        @test p.st_maturity_s1 == 5.0
        @test p.st_maturity_s2 == 5.0
        @test p.st_maturity_s3 == 5.0
        @test p.st_commit_s1 == 0.5
        @test p.st_cor_s1 == 2.0
        @test p.pl_ltv == 0.7
        @test p.bh_price_elas_s2 == 0.3
        for k in keys(cal.structural_overrides)
            @test capex_parameter_class(k) != :SENS
        end
    end

    @testset "§12.4-37 parameter_provenance が 147 全てに区分（欠落・重複なし）" begin
        prov = cal.parameter_provenance
        @test Set(keys(prov)) == Set(CAPEX_CC_PARAMETER_NAMES)
        placeholders = Set(CAPEX_CC_PARAMETER_DICT_PLACEHOLDERS)
        for n in CAPEX_CC_PARAMETER_NAMES
            if n in placeholders
                @test prov[n] == :dict_placeholder     # #170 §16.5（正本）
            else
                @test prov[n] in CAPEX_CC_PARAMETER_CLASSES
            end
        end
        # EST 総数 = 35（実証統合設計 §8.4）
        @test count(==(:EST), values(prov)) == 35
        @test count(==(:dict_placeholder), values(prov)) == 5
        # capex_parameter_provenance() は cal と同じ（静的）
        @test capex_parameter_provenance() == prov
    end

    @testset "§12.4-38 同一 dataset から同一 targets_hash" begin
        cal2 = calibrate_capex_credit_cycle(
            _calib_dataset(rt_values);
            baseline_start = _CALIB_BSTART,
            baseline_end = _CALIB_BEND,
            literature = rt_lit,
            assumptions = rt_asm,
        )
        @test cal2.targets_hash == cal.targets_hash
        @test cal2.dataset_hash == cal.dataset_hash
        @test startswith(cal.targets_hash, "sha256:")
        # dict 化・保存が決定的
        d1 = capex_calibration_to_dict(cal)
        d2 = capex_calibration_to_dict(cal2)
        @test d1["targets_hash"] == d2["targets_hash"]
        @test d1["parameters"] == d2["parameters"]
        mktempdir() do dir
            p = save_capex_calibration(joinpath(dir, "cal.json"), cal)
            @test isfile(p)
            @test occursin("sha256:", read(p, String))
        end
    end

    @testset "観測不足ターゲットを穴埋めしない（Issue #244 受け入れ条件）" begin
        # cost_capital intercept を与えない → literature ターゲットが構築不能
        @test_throws ArgumentError build_capex_steady_state_targets(
            ds;
            baseline_start = _CALIB_BSTART,
            baseline_end = _CALIB_BEND,
            assumptions = rt_asm,
        )
        # 観測系列を落とす → derived / observed が構築不能で列挙される
        dropped = copy(rt_values)
        delete!(dropped, :va_s1)
        delete!(dropped, :cap_s3)
        ds_drop = _calib_dataset(dropped)
        err = try
            build_capex_steady_state_targets(
                ds_drop;
                baseline_start = _CALIB_BSTART,
                baseline_end = _CALIB_BEND,
                literature = rt_lit,
                assumptions = rt_asm,
            )
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("穴埋めしません", err.msg)
        @test occursin("cap_s3", err.msg)
        @test occursin("va_s1", err.msg) || occursin("y_s5", err.msg)
    end

    @testset "CapexCreditCycleTargets → 逆較正の既存経路を再利用する" begin
        targets, specs, structural = build_capex_steady_state_targets(
            ds;
            baseline_start = _CALIB_BSTART,
            baseline_end = _CALIB_BEND,
            literature = rt_lit,
            assumptions = rt_asm,
        )
        @test targets isa CapexCreditCycleTargets
        @test targets.source["kind"] == "empirical"
        @test haskey(targets.source, "dataset_hash")
        # 同じ targets を既存 API へ直接渡しても通る（分岐追加なし）
        m = capex_credit_cycle_model(targets; structural = structural)
        @test parameters(m) == parameters(cal.model)
    end

    @testset "structural override 経路（CAL-OBS の st_ を注入）" begin
        cal_ov = calibrate_capex_credit_cycle(
            _calib_dataset(rt_values);
            baseline_start = _CALIB_BSTART,
            baseline_end = _CALIB_BEND,
            literature = merge(rt_lit, (st_cshare_s3 = 0.42, st_dcap_multiplier = 3.0)),
            assumptions = rt_asm,
        )
        @test haskey(cal_ov.structural_overrides, :st_cshare_s3)
        @test cal_ov.structural_overrides.st_cshare_s3 == 0.42
        @test parameters(cal_ov.model).st_cshare_s3 == 0.42
        @test haskey(cal_ov.structural_overrides, :st_dcap_s1)
        @test isapprox(
            parameters(cal_ov.model).st_dcap_s1,
            3.0 * cal_ov.targets.values.debt_s1 / cal_ov.targets.values.y_s1;
            rtol = 1e-9,
        )
        @test any(occursin("structural override", w) for w in cal_ov.warnings)
    end

    @testset "st_gen_share は標本全体・ext_demand は残差（§8.3）" begin
        # baseline 窓外で order_s2 を変えると gen_share（標本全体平均）が動く
        var_values = Dict{Symbol, Any}(k => v for (k, v) in rt_values)
        # 16 四半期。baseline は idx 4..11。標本全体平均が rt と変わるように末尾を持ち上げる
        base_order = rt_values[:order_s2]
        v = fill(Float64(base_order), 16)
        v[13:16] .= base_order + 8.0
        var_values[:order_s2] = v
        ds_var = _calib_dataset(var_values)
        _, specs_var, _ = build_capex_steady_state_targets(
            ds_var;
            baseline_start = _CALIB_BSTART,
            baseline_end = _CALIB_BEND,
            literature = rt_lit,
            assumptions = rt_asm,
        )
        cal_var = calibrate_capex_credit_cycle(
            ds_var;
            baseline_start = _CALIB_BSTART,
            baseline_end = _CALIB_BEND,
            literature = rt_lit,
            assumptions = rt_asm,
        )
        @test !isapprox(
            cal_var.targets.values.ext_demand_s2,
            cal.targets.values.ext_demand_s2;
            rtol = 1e-6,
        )
        @test occursin("full sample", specs_var[:ext_demand_s2].formula)
    end

    @testset "golden fixture と一致（決定性・区分・hash の回帰）" begin
        golden_path = joinpath(
            @__DIR__,
            "fixtures",
            "calibration",
            "capex_credit_cycle",
            "roundtrip_default_targets.json",
        )
        @test isfile(golden_path)
        g = DME.JSON3.read(read(golden_path, String))
        @test cal.dataset_hash == g["dataset_hash"]
        @test cal.targets_hash == g["targets_hash"]
        @test cal.metadata["calibration_version"] == g["calibration_version"]
        for k in CAPEX_CC_TARGET_KEYS
            @test isapprox(
                getproperty(cal.targets.values, k),
                Float64(g["targets"][String(k)]);
                rtol = 1e-9,
                atol = 1e-9,
            )
        end
        for (cls, n) in pairs(g["parameter_class_counts"])
            @test count(==(Symbol(cls)), values(cal.parameter_provenance)) == n
        end
        @test cal.ss_inconsistent == collect(String.(g["ss_inconsistent"]))
        @test sort(String.(collect(keys(cal.structural_overrides)))) ==
              collect(String.(g["structural_override_keys"]))
    end

    @testset "capex_parameter_class の網羅" begin
        for n in CAPEX_CC_PARAMETER_NAMES
            c = capex_parameter_class(n)
            @test c in CAPEX_CC_PARAMETER_CLASSES || c == :dict_placeholder
        end
        @test capex_parameter_class(:st_va_share_s5) == :FIX
        @test capex_parameter_class(:st_cor_s1) == :SENS
        @test capex_parameter_class(:st_cor_s2) == :CAL_SS
        @test capex_parameter_class(:bh_mpc) == :EST
        @test capex_parameter_class(:st_delta_s2) == :CAL_OBS
        @test capex_parameter_class(:bh_emp_up_s4) == :dict_placeholder
        @test capex_parameter_class(:pl_ltv) == :SENS
    end
end
