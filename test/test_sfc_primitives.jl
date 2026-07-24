# SFC 会計プリミティブ（src/sfc/）のテスト
#
# カバレッジ:
#   - 最小 2 部門・1 金融商品の正常構築と導出量
#   - stable id 重複 / 次元不一致 / 未知参照の拒否
#   - 入力順・Dict 反復順に依存しない決定的な軸順序
#   - JSON round-trip（to_dict/to_json/from_dict、save/load）と決定的な出力
#   - 空行列・0 値・負値・NaN/Inf を含む境界ケース

const JSON3 = DME.JSON3

# ---- 正常 fixture を組み立てるヘルパー ------------------------------------
function sfc_normal_fixture()
    hh = SFCSector(id = :households, name = "家計", sector_type = :household)
    gov = SFCSector(id = :government, name = "政府", sector_type = :government)
    money = SFCInstrument(
        id = :money,
        name = "政府貨幣",
        issuers = [:government],
        holders = [:households],
        unit = "円",
    )
    # instrument(money) × sector、資産+ / 負債−
    bs = BalanceSheetMatrix(
        instruments = [:money],
        sectors = [:households, :government],
        holdings = [100.0 -100.0],
    )
    tf = TransactionFlowMatrix(
        transactions = [:money_change],
        sectors = [:households, :government],
        flows = [-20.0 20.0],
    )
    snap = SFCPeriodSnapshot("2020", bs, tf)
    meth = SFCMethodologyMetadata(model_version = "sfc-sim/1.0.0")
    r = SFCResult(
        model_name = "SIM",
        scenario_name = "baseline",
        sectors = [gov, hh],
        instruments = [money],
        snapshots = [snap],
        methodology = meth,
        metadata = Dict{String, Any}("note" => "test"),
    )
    return (; hh, gov, money, bs, tf, snap, meth, r)
end

