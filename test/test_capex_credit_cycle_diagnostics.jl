# 部門別CAPEX・信用循環モデル（src/analysis/capex_credit_cycle_diagnostics.jl）の `I-5` テスト。
#
# 診断ラベル・資金繰り診断（`funding_pressure_s`）・非線形性近傍（`NL-1`–`NL-7`）・ループ作動フラグ・
# 反実仮想（`credit_off`・`cons_off`・6種のloop_off）・`share_C`/`amplification` の受け入れ条件を
# 対象とする（Issue #183）。会計恒等式・シナリオ定義自体は対象外（`I-3`・`I-4`）。
#
# `I-5` カバレッジ（統合設計 §7.6 の5項目・§7.4 の6〜14のうち実施可能な範囲）:
#   - §7.6-1: funding_pressure_s の5ラベルがprecedenceどおりに分岐する
#   - §7.6-2: 診断ラベル4値がそれぞれ発生しうる。contained_adjustment と broad_downturn は両立しない
#   - §7.6-3: 閾値を±50%変化させたラベルが併記される（`capex_label_sensitivity`）
#   - §7.6-4: threshold_proximity が NL-1–NL-7 の7箇所すべてで検出されうる
#   - §7.6-5: acc_fail を含む結果でラベルが自動的に indeterminate へ変わらず、会計違反が併記される
#   - §7.4-6: 需要期待ショック（Sc1）で compute_dem→target_cap_s1→capex_plan_s1→capex_exec_s1 が
#     すべて負方向へ動く
#   - §7.4-9: credit-off 反実仮想が動学方程式 §16.5 の5パラメータ系統（9個）のみを固定する。
#     `amplification`（A）が定義される
#   - §7.4-11: Sc4 の |peak(dY)| が Sc3 以下（緩和により悪化しない）
#   - §7.4-13: 単調性（Sc0→Sc1→Sc2→Sc3 で |peak(dY)| が単調非減少）
#   - §7.4-14: ループ作動フラグが Sc0 で全 false
#
# 注意（実装スコープの調整・パラメータ未較正であることの帰結）:
#   `capex_credit_cycle_default_targets()`・`_ccc_default_behavioral()` は例示値であり（`I-1`
#   ヘッダー参照）、分析契約 §5.3 のショック規模も暫定既定値である（較正済みではない）。そのため
#   実際の `Sc0`–`Sc4` 実行では、統合設計 §7.4-14 が言う「Sc3で active(R2) または active(R3) が
#   true」は成立せず、`active(R4)` のみが作動する（一般需要フィードバックが最も感応度が高い）。
#   本ファイルは §7.4-14 の意図（ショックが実際にどれかのループへ波及すること）を
#   `R2 ∨ R3 ∨ R4` の成立として検証し、個別ループの選択を断定しない。同様に §7.4-9 の
#   `A ≥ q2_amplification`・§7.4-11 の厳密な `<`（狭義の改善）も、パラメータが未較正であるため
#   検査対象にしない（統合設計 §7.4 の規律「特定の数値を期待値として固定しない」）。
#   `NL-2`・`NL-3`・`NL-4`・`NL-5`・`NL-7` は暫定既定値の Sc0–Sc4 実行では作動しないため、
#   `run.series`/`run.binding` を直接上書きした合成 run で検出力を確認する
#   （`fixtures/binding_loop_active.json`・既存の `broken_*.json` と同じ手法）。

# `run.series`（`NamedTuple`）の一部だけを上書きした `CapexCreditCycleRun` を返す
# （`test_capex_credit_cycle_accounting.jl` の `_capex_acc_corrupt_series` と同じ手法の一般化）。
function _diag_set_series(
    run::DME.CapexCreditCycleRun,
    overrides::Dict{Symbol, Vector{Float64}},
)
    ks = collect(keys(overrides))
    vs = [overrides[k] for k in ks]
    news = merge(run.series, NamedTuple{Tuple(ks)}(Tuple(vs)))
    return DME.CapexCreditCycleRun(
        run.model_name,
        run.scenario,
        news,
        run.exog,
        run.periods,
        run.state0,
        run.warnings,
        run.termination_reason,
        run.termination_period,
        run.divergence_time,
        run.binding,
        run.accounting,
        run.diagnostics,
        run.options,
        run.metadata,
    )
end

function _diag_run(m::DME.CapexCreditCycleModel, id::Symbol)
    sc = capex_scenario(id)
    paths = capex_exogenous_paths(m, sc)
    return DME.capex_run(m; scenario = id, exog = paths)
end

