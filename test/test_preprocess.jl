@testset "前処理ユーティリティ" begin
    # テスト用ヘルパー: 四半期系列
    function make_q(vals; dates=["2020-Q1","2020-Q2","2020-Q3","2020-Q4"])
        DataSeries(id="TEST", name="Test", source="src",
                   frequency=Quarterly, unit="index", dates=dates, values=vals)
    end

    # -----------------------------------------------------------------------
    @testset "fill_missing" begin
        vals = Union{Float64,Missing}[missing, 2.0, missing, 4.0, missing]
        dates = ["2020-Q1","2020-Q2","2020-Q3","2020-Q4","2021-Q1"]
        s = DataSeries(id="T", name="T", source="s",
                       frequency=Quarterly, unit="u", dates=dates, values=vals)

        @testset "forward" begin
            r = fill_missing(s; method=:forward)
            @test ismissing(r.values[1])       # 先頭は埋められない
            @test r.values[2] == 2.0
            @test r.values[3] == 2.0           # 前値で補完
            @test r.values[4] == 4.0
            @test r.values[5] == 4.0           # 前値で補完
        end

        @testset "backward" begin
            r = fill_missing(s; method=:backward)
            @test r.values[1] == 2.0           # 後ろ値で補完
            @test r.values[3] == 4.0
            @test ismissing(r.values[5])       # 末尾は埋められない
        end

        @testset "zero" begin
            r = fill_missing(s; method=:zero)
            @test r.values[1] == 0.0
            @test r.values[3] == 0.0
            @test r.values[5] == 0.0
        end

        @testset "数値定数" begin
            r = fill_missing(s; method=99.0)
            @test r.values[1] == 99.0
            @test r.values[3] == 99.0
            @test r.values[5] == 99.0
            @test r.values[2] == 2.0           # 非欠損値は変わらない
        end

        @testset "不正 method でエラー" begin
            @test_throws ArgumentError fill_missing(s; method=:unknown)
        end

        @testset "metadata・メタフィールド保持" begin
            r = fill_missing(s; method=:zero)
            @test r.source    == s.source
            @test r.frequency == s.frequency
            @test r.unit      == s.unit
            @test "fill_missing(method=:zero)" in r.metadata["transformations"]
        end
    end

    # -----------------------------------------------------------------------
    @testset "drop_missing" begin
        vals = Union{Float64,Missing}[1.0, missing, 3.0, missing, 5.0]
        dates = ["2020-Q1","2020-Q2","2020-Q3","2020-Q4","2021-Q1"]
        s = DataSeries(id="T", name="T", source="s",
                       frequency=Quarterly, unit="u", dates=dates, values=vals)
        r = drop_missing(s)

        @test length(r) == 3
        @test r.dates  == ["2020-Q1","2020-Q3","2021-Q1"]
        @test r.values == [1.0, 3.0, 5.0]
        @test "drop_missing" in r.metadata["transformations"]
    end

    # -----------------------------------------------------------------------
    @testset "apply_log" begin
        s = make_q([1.0, exp(1.0), 100.0, missing])

        @testset "基本変換" begin
            r = apply_log(s)
            @test r.values[1] ≈ 0.0 atol=1e-12
            @test r.values[2] ≈ 1.0 atol=1e-12
            @test r.values[3] ≈ log(100.0) atol=1e-12
            @test ismissing(r.values[4])
        end

        @testset "unit 更新" begin
            r = apply_log(s)
            @test r.unit == "log(index)"
        end

        @testset "非正値でエラー" begin
            s_neg = make_q([1.0, 0.0, 3.0, 4.0])
            @test_throws DomainError apply_log(s_neg)
            s_neg2 = make_q([1.0, -1.0, 3.0, 4.0])
            @test_throws DomainError apply_log(s_neg2)
        end

        @testset "transformations 記録" begin
            r = apply_log(s)
            @test "apply_log" in r.metadata["transformations"]
        end
    end

    # -----------------------------------------------------------------------
    @testset "difference" begin
        s = make_q([10.0, 12.0, 11.0, 14.0])

        @testset "periods=1" begin
            r = difference(s)
            @test length(r) == 3
            @test r.values[1] ≈ 2.0
            @test r.values[2] ≈ -1.0
            @test r.values[3] ≈ 3.0
            @test r.dates == ["2020-Q2","2020-Q3","2020-Q4"]
        end

        @testset "periods=2" begin
            r = difference(s; periods=2)
            @test length(r) == 2
            @test r.values[1] ≈ 1.0   # 11-10
            @test r.values[2] ≈ 2.0   # 14-12
        end

        @testset "欠損値の伝播" begin
            vals = Union{Float64,Missing}[1.0, missing, 3.0, 4.0]
            s_m = make_q(vals)
            r = difference(s_m)
            @test ismissing(r.values[1])  # missing - 1.0
            @test ismissing(r.values[2])  # 3.0 - missing
            @test r.values[3] ≈ 1.0
        end

        @testset "unit 更新" begin
            r = difference(s)
            @test r.unit == "Δ(index)"
        end

        @testset "transformations 記録" begin
            r = difference(s)
            @test "difference(periods=1)" in r.metadata["transformations"]
        end

        @testset "引数エラー" begin
            @test_throws ArgumentError difference(s; periods=0)
            @test_throws ArgumentError difference(s; periods=4)
        end
    end

    # -----------------------------------------------------------------------
    @testset "pct_change" begin
        s = make_q([100.0, 110.0, 99.0, 121.0])

        @testset "periods=1" begin
            r = pct_change(s)
            @test length(r) == 3
            @test r.values[1] ≈ 10.0   # (110-100)/100*100
            @test r.values[2] ≈ -10.0  # (99-110)/110*100
            @test r.unit == "%"
        end

        @testset "ゼロ除算 → missing" begin
            s_zero = make_q([0.0, 10.0, 20.0, 30.0])
            r = pct_change(s_zero)
            @test ismissing(r.values[1])
        end

        @testset "欠損値の伝播" begin
            vals = Union{Float64,Missing}[100.0, missing, 120.0, 130.0]
            s_m = make_q(vals)
            r = pct_change(s_m)
            @test ismissing(r.values[1])  # missing / 100
            @test ismissing(r.values[2])  # 120 / missing
        end

        @testset "transformations 記録" begin
            r = pct_change(s)
            @test "pct_change(periods=1)" in r.metadata["transformations"]
        end
    end

    # -----------------------------------------------------------------------
    @testset "moving_average" begin
        s = make_q([1.0, 2.0, 3.0, 4.0])

        @testset "window=3" begin
            r = moving_average(s; window=3)
            @test ismissing(r.values[1])
            @test ismissing(r.values[2])
            @test r.values[3] ≈ 2.0   # mean(1,2,3)
            @test r.values[4] ≈ 3.0   # mean(2,3,4)
        end

        @testset "window=1（恒等変換）" begin
            r = moving_average(s; window=1)
            @test r.values == [1.0, 2.0, 3.0, 4.0]
        end

        @testset "ウィンドウ内欠損 → missing" begin
            vals = Union{Float64,Missing}[1.0, missing, 3.0, 4.0]
            s_m = make_q(vals)
            r = moving_average(s_m; window=2)
            @test ismissing(r.values[2])  # missing + 1.0
            @test ismissing(r.values[3])  # 3.0 + missing
            @test r.values[4] ≈ 3.5
        end

        @testset "unit 保持" begin
            r = moving_average(s; window=2)
            @test r.unit == s.unit
        end

        @testset "引数エラー" begin
            @test_throws ArgumentError moving_average(s; window=0)
            @test_throws ArgumentError moving_average(s; window=5)
        end
    end

    # -----------------------------------------------------------------------
    @testset "standardize" begin
        s = make_q([1.0, 2.0, 3.0, 4.0])

        @testset "基本標準化" begin
            r = standardize(s)
            nm = collect(Float64, skipmissing(r.values))
            @test abs(sum(nm) / length(nm)) < 1e-12   # 平均 ≈ 0
            @test abs(sum(v^2 for v in nm) / length(nm) - 1.0) < 1e-12  # 分散 ≈ 1
        end

        @testset "unit 更新" begin
            r = standardize(s)
            @test r.unit == "standardized"
        end

        @testset "欠損値は欠損のまま" begin
            vals = Union{Float64,Missing}[1.0, missing, 3.0, 4.0]
            s_m = make_q(vals)
            r = standardize(s_m)
            @test ismissing(r.values[2])
            @test !ismissing(r.values[1])
        end

        @testset "標準偏差 0 でエラー" begin
            s_flat = make_q([5.0, 5.0, 5.0, 5.0])
            @test_throws DomainError standardize(s_flat)
        end

        @testset "transformations 記録" begin
            r = standardize(s)
            @test any(startswith(t, "standardize(") for t in r.metadata["transformations"])
        end
    end

    # -----------------------------------------------------------------------
    @testset "trim_period" begin
        dates = ["2020-Q1","2020-Q2","2020-Q3","2020-Q4","2021-Q1"]
        s = DataSeries(id="T", name="T", source="s",
                       frequency=Quarterly, unit="u",
                       dates=dates, values=[1.0,2.0,3.0,4.0,5.0])

        @testset "start_date のみ" begin
            r = trim_period(s; start_date="2020-Q2")
            @test r.dates == ["2020-Q2","2020-Q3","2020-Q4","2021-Q1"]
            @test r.values == [2.0,3.0,4.0,5.0]
        end

        @testset "end_date のみ" begin
            r = trim_period(s; end_date="2020-Q3")
            @test r.dates == ["2020-Q1","2020-Q2","2020-Q3"]
        end

        @testset "両方指定" begin
            r = trim_period(s; start_date="2020-Q2", end_date="2020-Q4")
            @test length(r) == 3
            @test r.dates == ["2020-Q2","2020-Q3","2020-Q4"]
        end

        @testset "不正日付でエラー" begin
            @test_throws KeyError trim_period(s; start_date="9999-Q1")
            @test_throws KeyError trim_period(s; end_date="9999-Q1")
        end

        @testset "start > end でエラー" begin
            @test_throws ArgumentError trim_period(s; start_date="2020-Q4", end_date="2020-Q2")
        end

        @testset "metadata 保持" begin
            r = trim_period(s; start_date="2020-Q2")
            @test r.frequency == Quarterly
            @test any(startswith(t, "trim_period(") for t in r.metadata["transformations"])
        end
    end

    # -----------------------------------------------------------------------
    @testset "to_quarterly" begin
        monthly_dates = [
            "2020-01","2020-02","2020-03",
            "2020-04","2020-05","2020-06",
            "2020-07","2020-08","2020-09",
            "2020-10","2020-11","2020-12",
        ]
        monthly_vals = [1.0,2.0,3.0, 4.0,5.0,6.0, 7.0,8.0,9.0, 10.0,11.0,12.0]
        s = DataSeries(id="M", name="M", source="s",
                       frequency=Monthly, unit="index",
                       dates=monthly_dates, values=monthly_vals)

        @testset "mean 集計" begin
            r = to_quarterly(s)
            @test r.frequency == Quarterly
            @test r.dates == ["2020-Q1","2020-Q2","2020-Q3","2020-Q4"]
            @test r.values[1] ≈ 2.0   # mean(1,2,3)
            @test r.values[2] ≈ 5.0   # mean(4,5,6)
            @test r.values[3] ≈ 8.0
            @test r.values[4] ≈ 11.0
        end

        @testset "sum 集計" begin
            r = to_quarterly(s; method=:sum)
            @test r.values[1] ≈ 6.0   # 1+2+3
            @test r.values[2] ≈ 15.0  # 4+5+6
        end

        @testset "月内欠損は除いて集計" begin
            vals_m = Union{Float64,Missing}[1.0, missing, 3.0,
                                             4.0, 5.0, 6.0,
                                             7.0, 8.0, 9.0,
                                             10.0, 11.0, 12.0]
            s_m = DataSeries(id="M", name="M", source="s",
                             frequency=Monthly, unit="index",
                             dates=monthly_dates, values=vals_m)
            r = to_quarterly(s_m)
            @test r.values[1] ≈ 2.0   # mean(1,3): missing 除外
        end

        @testset "非月次でエラー" begin
            s_q = make_q([1.0,2.0,3.0,4.0])
            @test_throws ArgumentError to_quarterly(s_q)
        end

        @testset "transformations 記録" begin
            r = to_quarterly(s)
            @test "to_quarterly(method=mean)" in r.metadata["transformations"]
        end
    end

    # -----------------------------------------------------------------------
    @testset "to_annual" begin
        s = make_q([1.0, 2.0, 3.0, 4.0,   # 2020
                    5.0, 6.0, 7.0, 8.0],  # 2021
                   dates=["2020-Q1","2020-Q2","2020-Q3","2020-Q4",
                          "2021-Q1","2021-Q2","2021-Q3","2021-Q4"])

        @testset "mean 集計" begin
            r = to_annual(s)
            @test r.frequency == Annual
            @test r.dates == ["2020","2021"]
            @test r.values[1] ≈ 2.5   # mean(1,2,3,4)
            @test r.values[2] ≈ 6.5
        end

        @testset "sum 集計" begin
            r = to_annual(s; method=:sum)
            @test r.values[1] ≈ 10.0
            @test r.values[2] ≈ 26.0
        end

        @testset "四半期内欠損は除いて集計" begin
            vals_m = Union{Float64,Missing}[1.0, missing, 3.0, 4.0,
                                             5.0, 6.0, 7.0, 8.0]
            s_m = DataSeries(id="T", name="T", source="s",
                             frequency=Quarterly, unit="u",
                             dates=["2020-Q1","2020-Q2","2020-Q3","2020-Q4",
                                    "2021-Q1","2021-Q2","2021-Q3","2021-Q4"],
                             values=vals_m)
            r = to_annual(s_m)
            @test r.values[1] ≈ 8.0/3  # mean(1,3,4)
        end

        @testset "非四半期次でエラー" begin
            s_a = DataSeries(id="A", name="A", source="s",
                             frequency=Annual, unit="u",
                             dates=["2020","2021"], values=[1.0,2.0])
            @test_throws ArgumentError to_annual(s_a)
        end

        @testset "transformations 記録" begin
            r = to_annual(s)
            @test "to_annual(method=mean)" in r.metadata["transformations"]
        end
    end

    # -----------------------------------------------------------------------
    @testset "変換履歴の累積" begin
        s = make_q([1.0, 2.0, 3.0, 4.0])
        r = s |> apply_log |> standardize
        @test length(r.metadata["transformations"]) == 2
        @test r.metadata["transformations"][1] == "apply_log"
        @test startswith(r.metadata["transformations"][2], "standardize(")
    end

    @testset "既存 metadata の保持" begin
        meta = Dict{String,Any}("seasonal_adjustment" => "SA")
        s = DataSeries(id="T", name="T", source="FRED",
                       frequency=Quarterly, unit="u",
                       dates=["2020-Q1","2020-Q2","2020-Q3","2020-Q4"],
                       values=[1.0,2.0,3.0,4.0], metadata=meta)
        r = apply_log(s)
        @test r.metadata["seasonal_adjustment"] == "SA"
        @test "apply_log" in r.metadata["transformations"]
    end
end
