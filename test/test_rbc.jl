@testset "RBC" begin
    rbc = RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9)
    @testset "calc_ep" begin
        rtn = DME.calc_ep(rbc)
        # 実装と独立に計算した数値アンカー
        @test rtn[1] ≈ 1.0 atol = 1e-12
        @test rtn[2] ≈ 0.035101010101 atol = 1e-8
        @test rtn[3] ≈ 1.755664793114 atol = 1e-8
        @test rtn[4] ≈ 0.667162060525 atol = 1e-8
        @test rtn[5] ≈ 14.301333749920 atol = 1e-8
        @test rtn[6] ≈ 1.673304201380 atol = 1e-8
        @test rtn[7] ≈ 1.315770857632 atol = 1e-8
    end
    @testset "calc_ep が定常条件を満たす" begin
        α, β, γ, δ, μ = rbc.α, rbc.β, rbc.γ, rbc.δ, rbc.μ
        A, r, w, L, K, Y, C = DME.calc_ep(rbc)
        # オイラー方程式の定常形: β(r* - δ + 1) = 1
        @test β * (r - δ + 1) ≈ 1.0 atol = 1e-12
        # 労働供給の一階条件: w*/C* = (γ+1)μL*^γ
        @test w / C ≈ (γ + 1) * μ * L^γ atol = 1e-12
        # 生産関数: Y* = A*K*^α L*^(1-α)
        @test Y ≈ A * K^α * L^(1 - α) atol = 1e-12
        # 要素価格 = 限界生産物
        @test w ≈ (1 - α) * A * K^α * L^(-α) atol = 1e-12
        @test r ≈ α * A * K^(α - 1) * L^(1 - α) atol = 1e-12
        # 資源制約: C* = Y* - δK*
        @test C ≈ Y - δ * K atol = 1e-12
    end
    @testset "find_path が均衡条件を満たす" begin
        α, β, γ, δ, μ, ρ = rbc.α, rbc.β, rbc.γ, rbc.δ, rbc.μ, rbc.ρ
        ep = DME.calc_ep(rbc)
        K⃰ = ep[5]
        d = DME.find_path(rbc, 0.9, K⃰ * 0.9)
        A, r, w, L, K, Y, C = d["A"], d["r"], d["w"], d["L"], d["K"], d["Y"], d["C"]
        @test K[1] == K⃰ * 0.9
        @test A[1] == 0.9
        # 経路全体で 7 本の均衡条件の残差がゼロに近いこと（実測 ~1e-10）
        for i in 1:(length(A) - 1)
            @test -w[i] / C[i] + (γ + 1) * μ * L[i]^γ ≈ 0 atol = 1e-8
            @test C[i + 1] / C[i] ≈ β * (r[i + 1] - δ + 1) atol = 1e-8
            @test Y[i] ≈ A[i] * K[i]^α * L[i]^(1 - α) atol = 1e-8
            @test w[i] ≈ (1 - α) * A[i] * K[i]^α * L[i]^(-α) atol = 1e-8
            @test K[i + 1] ≈ Y[i] + (1 - δ) * K[i] - C[i] atol = 1e-8
            @test r[i] ≈ α * A[i] * K[i]^(α - 1) * L[i]^(1 - α) atol = 1e-8
            @test log(A[i + 1]) ≈ ρ * log(A[i]) atol = 1e-8
        end
        # 定常状態への収束（K の終端は解ベクトル由来で固定されていない）
        @test K[end] ≈ K⃰ atol = 1e-2
    end
    @testset "find_path の定常状態不変性" begin
        # A0 = A*, K0 = K* から出発したら経路は定常状態に張り付くはず
        ep = DME.calc_ep(rbc)
        A⃰, r⃰, w⃰, L⃰, K⃰, Y⃰, C⃰ = ep
        d = DME.find_path(rbc, A⃰, K⃰; maxT = 50)
        @test maximum(abs.(d["K"] .- K⃰)) < 1e-10
        @test maximum(abs.(d["C"] .- C⃰)) < 1e-10
        @test maximum(abs.(d["L"] .- L⃰)) < 1e-10
        @test maximum(abs.(d["Y"] .- Y⃰)) < 1e-10
        @test maximum(abs.(d["r"] .- r⃰)) < 1e-10
        @test maximum(abs.(d["w"] .- w⃰)) < 1e-10
    end
    @testset "shock（対数線形 IRF）の基本性質" begin
        ρ = rbc.ρ
        ϵ0 = 0.01
        d = DME.shock(rbc, ϵ0)
        # TFP は AR(1) を厳密に満たす: â[t] = ρ^(t-1)·ϵ0
        for t in 1:length(d["â"])
            @test d["â"][t] ≈ ρ^(t - 1) * ϵ0 atol = 1e-12
        end
        # 資本は先決変数: ショック期の k̂ はゼロ
        @test d["k̂"][1] == 0.0
        # 正の TFP ショックのインパクト符号
        @test d["ŷ"][1] > 0
        @test d["ĉ"][1] > 0
        @test d["l̂"][1] > 0
        @test d["ŵ"][1] > 0
        @test d["r̂"][1] > 0
        # 長期的にゼロへ減衰（安定性）
        for k in ["â", "ĉ", "k̂", "l̂", "ŷ", "r̂", "ŵ"]
            @test abs(d[k][end]) < 1e-4
        end
        # 線形システムの斉次性: IRF(2ϵ) = 2·IRF(ϵ)
        d2 = DME.shock(rbc, 2 * ϵ0; maxT = 50)
        d1 = DME.shock(rbc, ϵ0; maxT = 50)
        for k in ["â", "ĉ", "k̂", "l̂", "ŷ", "r̂", "ŵ"]
            @test maximum(abs.(d2[k] .- 2 .* d1[k])) < 1e-12
        end
    end
    @testset "対数線形 IRF と非線形完全予見経路のクロス検証" begin
        # 小さいショックなら対数線形 IRF は非線形経路の対数偏差と
        # O(ϵ²) で一致するはず（実測 ~2e-5、IRF 振幅 ~1e-2）
        ϵ0 = 0.01
        ep = DME.calc_ep(rbc)
        A⃰, r⃰, w⃰, L⃰, K⃰, Y⃰, C⃰ = ep
        irf = DME.shock(rbc, ϵ0)
        p = DME.find_path(rbc, exp(ϵ0), K⃰)
        for (irf_key, path_key, ss) in
            [("ĉ", "C", C⃰), ("k̂", "K", K⃰), ("ŷ", "Y", Y⃰), ("l̂", "L", L⃰), ("ŵ", "w", w⃰)]
            @test maximum(abs.(irf[irf_key] .- log.(p[path_key] ./ ss))) < 1e-4
        end
        # r̂ は粗利子率 (1+r) の対数偏差（docs/models/rbc.md 参照）
        @test maximum(abs.(irf["r̂"] .- log.((1 .+ p["r"]) ./ (1 + r⃰)))) < 1e-4
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
