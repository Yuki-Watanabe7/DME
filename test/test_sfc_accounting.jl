# SFC 会計恒等式検証エンジン（src/analysis/sfc_accounting.jl）のテスト
#
# カバレッジ（Issue #147 受け入れ条件）:
#   - 正常な複数期 fixture が全 check を pass する
#   - 取引行・sector 列・資産負債対応・stock-flow 更新をそれぞれ単独で壊した fixture が
#     該当 check だけを fail する
#   - 許容誤差の境界値・NaN/Inf（invalid）・period 欠落/重複/順序の構造検証
#   - SFCResult 保存→再読込後も同じ report を得る（決定性）
#   - 外部接続なしに実行可能

# ---- SIM 型の会計整合スナップショットを組み立てるヘルパー -------------------
# 部門: households / production / government、金融商品: money（+ 純資産バランス行 net_worth）。
# source_use 符号で行和・列和・stock_flow がすべて 0 になる整合値のみを受け取る。
function sim_snapshot(period; H_prev, H, Y, C, G, T)
    WN = Y                       # 利潤ゼロ（WN = Y）
    dH = H - H_prev              # 当期の貨幣蓄積
    # 貸借対照表: 行 = [money, net_worth]、列 = [households, production, government]
    bs = BalanceSheetMatrix(
        instruments = [:money, :net_worth],
        sectors = [:households, :production, :government],
        holdings = [H 0.0 -H; -H 0.0 H],
    )
    # 取引フロー: 行 = 取引、列 = 部門（源泉+ / 使途−）
    tf = TransactionFlowMatrix(
        transactions = [:consumption, :govt_expenditure, :wages, :taxes, :money_change],
        sectors = [:households, :production, :government],
        flows = [
            -C C 0.0
            0.0 G -G
            WN -WN 0.0
            -T 0.0 T
            -dH 0.0 dH
        ],
    )
    return SFCPeriodSnapshot(period, bs, tf)
end

function sfc_accounting_fixture()
    hh = SFCSector(id = :households, name = "家計", sector_type = :household)
    pr = SFCSector(id = :production, name = "生産", sector_type = :firm)
    gov = SFCSector(id = :government, name = "政府", sector_type = :government)
    money = SFCInstrument(
        id = :money,
        name = "政府貨幣",
        issuers = [:government],
        holders = [:households],
        unit = "円",
    )
    nw = SFCInstrument(
        id = :net_worth,
        name = "純資産",
        metadata = Dict{String, Any}("role" => "balancing"),
    )
    # 2020: H 0→80（YD=180, C=100, saving=80; G−T=80）
    s2020 = sim_snapshot(
        "2020";
        H_prev = 0.0,
        H = 80.0,
        Y = 200.0,
        C = 100.0,
        G = 100.0,
        T = 20.0,
    )
    # 2021: H 80→100（YD=90, C=70, saving=20; G−T=20）
    s2021 = sim_snapshot(
        "2021";
        H_prev = 80.0,
        H = 100.0,
        Y = 100.0,
        C = 70.0,
        G = 30.0,
        T = 10.0,
    )
    meth = SFCMethodologyMetadata(model_version = "sfc-sim/1.0.0")
    r = SFCResult(
        model_name = "SIM",
        scenario_name = "baseline",
        sectors = [gov, hh, pr],
        instruments = [money, nw],
        snapshots = [s2020, s2021],
        methodology = meth,
    )
    return (; hh, pr, gov, money, nw, meth, s2020, s2021, r)
end

# fixture の 1 snapshot の行列を差し替えて壊す（登録簿はそのまま）。
function _rebuild_with_second(f, snap2)
    return SFCResult(
        model_name = f.r.model_name,
        scenario_name = f.r.scenario_name,
        sectors = [f.gov, f.hh, f.pr],
        instruments = [f.money, f.nw],
        snapshots = [f.s2020, snap2],
        methodology = f.meth,
    )
end

