# 部門別CAPEX・信用循環モデル（src/analysis/capex_credit_cycle_accounting.jl）の `I-3` テスト。
#
# 会計表構築（`capex_accounting_snapshots`）・会計恒等式検証12項目（`validate_capex_accounting`）
# の受け入れ条件を対象とする（Issue #181）。診断ラベル・シナリオ定義は対象外（`I-4`・`I-5`）。
#
# fixture について: `test/fixtures/capex_credit_cycle/degenerate_*.json`・`broken_*.json` は
# 各ケースの構成方法（既定モデルへの `exog`/`state0` 上書き、または `run.series` の直接改変）を
# 記録した illustrative な文書であり、`params_default.json`/`targets_default.json`（`I-1`）と
# 同様に本ファイルではプログラム的に読み込まない（数値は fixture の構造の記録であり、
# 実行時の入力は本ファイル内で直接構築する）。

# `run.series` の 1 変数・1 期だけを改変した `CapexCreditCycleRun` を返す（反例テスト用）。
function _capex_acc_corrupt_series(
    run::DME.CapexCreditCycleRun,
    sym::Symbol,
    idx::Int,
    delta::Real,
)
    v = copy(getproperty(run.series, sym))
    v[idx] += delta
    news = merge(run.series, NamedTuple{(sym,)}((v,)))
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

# 定常値からの `state0`（`state_variables(m)` の 65/70 要素）を返す。`DME._ccc_state0_from_steady`
# が返す `Dict` をそのまま `NamedTuple` 化する（`test_capex_credit_cycle.jl` §7.2-3 と同じ手法）。
function _capex_acc_state0_nt(m::DME.CapexCreditCycleModel)
    st0 = DME._ccc_state0_from_steady(m)
    sv = state_variables(m)
    return NamedTuple{Tuple(sv)}(Tuple(st0[s] for s in sv))
end

