# 最小 SIM 型 SFC モデル（src/models/sfc_sim.jl）とその会計 adapter
# （src/analysis/sfc_sim_adapter.jl）のテスト。
#
# カバレッジ:
#   - インターフェース（model_name / state / control / parameters）
#   - 定常状態の閉形式・残差（ΔH=0・予算均衡）
#   - simulate の長期収束・初期資産差の移行経路
#   - 財政ショック（G・θ、一時/恒久）の定常値
#   - baseline / ショック経路の全期会計整合性
#   - 政府赤字 ↔ 家計金融資産増加の対応
#   - SFCResult → SimulationResult 変換後の plot_result / summarize_result 利用
#   - 不正 parameter・負期間・不明ショック・非有限値の扱い
#   - fixture 非依存・決定的（同一入力で同一 report）

@testset "SIMModel（最小 SFC）" begin
    # Godley & Lavoie (2007) 第3章 SIM の代表的パラメータ
    m = SIMModel(α1 = 0.6, α2 = 0.4, θ = 0.2, G = 20.0)

    @testset "インターフェース" begin
        @test model_name(m) == "SIM Model"
        @test state_variables(m) == [:H]
        @test control_variables(m) == [:Y, :C, :YD, :T, :N]
        p = parameters(m)
        @test p.α1 == 0.6
        @test p.α2 == 0.4
        @test p.θ == 0.2
        @test p.G == 20.0
        @test p.W == 1.0
        # 位置引数コンストラクタも同値
        @test parameters(SIMModel(0.6, 0.4, 0.2, 20.0, 1.0)) == p
    end

    @testset "steady_state（閉形式・残差）" begin
        ss = steady_state(m)
        # Y*=G/θ=100, YD*=(1-θ)G/θ=80, H*=(1-α1)/α2·YD*=80
        @test ss.Y ≈ 100.0 atol = 1e-12
        @test ss.YD ≈ 80.0 atol = 1e-12
        @test ss.H ≈ 80.0 atol = 1e-12
        @test ss.T ≈ 20.0 atol = 1e-12       # T*=G（予算均衡）
        @test ss.C ≈ ss.YD atol = 1e-12       # ΔH=0（貯蓄ゼロ）
        @test ss.N ≈ ss.Y / m.W atol = 1e-12
        # 定常状態残差: 消費関数・貨幣蓄積式を満たす
        @test ss.C ≈ m.α1 * ss.YD + m.α2 * ss.H atol = 1e-12
        @test ss.H - ss.H ≈ ss.YD - ss.C atol = 1e-12   # ΔH = YD − C = 0
        # 定常状態を初期値にすると不動点（1 期進めても不変）
        s1 = simulate(m, ss.H; T = 3)
        @test all(≈(100.0; atol = 1e-9), s1.Y)
        @test all(≈(ss.H; atol = 1e-9), s1.H)
    end

    @testset "simulate（長期収束）" begin
        ss = steady_state(m)
        s = simulate(m, 0.0; T = 400)
        @test length(s.Y) == 400
        @test s.Y[1] ≈ (m.G) / (1 - m.α1 * (1 - m.θ)) atol = 1e-12  # H_0=0
        @test s.Y[end] ≈ ss.Y atol = 1e-6
        @test s.H[end] ≈ ss.H atol = 1e-6
        # H_0=0 < H* なので単調増加で収束
        @test all(diff(s.Y) .>= -1e-12)
        @test all(diff(s.H) .>= -1e-12)
        # 恒等式が各期成立: Y=C+G, YD=Y-T, H_t=H_{t-1}+(YD-C)
        Hprev = 0.0
        for t in 1:length(s.Y)
            @test s.Y[t] ≈ s.C[t] + s.G[t] atol = 1e-10
            @test s.YD[t] ≈ s.Y[t] - s.T[t] atol = 1e-10
            @test s.H[t] ≈ Hprev + (s.YD[t] - s.C[t]) atol = 1e-10
            Hprev = s.H[t]
        end
    end

    @testset "simulate（初期資産差の移行経路）" begin
        ss = steady_state(m)
        low = simulate(m, ss.H / 2; T = 400)
        high = simulate(m, ss.H * 2; T = 400)
        # 上からは単調減少、下からは単調増加、いずれも同じ定常へ
        @test all(diff(high.H) .<= 1e-12)
        @test all(diff(low.H) .>= -1e-12)
        @test low.Y[end] ≈ high.Y[end] atol = 1e-6
        @test low.H[end] ≈ high.H[end] atol = 1e-6
        @test low.H[end] ≈ ss.H atol = 1e-6
    end

    @testset "impulse_response（財政ショック）" begin
        ss = steady_state(m)
        # 恒久的な政府支出増: 新定常 Y*=(G+ΔG)/θ
        irfG = impulse_response(m, 5.0; shock = :G, T = 500, permanent = true)
        # 開始ストックは旧定常 H*。1 期目に需要増で即ジャンプ（H* から Y=(G+ΔG+α2·H*)/(1−α1(1−θ))）
        @test irfG.Y[1] ≈ (25.0 + m.α2 * ss.H) / (1 - m.α1 * (1 - m.θ)) atol = 1e-9
        @test irfG.Y[1] > ss.Y
        @test irfG.Y[end] ≈ 25.0 / m.θ atol = 1e-4  # 125
        @test irfG.H[end] > ss.H                # 赤字蓄積で家計資産増
        @test irfG.G[end] ≈ 25.0

        # 一時的な政府支出増（1 期のみ）: 旧定常へ戻る
        irfGt = impulse_response(
            m,
            5.0;
            shock = :G,
            T = 500,
            permanent = false,
            shock_start = 1,
        )
        @test irfGt.G[1] ≈ 25.0
        @test irfGt.G[2] ≈ 20.0
        @test irfGt.Y[end] ≈ ss.Y atol = 1e-3

        # 税率引き上げ: 新定常 Y*=G/(θ+Δθ)
        irfθ = impulse_response(m, 0.05; shock = :θ, T = 500, permanent = true)
        @test irfθ.Y[end] ≈ m.G / 0.25 atol = 1e-4  # 80
        @test irfθ.T[end] ≈ m.G atol = 1e-3          # 新定常で予算均衡
    end

    @testset "会計整合性（baseline 全期 pass）" begin
        s = simulate(m, 0.0; T = 60)
        r = sfc_result(m, s; scenario_name = "baseline")
        @test r isa SFCResult
        @test r.model_name == "SIM Model"
        @test length(r.snapshots) == 60
        # 3 部門・2 instrument（貨幣＋純資産バランス行）
        @test Set(sec.id for sec in r.sectors) ==
              Set([:households, :production, :government])
        @test Set(ins.id for ins in r.instruments) == Set([:money, :net_worth])

        rep = validate_sfc_accounting(r)
        @test accounting_passed(rep)
        @test rep.status === acc_pass
        @test isempty(rep.violations)
        @test rep.checks_passed == rep.checks_performed
        @test rep.max_abs_residual < 1e-8
        # metadata に会計サマリー・warnings なし
        @test r.metadata["accounting_status"] == "pass"
        @test r.metadata["accounting_checks_passed"] ==
              r.metadata["accounting_checks_performed"]
        @test isempty(r.warnings)
    end

    @testset "会計整合性（ショック経路 全期 pass・shock metadata）" begin
        irfG = impulse_response(m, 5.0; shock = :G, T = 40, permanent = true)
        r = sfc_result(
            m,
            irfG;
            scenario_name = "G_permanent",
            shock = (type = "G", size = 5.0, permanent = true),
        )
        rep = validate_sfc_accounting(r)
        @test accounting_passed(rep)
        @test r.metadata["shock"].type == "G"
        @test r.metadata["shock"].size == 5.0

        irfθ = impulse_response(m, 0.05; shock = :θ, T = 40, permanent = true)
        rθ = sfc_result(m, irfθ; scenario_name = "tax_hike")
        @test accounting_passed(validate_sfc_accounting(rθ))
    end

    @testset "政府赤字 ↔ 家計金融資産増加の対応" begin
        # H_0=0 から出発。各期: 家計貨幣ストック増 = 政府赤字（G−T）
        s = simulate(m, 0.0; T = 30)
        r = sfc_result(m, s; scenario_name = "baseline")
        Hprev = 0.0
        for (t, snap) in enumerate(r.snapshots)
            deficit = s.G[t] - s.T[t]
            dH_household = s.H[t] - Hprev
            @test dH_household ≈ deficit atol = 1e-10
            # 貸借対照表: 家計の貨幣資産 = 政府の貨幣負債
            @test holding(snap.balance_sheet, :money, :households) ≈ s.H[t] atol = 1e-10
            @test holding(snap.balance_sheet, :money, :government) ≈ -s.H[t] atol = 1e-10
            # 純資産: 家計 +H、政府 −H
            @test net_worth(snap.balance_sheet, :households) ≈ 0.0 atol = 1e-9
            Hprev = s.H[t]
        end
        # 政府支出増で赤字拡大 → 家計資産がより速く増える
        base = simulate(m, 0.0; T = 30)
        boosted = impulse_response(m, 5.0; shock = :G, T = 30, permanent = true, H0 = 0.0)
        @test boosted.H[end] > base.H[end]
    end

    @testset "SimulationResult adapter と既存 API 接続" begin
        s = simulate(m, 0.0; T = 25)
        sr = to_simulation_result(m, s, "baseline")
        # SimulationResult → sfc_result（設計 §5.4 の復元 adapter）
        r = sfc_result(sr)
        @test accounting_passed(validate_sfc_accounting(r))
        @test r.simulation_result === sr
        # SFCResult に埋め込まれた SimulationResult で既存 API が使える
        emb = r.simulation_result
        @test emb isa SimulationResult
        @test haskey(emb, "Y") && haskey(emb, "H")
        summary = summarize_result(emb)
        @test summary["nperiods"] == 25
        @test haskey(summary["variables"], "Y")
        p = plot_result(emb; vars = ["Y", "C"])
        @test p !== nothing

        # 必須変数が欠けると ArgumentError
        bad = SimulationResult("SIM Model", "x", Dict("Y" => [1.0]))
        @test_throws ArgumentError sfc_result(bad)
    end

    @testset "不正 parameter・負期間・不明ショック" begin
        @test_throws ArgumentError SIMModel(α1 = 1.2, α2 = 0.4, θ = 0.2, G = 20.0)
        @test_throws ArgumentError SIMModel(α1 = 0.6, α2 = 0.7, θ = 0.2, G = 20.0)  # α2≥α1
        @test_throws ArgumentError SIMModel(α1 = 0.6, α2 = 0.4, θ = 1.5, G = 20.0)
        @test_throws ArgumentError SIMModel(α1 = 0.6, α2 = 0.4, θ = 0.2, G = -1.0)
        @test_throws ArgumentError SIMModel(α1 = 0.6, α2 = 0.4, θ = 0.2, G = 20.0, W = 0.0)
        @test_throws ArgumentError simulate(m, 0.0; T = 0)
        @test_throws ArgumentError simulate(m, 0.0; T = -5)
        @test_throws ArgumentError impulse_response(m, 1.0; shock = :unknown, T = 10)
        @test_throws ArgumentError impulse_response(m, -0.3; shock = :θ, T = 10)   # θ→負
        @test_throws ArgumentError impulse_response(m, 0.9; shock = :θ, T = 10)    # θ→>1
        @test_throws ArgumentError impulse_response(m, -100.0; shock = :G, T = 10) # G→負
        @test_throws ArgumentError impulse_response(
            m,
            1.0;
            shock = :G,
            T = 10,
            shock_start = 20,
        )
    end

    @testset "非有限値（発散）の扱い" begin
        # 非有限な初期ストックはそのまま伝播し、会計検証は invalid として構造化する（例外にしない）
        s = simulate(m, NaN; T = 5)
        @test all(isnan, s.H)
        r = sfc_result(m, s; scenario_name = "nan")
        rep = validate_sfc_accounting(r)
        @test rep.status === acc_invalid
        @test length(rep.invalid_periods) == 5
        @test r.metadata["accounting_status"] == "invalid"
        @test !isempty(r.warnings)
    end

    @testset "決定的（fixture 非依存・同一入力で同一 report）" begin
        s = simulate(m, 0.0; T = 20)
        r1 = sfc_result(m, s; scenario_name = "baseline")
        r2 = sfc_result(m, s; scenario_name = "baseline")
        rep1 = validate_sfc_accounting(r1)
        rep2 = validate_sfc_accounting(r2)
        @test isequal(rep1, rep2)
        # 部門・instrument 軸は入力順に依存せず正準化されている
        @test [sec.id for sec in r1.sectors] == [:government, :households, :production]
        @test [ins.id for ins in r1.instruments] == [:money, :net_worth]
    end
end
