@testset "RBC" begin
    rbc = RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9)
    @testset "calc_ep" begin
        rtn = DME.calc_ep(rbc)
        @test rtn[1] ≈ 1.0 atol=1e-3
        @test rtn[2] ≈ 0.0351 atol=1e-3
        @test rtn[3] ≈ 1.7557 atol=1e-3
        @test rtn[4] ≈ 0.6672 atol=1e-3
        @test rtn[5] ≈ 14.301 atol=1e-3
        @test rtn[6] ≈ 1.6733 atol=1e-3
        @test rtn[7] ≈ 1.3158 atol=1e-3
    end
end

@testset "カスタム設定でのシミュレーション（RBC）" begin
    rbc = RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9)

    @testset "find_path（RBC）カスタム maxT" begin
        A⃰, _, _, _, K⃰, _, _ = DME.calc_ep(rbc)
        rtn = DME.find_path(rbc, A⃰ * 0.9, K⃰ * 0.9; maxT = 30)
        @test length(rtn["K"]) == 31  # maxT + 1
        @test length(rtn["A"]) == 31
    end

    @testset "shock カスタム maxT" begin
        rtn = DME.shock(rbc, 0.01; maxT = 30)
        @test length(rtn["â"]) == 31  # maxT + 1
        @test length(rtn["ĉ"]) == 31
    end
end