@testset "CapexCreditCycleModel 会計層（部門別CAPEX・信用循環モデル、I-3）" begin
    targets = capex_credit_cycle_default_targets()
    m = capex_credit_cycle_model(targets)
    baseline_run = DME.capex_run(m)

    @testset "smoke test（CLAUDE.md）" begin
        snaps = capex_accounting_snapshots(m, baseline_run)
        @test snaps isa Vector{SFCPeriodSnapshot}
        @test length(snaps) == length(baseline_run.periods)
        report = validate_capex_accounting(m, baseline_run)
        @test report isa AccountingCheckReport
        @test accounting_passed(report)
    end

    @testset "CAPEX_CC_ACCOUNTING_CHECKS が会計仕様§8.1の12項目と一致する" begin
        @test length(CAPEX_CC_ACCOUNTING_CHECKS) == 12
        @test Set(CAPEX_CC_ACCOUNTING_CHECKS) == Set((
            :balance_row_sum,
            :balance_column_sum,
            :flow_row_sum,
            :flow_column_sum,
            :stock_flow,
            :nlb_consistency,
            :net_worth_update,
            :capex_funding,
            :s4_balance_sheet,
            :output_income_split,
            :aggregate_output,
            :no_double_count,
        ))
    end

    @testset "methodology metadata（ADR 0009 §3.1: 本モデル専用の許容誤差規約を作らない）" begin
        report = validate_capex_accounting(m, baseline_run)
        meth = report.methodology
        @test meth.contract_version == SFC_CONTRACT_VERSION
        @test meth.model_version == CAPEX_CC_ACCOUNTING_VERSION
        @test meth.tolerance_abs == 1.0e-8
        @test meth.tolerance_rel == 1.0e-6
        @test report.tolerance_abs == 1.0e-8
        @test report.tolerance_rel == 1.0e-6
    end

    @testset "SFCResult を返さない（ADR 0013 決定15）" begin
        # capex_accounting_snapshots の戻り値は Vector{SFCPeriodSnapshot} であり、
        # validate_capex_accounting の戻り値は AccountingCheckReport である
        # （いずれも SFCResult ではない）。
        snaps = capex_accounting_snapshots(m, baseline_run)
        @test snaps isa Vector{SFCPeriodSnapshot}
        @test !(snaps isa SFCResult)
        report = validate_capex_accounting(m, baseline_run)
        @test !(report isa SFCResult)
    end

    @testset "§7.3-1 恒等式: baseline で12項目が全期 acc_pass" begin
        report = validate_capex_accounting(m, baseline_run)
        @test accounting_passed(report)
        @test isempty(report.violations)
        @test report.invalid_periods == String[]
        @test report.checks_performed > 0
        @test report.checks_passed == report.checks_performed
    end

    @testset "§7.3-1 恒等式: 需要・CAPEX・信用ショックの複合シナリオでも全期 acc_pass" begin
        n = length(baseline_run.periods)
        exog = Dict{Symbol, Vector{Float64}}(
            :ai_exp => vcat(fill(1.0, 8), fill(0.7, n - 8)),
            :capex_plan_shock_ex => fill(1.0, n),
            :spread_shock_ex => vcat(fill(0.0, 8), fill(150.0, n - 8)),
            :policy_rate => fill(m.params.st_pol_ref, n),
            :ext_demand_s2 => fill(m.params.st_extdem_s2, n),
            :ext_demand_s3 => fill(m.params.st_extdem_s3, n),
            :price_s1 => fill(1.0, n),
        )
        run = DME.capex_run(m; exog = exog)
        @test run.termination_reason == :completed
        report = validate_capex_accounting(m, run)
        @test accounting_passed(report)
        @test isempty(report.violations)
    end

    @testset "§7.3-3 退化ケース: capex_exec_s1 = 0 の期でも12項目が成立する" begin
        n = length(baseline_run.periods)
        exog = Dict{Symbol, Vector{Float64}}(
            :ai_exp => vcat(fill(1.0, 8), fill(0.7, n - 8)),
            :capex_plan_shock_ex => fill(1.0, n),
            :spread_shock_ex => fill(0.0, n),
            :policy_rate => fill(m.params.st_pol_ref, n),
            :ext_demand_s2 => fill(m.params.st_extdem_s2, n),
            :ext_demand_s3 => fill(m.params.st_extdem_s3, n),
            :price_s1 => fill(1.0, n),
        )
        run = DME.capex_run(m; exog = exog)
        @test run.termination_reason == :completed
        @test any(==(0.0), run.series.capex_exec_s1) # 退化状態が実際に発生することの確認
        report = validate_capex_accounting(m, run)
        @test accounting_passed(report)
        @test isempty(report.violations)
    end

    @testset "§7.3-4 退化ケース: debt_s = 0（全部門無借金）— 有効期間は成立し、打ち切り後はNaNが acc_invalid に正しく分類される" begin
        state0 =
            merge(_capex_acc_state0_nt(m), (debt_s1 = 0.0, debt_s2 = 0.0, debt_s3 = 0.0))
        run = DME.capex_run(m; state0 = state0)
        report = validate_capex_accounting(m, run)

        # 打ち切り前（最初の期）は退化状態でも12項目が成立する
        first_period = string(run.periods[1])
        @test isempty([v for v in report.violations if v.period == first_period])

        # 会計違反（acc_fail）ではなく acc_invalid として分類される（NaN の伝播）
        @test !any(v -> v.status == acc_fail, report.violations)
        if run.termination_reason != :completed
            @test any(v -> v.status == acc_invalid, report.violations)
            @test !isempty(report.invalid_periods)
        end
    end

    @testset "§7.3-5 退化ケース: inv_s = 0（在庫ゼロ）で12項目が成立する" begin
        state0 = merge(_capex_acc_state0_nt(m), (inv_s2 = 0.0, inv_s3 = 0.0))
        @test state0.inv_s2 == 0.0 && state0.inv_s3 == 0.0 # 退化状態（初期在庫ゼロ）の確認
        run = DME.capex_run(m; state0 = state0)
        @test run.termination_reason == :completed
        report = validate_capex_accounting(m, run)
        @test accounting_passed(report)
        @test isempty(report.violations)
    end

    @testset "§7.3-6 反例: cap_s の更新式を壊すと :stock_flow が acc_fail を返す" begin
        broken = _capex_acc_corrupt_series(baseline_run, :cap_s1, 15, 10.0)
        report = validate_capex_accounting(m, broken)
        @test !accounting_passed(report)
        @test any(v -> v.check == :stock_flow && v.status == acc_fail, report.violations)
    end

    @testset "§7.3-7 反例: capex_exec_s1 の配分（配分比の和を1から外す）を壊すと :no_double_count が acc_fail を返す" begin
        # st_capex_share_s2+_s3+_sx=1 はモデルのコンストラクタが強制するため（§7.5-2）、
        # 配分比を直接壊すことはできない。代わりに capex_sx_s1（配分の1項）を改変し、
        # 「capex_exec_s1 = d_{S1,S2}+d_{S1,S3}+capex_sx_s1（R-3）」を成立させなくする
        # （配分比の和が1から外れた場合と同型の不整合を作る）。
        broken = _capex_acc_corrupt_series(baseline_run, :capex_sx_s1, 15, 5.0)
        report = validate_capex_accounting(m, broken)
        @test !accounting_passed(report)
        @test any(
            v -> v.check == :no_double_count && v.status == acc_fail,
            report.violations,
        )
    end

    @testset "§7.3-8 反例: va_s の分解を壊すと :output_income_split が acc_fail を返す" begin
        broken = _capex_acc_corrupt_series(baseline_run, :va_s2, 15, 5.0)
        report = validate_capex_accounting(m, broken)
        @test !accounting_passed(report)
        @test any(
            v -> v.check == :output_income_split && v.status == acc_fail,
            report.violations,
        )
    end

    @testset "§7.3-10 決定性: 同一 run で2回実行すると AccountingCheckReport が完全一致する" begin
        report1 = validate_capex_accounting(m, baseline_run)
        report2 = validate_capex_accounting(m, baseline_run)
        @test isequal(report1, report2)
    end

    @testset "会計違反を自動補正していない（丸め・クリップ・辻褄合わせをしない）" begin
        broken = _capex_acc_corrupt_series(baseline_run, :cap_s1, 15, 10.0)
        report = validate_capex_accounting(m, broken)
        period15 = string(broken.periods[15])
        v = only(
            filter(
                x -> x.check == :stock_flow && x.sector == :s1 && x.period == period15,
                report.violations,
            ),
        )
        @test v.status == acc_fail
        @test abs(v.residual) >= 10.0 - 1.0e-6 # 残差がそのまま保持され、10.0 の改変が吸収されていない
    end

    @testset "検証対象外の扱い（会計仕様 §8.1「検証対象に含めないもの」）" begin
        report = validate_capex_accounting(m, baseline_run)
        # 実物資産行（cap・cip・inventory）・純資産行（balance）は :balance_row_sum の対象外
        @test !any(
            v ->
                v.check == :balance_row_sum &&
                v.instrument in (:capital, :cip, :inventory, :balance),
            report.violations,
        )
        # S5・SX 列は :balance_column_sum の対象外、S4・SX 列は :flow_column_sum の対象外
        @test !any(
            v -> v.check == :balance_column_sum && v.sector in (:s5, :sx),
            report.violations,
        )
        @test !any(
            v -> v.check == :flow_column_sum && v.sector in (:s4, :sx),
            report.violations,
        )
    end

    @testset "capex_accounting_snapshots の内容（貸借対照表・取引フロー行列の形状）" begin
        snaps = capex_accounting_snapshots(m, baseline_run)
        snap = snaps[15]
        bs = snap.balance_sheet
        @test Set(bs.instruments) == Set((
            :capital,
            :cip,
            :inventory,
            :deposit,
            :loan,
            :advance,
            :extfund,
            :balance,
        ))
        @test Set(bs.sectors) == Set((:s1, :s2, :s3, :s4, :s5, :sx))
        tf = snap.transaction_flow
        @test length(tf.transactions) == 19 # C-01–C-12・F-01–F-07
        @test Set(tf.sectors) == Set((:s1, :s2, :s3, :s4, :s5, :sx))

        # 貸借対照表: S1–S4 の列和が0（純資産行込み。§3.2）
        for sec in (:s1, :s2, :s3, :s4)
            c = findfirst(==(sec), bs.sectors)
            @test isapprox(sum(@view(bs.holdings[:, c])), 0.0; atol = 1.0e-6)
        end
    end
end