@testset "SFC 会計恒等式検証エンジン" begin
    @testset "正常な複数期 fixture は全 check pass" begin
        f = sfc_accounting_fixture()
        rep = validate_sfc_accounting(f.r)
        @test accounting_passed(rep)
        @test rep.status == acc_pass
        @test isempty(rep.violations)
        @test rep.checks_performed == rep.checks_passed
        @test rep.checks_performed > 0
        @test rep.max_abs_residual <= 1e-8
        @test rep.invalid_periods == String[]
        @test rep.valid_periods == ["2020", "2021"]
        @test rep.divergence_time === nothing
        @test accounting_status_label(rep.status) == "pass"
        # stock_flow が実際に評価されている（2 期あるので money 行が検証される）
        # 単一 snapshot 版は期内検証のみ
        rep1 = validate_sfc_accounting(f.s2020)
        @test accounting_passed(rep1)
    end

    @testset "取引行を壊すと flow_row_sum だけ fail" begin
        f = sfc_accounting_fixture()
        # 2021 の wages 行の生産部門を −100 → −90 にして行和を崩す（列和も崩れるが下でsector単独版で確認）
        tf = f.s2021.transaction_flow
        bad_flows = copy(tf.flows)
        wi = findfirst(==(:wages), tf.transactions)
        pj = findfirst(==(:production), tf.sectors)
        bad_flows[wi, pj] += 10.0   # 行和 = +10、生産列も +10 崩れる
        bad_tf = TransactionFlowMatrix(
            transactions = tf.transactions,
            sectors = tf.sectors,
            flows = bad_flows,
        )
        snap2 = SFCPeriodSnapshot("2021", f.s2021.balance_sheet, bad_tf)
        rep = validate_sfc_accounting(_rebuild_with_second(f, snap2))
        failed = Set(v.check for v in rep.violations if v.status == acc_fail)
        @test :flow_row_sum in failed
        rowfail =
            [v for v in rep.violations if v.check == :flow_row_sum && v.status == acc_fail]
        @test length(rowfail) == 1
        @test rowfail[1].transaction == :wages
        @test rowfail[1].period == "2021"
        @test rowfail[1].residual ≈ 10.0
    end

    @testset "sector 列を壊すと flow_column_sum だけ fail" begin
        f = sfc_accounting_fixture()
        # money_change 行の政府列だけずらして「行和は保つが列（予算制約）を崩す」…
        # のは行和も崩れるため、相殺する別 sector に載せ替えて列だけ壊す。
        tf = f.s2021.transaction_flow
        bad_flows = copy(tf.flows)
        mi = findfirst(==(:money_change), tf.transactions)
        ti = findfirst(==(:taxes), tf.transactions)
        hj = findfirst(==(:households), tf.sectors)
        gj = findfirst(==(:government), tf.sectors)
        # taxes 家計 −10→−5(+5)、money_change 家計 −20→−25(−5): 各行和は不変、家計列だけ 0→0…
        # 家計列を崩すには行和を保ったまま家計だけ動かす必要があるが 1 セルでは行和が崩れる。
        # そこで taxes 行で家計 +5・政府 −5 と両側動かし各行和保持、列は家計 +5/政府 −5 崩す。
        bad_flows[ti, hj] += 5.0
        bad_flows[ti, gj] -= 5.0
        bad_tf = TransactionFlowMatrix(
            transactions = tf.transactions,
            sectors = tf.sectors,
            flows = bad_flows,
        )
        snap2 = SFCPeriodSnapshot("2021", f.s2021.balance_sheet, bad_tf)
        rep = validate_sfc_accounting(_rebuild_with_second(f, snap2))
        failed = Set(v.check for v in rep.violations if v.status == acc_fail)
        @test :flow_column_sum in failed
        @test !(:flow_row_sum in failed)   # 各行和は保たれている
        colfail = Set(
            v.sector for
            v in rep.violations if v.check == :flow_column_sum && v.status == acc_fail
        )
        @test colfail == Set([:households, :government])
    end

    @testset "資産負債対応を壊すと balance_row_sum だけ fail" begin
        f = sfc_accounting_fixture()
        bs = f.s2021.balance_sheet
        bad_h = copy(bs.holdings)
        mi = findfirst(==(:money), bs.instruments)
        gj = findfirst(==(:government), bs.sectors)
        bad_h[mi, gj] += 30.0   # money 行和を +30 に（政府の負債が過小 → 資産負債不一致）
        bad_bs = BalanceSheetMatrix(
            instruments = bs.instruments,
            sectors = bs.sectors,
            holdings = bad_h,
        )
        snap2 = SFCPeriodSnapshot("2021", bad_bs, f.s2021.transaction_flow)
        rep = validate_sfc_accounting(_rebuild_with_second(f, snap2))
        failed = Set(v.check for v in rep.violations if v.status == acc_fail)
        @test :balance_row_sum in failed
        rowfail = [
            v for v in rep.violations if v.check == :balance_row_sum && v.status == acc_fail
        ]
        @test all(v -> v.instrument == :money && v.period == "2021", rowfail)
    end

    @testset "stock-flow 更新を壊すと stock_flow だけ fail" begin
        f = sfc_accounting_fixture()
        bs = f.s2021.balance_sheet
        bad_h = copy(bs.holdings)
        mi = findfirst(==(:money), bs.instruments)
        nwi = findfirst(==(:net_worth), bs.instruments)
        hj = findfirst(==(:households), bs.sectors)
        gj = findfirst(==(:government), bs.sectors)
        # 家計 money 100→130、対応する純資産も更新して行和・列和は保つ（フローは据え置き）
        bad_h[mi, hj] += 30.0
        bad_h[mi, gj] -= 30.0
        bad_h[nwi, hj] -= 30.0
        bad_h[nwi, gj] += 30.0
        bad_bs = BalanceSheetMatrix(
            instruments = bs.instruments,
            sectors = bs.sectors,
            holdings = bad_h,
        )
        snap2 = SFCPeriodSnapshot("2021", bad_bs, f.s2021.transaction_flow)
        rep = validate_sfc_accounting(_rebuild_with_second(f, snap2))
        failed = Set(v.check for v in rep.violations if v.status == acc_fail)
        @test :stock_flow in failed
        @test !(:balance_row_sum in failed)     # 行和は保った
        @test !(:balance_column_sum in failed)  # 列和も保った
        @test !(:flow_row_sum in failed)
        sf = [v for v in rep.violations if v.check == :stock_flow && v.status == acc_fail]
        @test any(v -> v.instrument == :money && v.sector == :households, sf)
    end

    @testset "許容誤差の境界値" begin
        f = sfc_accounting_fixture()
        bs = f.s2021.balance_sheet
        mi = findfirst(==(:money), bs.instruments)
        hj = findfirst(==(:households), bs.sectors)
        gj = findfirst(==(:government), bs.sectors)
        # money 行和にちょうど誤差を仕込む（行和 = ε）
        function with_row_error(ε)
            h = copy(bs.holdings)
            h[mi, hj] += ε
            bad_bs = BalanceSheetMatrix(
                instruments = bs.instruments,
                sectors = bs.sectors,
                holdings = h,
            )
            snap2 = SFCPeriodSnapshot("2021", bad_bs, f.s2021.transaction_flow)
            return _rebuild_with_second(f, snap2)
        end
        atol = 1e-6
        rtol = 0.0
        # 許容内: ε = atol → pass
        rep_in = validate_sfc_accounting(with_row_error(1e-7); atol = atol, rtol = rtol)
        @test !(:balance_row_sum in Set(v.check for v in rep_in.violations))
        # 許容外: ε = 10*atol → fail
        rep_out = validate_sfc_accounting(with_row_error(1e-5); atol = atol, rtol = rtol)
        @test :balance_row_sum in
              Set(v.check for v in rep_out.violations if v.status == acc_fail)
    end

    @testset "NaN/Inf は invalid（会計違反と別扱い）" begin
        f = sfc_accounting_fixture()
        for badval in (NaN, Inf)
            bs = f.s2020.balance_sheet
            h = copy(bs.holdings)
            h[1, 1] = badval
            bad_bs = BalanceSheetMatrix(
                instruments = bs.instruments,
                sectors = bs.sectors,
                holdings = h,
            )
            snap = SFCPeriodSnapshot("2020", bad_bs, f.s2020.transaction_flow)
            r = SFCResult(
                model_name = "SIM",
                scenario_name = "x",
                sectors = [f.hh, f.pr, f.gov],
                instruments = [f.money, f.nw],
                snapshots = [snap],
                methodology = f.meth,
            )
            rep = validate_sfc_accounting(r)
            @test rep.status == acc_invalid
            @test "2020" in rep.invalid_periods
            @test any(v -> v.status == acc_invalid, rep.violations)
            # 会計違反(fail)には分類しない（invalid が別カテゴリ）
            invalids = [v for v in rep.violations if v.status == acc_invalid]
            @test !isempty(invalids)
        end
        # Inf ストックは divergence_time に記録
        bs = f.s2020.balance_sheet
        h = copy(bs.holdings)
        h[1, 1] = Inf
        bad_bs = BalanceSheetMatrix(
            instruments = bs.instruments,
            sectors = bs.sectors,
            holdings = h,
        )
        snap = SFCPeriodSnapshot("2020", bad_bs, f.s2020.transaction_flow)
        r = SFCResult(
            model_name = "SIM",
            scenario_name = "x",
            sectors = [f.hh, f.pr, f.gov],
            instruments = [f.money, f.nw],
            snapshots = [snap],
            methodology = f.meth,
        )
        @test validate_sfc_accounting(r).divergence_time == "2020"
    end

    @testset "構造検証（period 重複・順序・次元変化）" begin
        f = sfc_accounting_fixture()
        # 重複 period
        dup = SFCResult(
            model_name = "SIM",
            scenario_name = "x",
            sectors = [f.hh, f.pr, f.gov],
            instruments = [f.money, f.nw],
            snapshots = [f.s2020, f.s2020],
            methodology = f.meth,
        )
        rep_dup = validate_sfc_accounting(dup)
        @test :duplicate_period in Set(v.check for v in rep_dup.violations)
        @test rep_dup.status == acc_fail

        # 逆順 period → period_order warning
        rev = SFCResult(
            model_name = "SIM",
            scenario_name = "x",
            sectors = [f.hh, f.pr, f.gov],
            instruments = [f.money, f.nw],
            snapshots = [f.s2021, f.s2020],
            methodology = f.meth,
        )
        rep_rev = validate_sfc_accounting(rev)
        @test :period_order in Set(v.check for v in rep_rev.violations)

        # 次元変化（instrument 軸が異なる）→ dimension_change warning・stock_flow はスキップ
        bs2 = BalanceSheetMatrix(
            instruments = [:money],
            sectors = [:households, :production, :government],
            holdings = [100.0 0.0 -100.0],
        )
        snap_diff = SFCPeriodSnapshot("2021", bs2, f.s2021.transaction_flow)
        # 登録簿には money・net_worth があるので参照は満たす
        rdiff = SFCResult(
            model_name = "SIM",
            scenario_name = "x",
            sectors = [f.hh, f.pr, f.gov],
            instruments = [f.money, f.nw],
            snapshots = [f.s2020, snap_diff],
            methodology = f.meth,
        )
        rep_diff = validate_sfc_accounting(rdiff)
        @test :dimension_change in Set(v.check for v in rep_diff.violations)
        @test !(
            :stock_flow in
            Set(v.check for v in rep_diff.violations if v.status == acc_fail)
        )
    end

    @testset "空行列・0 値を安全に扱う" begin
        # instrument が空・sector のみ
        ebs = BalanceSheetMatrix(
            instruments = Symbol[],
            sectors = [:households, :government],
            holdings = Matrix{Float64}(undef, 0, 2),
        )
        etf = TransactionFlowMatrix(
            transactions = Symbol[],
            sectors = [:households, :government],
            flows = Matrix{Float64}(undef, 0, 2),
        )
        esnap = SFCPeriodSnapshot("2020", ebs, etf)
        hh = SFCSector(id = :households, name = "家計")
        gov = SFCSector(id = :government, name = "政府")
        er = SFCResult(
            model_name = "e",
            scenario_name = "e",
            sectors = [hh, gov],
            instruments = SFCInstrument[],
            snapshots = [esnap],
        )
        rep = validate_sfc_accounting(er)
        # 列和 0（空行の和は 0）→ pass、例外なし
        @test accounting_passed(rep)
    end

    @testset "SFCResult 保存→再読込で同じ report" begin
        f = sfc_accounting_fixture()
        rep1 = validate_sfc_accounting(f.r)
        dir = mktempdir()
        path = joinpath(dir, "sfc.json")
        save_sfc_result(path, f.r)
        r2 = load_sfc_result(path)
        rep2 = validate_sfc_accounting(r2)
        @test isequal(rep1, rep2)

        # 壊した fixture でも round-trip 後に同じ違反集合
        bs = f.s2021.balance_sheet
        h = copy(bs.holdings)
        h[findfirst(==(:money), bs.instruments), findfirst(==(:government), bs.sectors)] +=
            30.0
        bad_bs = BalanceSheetMatrix(
            instruments = bs.instruments,
            sectors = bs.sectors,
            holdings = h,
        )
        rbad = _rebuild_with_second(
            f,
            SFCPeriodSnapshot("2021", bad_bs, f.s2021.transaction_flow),
        )
        repb1 = validate_sfc_accounting(rbad)
        save_sfc_result(path, rbad)
        repb2 = validate_sfc_accounting(load_sfc_result(path))
        @test isequal(repb1, repb2)
        @test repb1.status == acc_fail
    end

    @testset "既定許容誤差は methodology 由来・上書き可能" begin
        f = sfc_accounting_fixture()
        rep = validate_sfc_accounting(f.r)
        @test rep.tolerance_abs == f.meth.tolerance_abs
        @test rep.tolerance_rel == f.meth.tolerance_rel
        rep2 = validate_sfc_accounting(f.r; atol = 1e-3, rtol = 1e-2)
        @test rep2.tolerance_abs == 1e-3
        @test rep2.tolerance_rel == 1e-2
    end

    @testset "to_dict / to_json（Issue #152）" begin
        f = sfc_accounting_fixture()
        rep = validate_sfc_accounting(f.r)
        d = to_dict(rep)
        for k in (
            "status",
            "violations",
            "checks_performed",
            "checks_passed",
            "max_abs_residual",
            "valid_periods",
            "invalid_periods",
            "divergence_time",
            "methodology",
            "tolerance_abs",
            "tolerance_rel",
        )
            @test haskey(d, k)
        end
        @test d["status"] == accounting_status_label(rep.status)
        @test d["checks_performed"] == rep.checks_performed

        j = to_json(rep)
        parsed = DME.JSON3.read(j)
        @test parsed["status"] == "pass"
        @test parsed["checks_performed"] == rep.checks_performed

        # 非有限な残差は "NaN" 文字列タグへ符号化される（round-trip 規約。src/sfc/serialization.jl と同じ）
        broken_violation = AccountingViolation(
            :stock_flow,
            "2021",
            acc_invalid,
            :households,
            :money,
            :money_change,
            NaN,
            0.0,
            1e-8,
            "非有限な残差（テスト用）",
            Dict{String, Any}("delta_stock" => NaN),
        )
        vd = to_dict(broken_violation)
        @test vd["residual"] == "NaN"
        @test vd["evidence"]["delta_stock"] == "NaN"
    end
end