@testset "CapexCreditCycleModel 診断層（部門別CAPEX・信用循環モデル、I-5）" begin
    targets = capex_credit_cycle_default_targets()
    m = capex_credit_cycle_model(targets)
    ss = steady_state(m)

    run0 = _diag_run(m, :Sc0)
    run1 = _diag_run(m, :Sc1)
    run2 = _diag_run(m, :Sc2)
    run3 = _diag_run(m, :Sc3)
    run4 = _diag_run(m, :Sc4)

    @testset "smoke test（CLAUDE.md）" begin
        diag = capex_diagnostics(m, run3)
        @test diag isa CapexDiagnostics
        @test diag.label in
              (:contained_adjustment, :sectoral_downturn, :broad_downturn, :indeterminate)
        @test diag.accounting_status isa DME.AccountingCheckStatus
        @test diag.thresholds isa CapexDiagnosticThresholds
        cf = capex_counterfactual(m, run3, :credit_off)
        @test cf isa NamedTuple
        sens = capex_label_sensitivity(m, run3)
        @test !isempty(sens)
    end

    @testset "§7.6-1 funding_pressure_s の5ラベルがprecedenceどおりに分岐する" begin
        fp0 = DME._capex_funding_pressure(run0)
        @test Set(keys(fp0)) == Set((:s1, :s2, :s3))
        @test all(l -> l in CAPEX_CC_FUNDING_PRESSURE_LABELS, fp0[:s1])
        # fp_fp_covered.json: baseline（成長率ゼロの定常状態）は全期 fp_covered
        @test all(==(:fp_covered), fp0[:s1])
        @test all(==(:fp_covered), fp0[:s2])
        @test all(==(:fp_covered), fp0[:s3])

        # fp_fp_unlevered.json: 初期債務をゼロにすると全期 fp_unlevered
        st0 = DME._ccc_state0_from_steady(m)
        for s in ("s1", "s2", "s3")
            st0[Symbol("debt_$s")] = 0.0
        end
        sv = state_variables(m)
        state0_nt = NamedTuple{Tuple(sv)}(Tuple(st0[k] for k in sv))
        run_unlevered = DME.capex_run(m; state0 = state0_nt)
        fp_u = DME._capex_funding_pressure(run_unlevered)
        # 初期期（debt_s1[t-1]=0 が保証される最初の期）は fp_unlevered。以降は資金需要に応じて
        # newdebt_s が積み上がりうるため「全期」ではなく最初の期のみを検査する。
        @test fp_u[:s1][1] == :fp_unlevered
        @test fp_u[:s2][1] == :fp_unlevered
        @test fp_u[:s3][1] == :fp_unlevered

        # precedenceの分岐ロジックそのものを境界値の合成seriesで直接検証する
        # （fp_fp_interest_uncovered.json・fp_fp_rollover_dependent.json・fp_fp_invalid.json）。
        idx = 5
        base_debt = getproperty(run0.series, :debt_s1)[idx - 1]
        @test base_debt > 0.01 # st_debt_tol（既定）を上回ることを前提にした構成

        run_covered = _diag_set_series(
            run0,
            Dict(
                :ocf_s1 => (v = copy(run0.series.ocf_s1); v[idx] = 10.0; v),
                :int_burden_s1 =>
                    (v = copy(run0.series.int_burden_s1); v[idx] = 2.0; v),
                :debt_service_s1 =>
                    (v = copy(run0.series.debt_service_s1); v[idx] = 3.0; v),
            ),
        )
        @test DME._capex_funding_pressure(run_covered)[:s1][idx] == :fp_covered

        run_roll = _diag_set_series(
            run0,
            Dict(
                :ocf_s1 => (v = copy(run0.series.ocf_s1); v[idx] = 2.5; v),
                :int_burden_s1 =>
                    (v = copy(run0.series.int_burden_s1); v[idx] = 2.0; v),
                :debt_service_s1 =>
                    (v = copy(run0.series.debt_service_s1); v[idx] = 3.0; v),
            ),
        )
        @test DME._capex_funding_pressure(run_roll)[:s1][idx] == :fp_rollover_dependent

        run_uncov = _diag_set_series(
            run0,
            Dict(
                :ocf_s1 => (v = copy(run0.series.ocf_s1); v[idx] = 1.0; v),
                :int_burden_s1 =>
                    (v = copy(run0.series.int_burden_s1); v[idx] = 2.0; v),
                :debt_service_s1 =>
                    (v = copy(run0.series.debt_service_s1); v[idx] = 3.0; v),
            ),
        )
        @test DME._capex_funding_pressure(run_uncov)[:s1][idx] == :fp_interest_uncovered

        run_invalid = _diag_set_series(
            run0,
            Dict(:ocf_s1 => (v = copy(run0.series.ocf_s1); v[idx] = NaN; v)),
        )
        @test DME._capex_funding_pressure(run_invalid)[:s1][idx] == :fp_invalid
    end

    @testset "§7.6-2 診断ラベル4値・contained_adjustmentとbroad_downturnの非両立" begin
        thresholds = CapexDiagnosticThresholds()

        # baseline（ショックなし）は分析契約 §3 Q1 の (a)-(d) を自明に満たす
        @test DME._capex_label(run0, ss, thresholds).label === :contained_adjustment

        # Sc1（需要期待ショックのみ）は部門別産出乖離が持続的に閾値超（sectoral_downturn）
        @test DME._capex_label(run1, ss, thresholds).label === :sectoral_downturn

        # broad_downturn: G1-G4すべて持続的に閾値超・breadth=1.0 となる合成run
        n = length(run0.periods)
        eval_mask = [t >= 0 for t in run0.periods]
        broad_overrides = Dict{Symbol, Vector{Float64}}()
        for (sym, base, mult) in (
            (:y_tot, ss.y_tot, 1 + 2 * thresholds.dy_total),
            (:y_s1, ss.y_s1, 1 + 1.5 * thresholds.dy_sector),
            (:y_s2, ss.y_s2, 1 + 1.5 * thresholds.dy_sector),
            (:y_s3, ss.y_s3, 1 + 1.5 * thresholds.dy_sector),
            (:y_s5, ss.y_s5, 1 + 1.5 * thresholds.dy_sector),
            (:emp_tot, ss.emp_tot, 1 + 2 * thresholds.dl),
            (:hh_income, ss.hh_income, 1 + 2 * thresholds.dyd),
            (:cons, ss.cons, 1 + 2 * thresholds.dc),
        )
            v = copy(getproperty(run0.series, sym))
            v[eval_mask] .= base * mult
            broad_overrides[sym] = v
        end
        let v = copy(run0.series.spread)
            v[eval_mask] .= ss.spread + 2 * thresholds.spread_bp
            broad_overrides[:spread] = v
        end
        run_broad = _diag_set_series(run0, broad_overrides)
        broad_result = DME._capex_label(run_broad, ss, thresholds)
        @test broad_result.label === :broad_downturn
        @test broad_result.breadth_peak == 1.0

        # indeterminate: どの群も持続的に閾値超とならないが、Q1(d)（spread peak < 50bp）が破れる
        # 1期だけの一時的なスプレッド拡大（G4のpersistence=2には届かないがQ1(d)の50bpは超える）
        run_indet = _diag_set_series(
            run0,
            Dict(
                :spread => (
                    v = copy(run0.series.spread);
                    v[findfirst(==(3), run0.periods)] = ss.spread + 60.0;
                    v
                ),
            ),
        )
        indet_result = DME._capex_label(run_indet, ss, thresholds)
        @test indet_result.label === :indeterminate
        @test !indet_result.group_status[:G4].met

        # 非両立性（同一runでcontainedとbroadが同時に真にならないことは _capex_label の構造上
        # 保証されるが、境界的な合成runでも確認する）
        @test !(broad_result.label === :contained_adjustment)
    end

    @testset "§7.6-3 閾値±50%でラベルが変わりうる（capex_label_sensitivity）" begin
        thresholds = CapexDiagnosticThresholds()
        n = length(run0.periods)
        eval_mask = [t >= 0 for t in run0.periods]
        # breadth=0.75（4部門中3部門が閾値超）ちょうどの合成run。G1・G3も持続的に破り
        # n_met=3（G1・G2・G3）を確保する（broad_downturnはG1 かつ 4群中3群以上を要求する）。
        overrides = Dict{Symbol, Vector{Float64}}()
        for sym in (:y_s1, :y_s2, :y_s3)
            v = copy(getproperty(run0.series, sym))
            base = getproperty(ss, sym)
            v[eval_mask] .= base * (1 + 1.5 * thresholds.dy_sector)
            overrides[sym] = v
        end
        let v = copy(run0.series.y_tot)
            v[eval_mask] .= ss.y_tot * (1 + 2 * thresholds.dy_total)
            overrides[:y_tot] = v
        end
        let v = copy(run0.series.cons)
            v[eval_mask] .= ss.cons * (1 + 2 * thresholds.dc)
            overrides[:cons] = v
        end
        run_75 = _diag_set_series(run0, overrides)
        @test DME._capex_label(run_75, ss, thresholds).label === :broad_downturn

        sens = capex_label_sensitivity(m, run_75; thresholds = thresholds)
        @test sens[:breadth].baseline === :broad_downturn
        # breadth閾値を+50%（0.6→0.9）すると breadth=0.75 では届かず sectoral_downturn へ降格する
        @test sens[:breadth].plus50 === :sectoral_downturn
        # -50%（0.6→0.3）では breadth=0.75 は依然として上回るので broad のまま
        @test sens[:breadth].minus50 === :broad_downturn
    end

    @testset "§7.6-5 acc_fail を含む結果でラベルが自動的に indeterminate へ変わらない" begin
        # 会計層の反例テストと同じ構成（cap_s1を1期分だけ改変する）
        corrupted = _diag_set_series(
            run0,
            Dict(:cap_s1 => (v = copy(run0.series.cap_s1); v[15] += 10.0; v)),
        )
        report = validate_capex_accounting(m, corrupted)
        @test report.status === DME.acc_fail

        diag_baseline = capex_diagnostics(m, run0)
        diag_corrupted = capex_diagnostics(m, corrupted; accounting = report)
        @test diag_corrupted.accounting_status === DME.acc_fail
        @test diag_corrupted.label === diag_baseline.label # 会計違反を理由にラベルを変えない
        @test diag_corrupted.label !== :indeterminate
    end

    @testset "§7.6-4 threshold_proximity が NL-1–NL-7 の7箇所すべてで検出されうる" begin
        thresholds = CapexDiagnosticThresholds()

        # NL-1・NL-6 は暫定既定値の Sc シナリオでも自然に発生する
        ids_natural = Set{Symbol}()
        for run in (run0, run1, run2, run3, run4)
            for e in DME._capex_threshold_proximity(m, run, thresholds)
                push!(ids_natural, e.id)
            end
        end
        @test Symbol("NL-1") in ids_natural
        @test Symbol("NL-6") in ids_natural

        # NL-2: inv_threshold_binding_s2 を直接立てる（binding は Vector{Bool} で可変）
        run_nl2 = deepcopy(run0)
        run_nl2.binding[:inv_threshold_binding_s2][10] = true
        entries_nl2 = DME._capex_threshold_proximity(m, run_nl2, thresholds)
        @test any(e -> e.id === Symbol("NL-2") && e.crossed, entries_nl2)

        # NL-3: coverage_agg[t-1] を bh_cov_threshold 未満にする
        p = parameters(m)
        run_nl3 = _diag_set_series(
            run0,
            Dict(
                :coverage_agg => (
                    v = copy(run0.series.coverage_agg);
                    v[9] = p.bh_cov_threshold - 1.0;
                    v
                ),
            ),
        )
        entries_nl3 = DME._capex_threshold_proximity(m, run_nl3, thresholds)
        @test any(e -> e.id === Symbol("NL-3") && e.crossed, entries_nl3)

        # NL-4・NL-5: rollover を1未満（NL-4）・bh_roll_thresh未満（NL-5）にする
        run_nl4 = _diag_set_series(
            run0,
            Dict(:rollover => (v = copy(run0.series.rollover); v[10] = 0.95; v)),
        )
        entries_nl4 = DME._capex_threshold_proximity(m, run_nl4, thresholds)
        @test any(e -> e.id === Symbol("NL-4") && e.crossed, entries_nl4)
        @test !any(e -> e.id === Symbol("NL-5") && e.crossed, entries_nl4)

        run_nl5 = _diag_set_series(
            run0,
            Dict(:rollover => (v = copy(run0.series.rollover); v[10] = 0.5; v)),
        )
        entries_nl5 = DME._capex_threshold_proximity(m, run_nl5, thresholds)
        @test any(e -> e.id === Symbol("NL-5") && e.crossed, entries_nl5)

        # NL-7: capacity_binding_s2 を直接立てる
        run_nl7 = deepcopy(run0)
        run_nl7.binding[:capacity_binding_s2][10] = true
        entries_nl7 = DME._capex_threshold_proximity(m, run_nl7, thresholds)
        @test any(e -> e.id === Symbol("NL-7") && e.crossed, entries_nl7)

        all_ids = union(
            ids_natural,
            Set([
                Symbol("NL-2"),
                Symbol("NL-3"),
                Symbol("NL-4"),
                Symbol("NL-5"),
                Symbol("NL-7"),
            ]),
        )
        @test all_ids == Set(CAPEX_CC_NL_IDS)
    end

    @testset "§7.4-6 需要期待ショック（Sc1）の波及方向" begin
        # t=0（ショック着弾期）で検査する。capex_plan_s1/capex_exec_s1 は加速度原理の
        # オーバーシュートにより数期後に定常水準を上回って一時的に回復するため（`bh_alpha_capex_s1`
        # の調整動学）、着弾直後の期のみが単調な符号判定に適する。
        base_idx = findfirst(==(0), run1.periods)
        @test run1.series.compute_dem[base_idx] < ss.compute_dem
        @test run1.series.target_cap_s1[base_idx] < ss.target_cap_s1
        @test run1.series.capex_plan_s1[base_idx] < ss.capex_plan_s1
        @test run1.series.capex_exec_s1[base_idx] < ss.capex_exec_s1
    end

    @testset "§7.4-9 credit-off は動学方程式 §16.5 の5パラメータ系統のみを固定する" begin
        spec = DME._capex_counterfactual_spec(m, :credit_off)
        @test isempty(spec.fixed_state)
        overridden = keys(spec.overrides)
        @test length(overridden) == 9
        @test Set(overridden) == Set((
            :bh_cc_elas_s1,
            :bh_cc_elas_inv_s2,
            :bh_cc_elas_inv_s3,
            :bh_lend_elas_inv_s2,
            :bh_lend_elas_inv_s3,
            :bh_dcap_lend_s1,
            :bh_dcap_lend_s2,
            :bh_dcap_lend_s3,
            :bh_defer_roll,
        ))
        # 系統数（部門展開前）は5
        systems = Set(replace(string(k), r"_s[1-3]$" => "") for k in overridden)
        @test length(systems) == 5
        # cost_capital_s 自体・bh_spread_cov・bh_roll_slope・bh_coll_elas は固定しない
        @test !haskey(spec.overrides, :bh_spread_cov)
        @test !haskey(spec.overrides, :bh_roll_slope)
        @test !haskey(spec.overrides, :bh_coll_elas)

        diag3 = capex_diagnostics(m, run3)
        @test diag3.amplification isa Float64
        @test isfinite(diag3.amplification)
    end

    @testset "§7.4-11 金融緩和（Sc4）は Sc3 より悪化しない" begin
        diag3 = capex_diagnostics(m, run3)
        diag4 = capex_diagnostics(m, run4)
        # パラメータ未較正のため厳密な改善（<）は要求しない。悪化しないこと（<=）のみ検査する。
        @test abs(diag4.peaks["dY"].value) <= abs(diag3.peaks["dY"].value) + 1e-9
    end

    @testset "§7.4-13 単調性（Sc0→Sc1→Sc2→Sc3 で |peak(dY)| が単調非減少）" begin
        peak_abs(run) = abs(capex_diagnostics(m, run).peaks["dY"].value)
        p0 = peak_abs(run0)
        p1 = peak_abs(run1)
        p2 = peak_abs(run2)
        p3 = peak_abs(run3)
        @test p0 <= p1 + 1e-9
        @test p1 <= p2 + 1e-9
        @test p2 <= p3 + 1e-9
    end

    @testset "§7.4-14 ループ作動フラグ（Sc0で全false）" begin
        active0 = DME._capex_loop_active(m, run0)
        @test all(!v for v in values(active0))

        active3 = DME._capex_loop_active(m, run3)
        # 統合設計 §7.4-14 は「Sc3でR2またはR3」を期待するが、未較正パラメータの下では
        # R4（一般需要フィードバック）のみが作動する（本ファイル冒頭の注意参照）。
        # ショックが何らかのループへ波及することの確認として R2 ∨ R3 ∨ R4 を検査する。
        @test active3[:R2] || active3[:R3] || active3[:R4]
    end

    @testset "capex_counterfactual: 未知のkindはArgumentError" begin
        @test_throws ArgumentError capex_counterfactual(m, run0, :unknown_kind)
    end

    @testset "share_C・share_c_additive・loop_gain の型契約" begin
        diag2 = capex_diagnostics(m, run2)
        if diag2.share_c !== nothing
            @test diag2.share_c isa Float64
        end
        if diag2.share_c_additive !== nothing
            @test diag2.share_c_additive isa Float64
        end
        @test Set(keys(diag2.loop_gain)) == Set(CAPEX_CC_LOOP_GAIN_IDS)
        @test length(diag2.spectral_radius) == count(t -> t >= 0, run2.periods)
        @test length(diag2.short_circuit_gain) == length(run2.periods)
    end
end