@testset "SFC 会計プリミティブ" begin
    @testset "正常構築と導出量" begin
        f = sfc_normal_fixture()
        @test net_worth(f.bs, :households) == 100.0
        @test net_worth(f.bs, :government) == -100.0
        @test total_assets(f.bs, :households) == 100.0
        @test total_liabilities(f.bs, :households) == 0.0
        @test total_assets(f.bs, :government) == 0.0
        @test total_liabilities(f.bs, :government) == 100.0
        @test holding(f.bs, :money, :households) == 100.0
        @test flow_value(f.tf, :money_change, :government) == 20.0
        # 資産負債は誰かの負債（行和 0）: プリミティブ側で計算だけ確認（判定は対象外）
        @test sum(f.bs.holdings) == 0.0
        # 未知参照アクセスは拒否
        @test_throws ArgumentError net_worth(f.bs, :firm)
        @test_throws ArgumentError holding(f.bs, :bonds, :households)
    end

    @testset "決定的な軸順序（入力順に非依存）" begin
        bs_a = BalanceSheetMatrix(
            instruments = [:money],
            sectors = [:households, :government],
            holdings = [100.0 -100.0],
        )
        bs_b = BalanceSheetMatrix(
            instruments = [:money],
            sectors = [:government, :households],
            holdings = [-100.0 100.0],
        )
        # stable id 昇順へ正準化されるため、入力順が違っても等価
        @test bs_a.sectors == bs_b.sectors == [:government, :households]
        @test bs_a.holdings == bs_b.holdings
        @test to_dict(bs_a) == to_dict(bs_b)

        # SFCResult 登録簿も id 昇順
        f = sfc_normal_fixture()
        @test [s.id for s in f.r.sectors] == [:government, :households]
        @test [i.id for i in f.r.instruments] == [:money]

        # 複数 transaction / instrument の並べ替え
        tf = TransactionFlowMatrix(
            transactions = [:wages, :taxes, :consumption],
            sectors = [:government, :households],
            flows = [1.0 2.0; 3.0 4.0; 5.0 6.0],
        )
        @test tf.transactions == [:consumption, :taxes, :wages]
        # consumption 行（元 index 3）→ [5.0 6.0]
        @test tf.flows[1, :] == [5.0, 6.0]
    end

    @testset "表示名変更が保存形式・比較キーを壊さない" begin
        s1 = SFCSector(id = :households, name = "家計", sector_type = :household)
        s2 = SFCSector(id = :households, name = "Households", sector_type = :household)
        # id が保存キー。表示名が変わっても id は不変
        @test to_dict(s1)["id"] == to_dict(s2)["id"] == "households"
        @test to_dict(s1)["name"] != to_dict(s2)["name"]
    end

    @testset "不正入力の拒否" begin
        # 未知 sector_type
        @test_throws ArgumentError SFCSector(id = :x, name = "x", sector_type = :banana)
        # 未知 sign / time convention・負の許容誤差
        @test_throws ArgumentError SFCMethodologyMetadata(sign_convention = :foo)
        @test_throws ArgumentError SFCMethodologyMetadata(time_convention = :foo)
        @test_throws ArgumentError SFCMethodologyMetadata(tolerance_abs = -1.0)
        # stable id 重複
        @test_throws ArgumentError BalanceSheetMatrix(
            instruments = [:money, :money],
            sectors = [:households],
            holdings = reshape([1.0, 2.0], 2, 1),
        )
        @test_throws ArgumentError TransactionFlowMatrix(
            transactions = [:t],
            sectors = [:s, :s],
            flows = [1.0 2.0],
        )
        # 次元不一致
        @test_throws ArgumentError BalanceSheetMatrix(
            instruments = [:money],
            sectors = [:s1, :s2],
            holdings = reshape([1.0], 1, 1),
        )
        # 未知参照（登録簿に無い sector / instrument）
        hh = SFCSector(id = :households, name = "家計", sector_type = :household)
        money = SFCInstrument(id = :money, name = "貨幣")
        bs = BalanceSheetMatrix(
            instruments = [:money],
            sectors = [:households, :government],
            holdings = [1.0 -1.0],
        )
        tf = TransactionFlowMatrix(
            transactions = [:t],
            sectors = [:households, :government],
            flows = [0.0 0.0],
        )
        @test_throws ArgumentError SFCResult(
            model_name = "m",
            scenario_name = "s",
            sectors = [hh],           # :government 未登録
            instruments = [money],
            snapshots = [SFCPeriodSnapshot("2020", bs, tf)],
        )
        bs2 = BalanceSheetMatrix(
            instruments = [:money, :bonds],   # :bonds 未登録
            sectors = [:households],
            holdings = reshape([1.0, 2.0], 2, 1),
        )
        tf2 = TransactionFlowMatrix(
            transactions = [:t],
            sectors = [:households],
            flows = reshape([0.0], 1, 1),
        )
        @test_throws ArgumentError SFCResult(
            model_name = "m",
            scenario_name = "s",
            sectors = [hh],
            instruments = [money],
            snapshots = [SFCPeriodSnapshot("2020", bs2, tf2)],
        )
    end

    @testset "JSON round-trip と決定性" begin
        f = sfc_normal_fixture()
        # to_dict/from_dict
        r2 = sfc_result_from_dict(to_dict(f.r))
        @test to_dict(r2) == to_dict(f.r)
        # to_json/from_json
        r3 = sfc_result_from_json(to_json(f.r))
        @test to_dict(r3) == to_dict(f.r)
        # 出力が決定的（同一入力から同一 JSON 文字列）
        @test to_json(f.r) == to_json(sfc_normal_fixture().r)

        # save / load（ファイル往復）
        dir = mktempdir()
        path = joinpath(dir, "sfc_result.json")
        @test save_sfc_result(path, f.r) == path
        @test isfile(path)
        r4 = load_sfc_result(path)
        @test to_dict(r4) == to_dict(f.r)
        # 復元後も導出量が一致
        @test net_worth(r4.snapshots[1].balance_sheet, :households) == 100.0

        # SimulationResult を束ねた場合の往復
        sr = SimulationResult(
            "SIM",
            "baseline",
            Dict{String, Vector{Float64}}("Y" => [1.0, 2.0], "H" => [0.0, 1.0]),
            Dict{String, Any}("periods" => 2),
        )
        rr = SFCResult(
            model_name = "SIM",
            scenario_name = "baseline",
            sectors = [f.hh, f.gov],
            instruments = [f.money],
            snapshots = [f.snap],
            simulation_result = sr,
            methodology = f.meth,
        )
        rr2 = sfc_result_from_json(to_json(rr))
        @test rr2.simulation_result !== nothing
        @test rr2.simulation_result.variables["Y"] == [1.0, 2.0]
        @test to_dict(rr2) == to_dict(rr)
    end

    @testset "境界ケース（空・0・負・非有限）" begin
        # 空: 0 instrument × 2 sector
        ebs = BalanceSheetMatrix(
            instruments = Symbol[],
            sectors = [:households, :government],
            holdings = Matrix{Float64}(undef, 0, 2),
        )
        @test size(ebs.holdings) == (0, 2)
        @test net_worth(ebs, :households) == 0.0
        @test total_assets(ebs, :households) == 0.0
        ebs2 = DME.balance_sheet_from_dict(to_dict(ebs))
        @test size(ebs2.holdings) == (0, 2)
        @test ebs2.sectors == [:government, :households]

        # 0 値・負値
        zbs = BalanceSheetMatrix(
            instruments = [:money],
            sectors = [:households, :government],
            holdings = [0.0 0.0],
        )
        @test net_worth(zbs, :households) == 0.0

        # 非有限値: 保持され round-trip で失われない
        nbs = BalanceSheetMatrix(
            instruments = [:money, :bonds],
            sectors = [:households, :government],
            holdings = [NaN Inf; -Inf 5.0],
        )
        nbs2 = DME.balance_sheet_from_dict(to_dict(nbs))
        @test any(isnan, nbs2.holdings)
        @test count(isinf, nbs2.holdings) == 2
        # 文字列符号化のため to_dict は NaN 安全に比較できる
        @test to_dict(nbs2) == to_dict(nbs)
        # 非有限値は資産/負債集計から除外し、5.0 のみ集計される
        @test total_assets(nbs2, :government) == 5.0
        @test total_liabilities(nbs2, :government) == 0.0
    end
end
