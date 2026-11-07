# 2026-09 financial-instability live holdoutの構造化診断のテスト
# （src/analysis/financial_instability_holdout.jl、Issue #260 Part D）。
#
# fixtureは test/fixtures/data/financial_stress/series/*.json（fictional）に加え、
# overall_statusの4通り（:insufficient_data/:not_supported/:watch/:confirmed）を
# 決定的に再現するための合成 FinancialStressRawDataset を単体で構築する。

const _FIH_FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "data", "financial_stress")

_fih_series(; key, dates, values) = FinancialStressSeries(;
    key = key, provider_series_id = uppercase(String(key)), name = "test", unit = "Percent",
    dates = dates, values = values,
)

_fih_ok(spec::FinancialStressSeriesSpec, series::FinancialStressSeries) =
    FinancialStressRawObservation(;
        key = spec.key, spec = spec, status = :ok, series = series,
        retrieved_at = nothing, mode = :fixture,
    )

_fih_missing(spec::FinancialStressSeriesSpec) = FinancialStressRawObservation(;
    key = spec.key, spec = spec, status = :missing_series, series = nothing,
    retrieved_at = nothing, mode = :fixture, detail = "test: no fixture",
)

"""
`shift_bps` を `:long_nominal_yield` に与え、他はすべて動かない合成dataset を作る
（`trigger_state` のみを制御する）。`weak_credit`/`funding` を動かしたい場合は
`weak_credit_shift_bps`/`funding_shift_bps` を指定する。
"""
function _fih_dataset(;
    nominal_shift_bps::Float64 = 0.0,
    weak_credit_shift_bps::Float64 = 0.0,
    funding_gap_bps::Float64 = 0.0,
    include_upper_tier::Bool = true,
    include_long_real_yield::Bool = true,
    include_inflation_compensation::Bool = true,
)
    dates = ["2026-01-01", "2026-01-02"]
    nominal = _fih_series(;
        key = :long_nominal_yield, dates = dates, values = [4.00, 4.00 + nominal_shift_bps / 100],
    )
    real = include_long_real_yield ?
           _fih_series(; key = :long_real_yield, dates = dates, values = [1.80, 1.80]) : nothing
    inflation_comp = include_inflation_compensation ?
                     _fih_series(; key = :inflation_compensation, dates = dates, values = [2.20, 2.20]) :
                     nothing
    # credit-tier: 30日物 A2/P2 − AA 非金融CP（fictional）。weak_credit_shift_bps だけ階層差が動く
    lower_tier = _fih_series(;
        key = :cp_a2p2_nonfinancial_30d, dates = dates,
        values = [4.40, 4.40 + weak_credit_shift_bps / 100],
    )
    upper_tier = include_upper_tier ?
                 _fih_series(; key = :cp_aa_nonfinancial_30d, dates = dates, values = [4.20, 4.20]) :
                 nothing
    # 平時のSOFR-IORB/TGCR-IORB乖離は数bp程度に収まる想定で基準値を選ぶ（fictional）。
    # funding_gap_bps=0.0 のとき :not_supported になることをテストが前提とするため。
    sofr = _fih_series(;
        key = :sofr, dates = dates, values = [4.16, 4.16 + funding_gap_bps / 100],
    )
    tgcr = _fih_series(; key = :tgcr, dates = dates, values = [4.16, 4.16])
    iorb = _fih_series(; key = :iorb, dates = dates, values = [4.15, 4.15])

    observations = Dict{Symbol, FinancialStressRawObservation}(
        :long_nominal_yield => _fih_ok(financial_stress_spec(:long_nominal_yield), nominal),
        :cp_a2p2_nonfinancial_30d =>
            _fih_ok(financial_stress_spec(:cp_a2p2_nonfinancial_30d), lower_tier),
        :sofr => _fih_ok(financial_stress_spec(:sofr), sofr),
        :tgcr => _fih_ok(financial_stress_spec(:tgcr), tgcr),
        :iorb => _fih_ok(financial_stress_spec(:iorb), iorb),
    )
    observations[:long_real_yield] = real === nothing ?
        _fih_missing(financial_stress_spec(:long_real_yield)) :
        _fih_ok(financial_stress_spec(:long_real_yield), real)
    observations[:inflation_compensation] = inflation_comp === nothing ?
        _fih_missing(financial_stress_spec(:inflation_compensation)) :
        _fih_ok(financial_stress_spec(:inflation_compensation), inflation_comp)
    observations[:cp_aa_nonfinancial_30d] = upper_tier === nothing ?
        _fih_missing(financial_stress_spec(:cp_aa_nonfinancial_30d)) :
        _fih_ok(financial_stress_spec(:cp_aa_nonfinancial_30d), upper_tier)

    return FinancialStressRawDataset(
        observations, FINANCIAL_STRESS_CATALOG_VERSION, "", Dict{String, Any}(),
    )
end

@testset "financial_instability_holdout（Issue #260 Part D）" begin
    @testset "smoke test（CLAUDE.md）" begin
        client = DataProviderClient(mode = :fixture, fixture_dir = _FIH_FIXTURE_DIR)
        raw = build_financial_stress_raw_dataset(; client = client)
        a = assess_financial_instability(raw, "2026-08-25", "2026-09-04")
        @test a isa FinancialInstabilityAssessment
        @test a.overall_status in FINANCIAL_INSTABILITY_STATUSES
        @test !isempty(a.caveats)
    end

    @testset "FinancialInstabilityThresholds: 既定値は明示的なnamed constant" begin
        t = FinancialInstabilityThresholds()
        @test t.trigger_watch_bps == 25.0
        @test t.trigger_confirmed_bps == 50.0
        @test t.version == FINANCIAL_INSTABILITY_RULE_VERSION
    end

    @testset "overall_status: trigger単独ではconfirmed/watchにならない" begin
        # trigger=confirmed（60bp）だが他は全て動かない -> not_supported
        d = _fih_dataset(; nominal_shift_bps = 60.0)
        a = assess_financial_instability(d, "2026-01-01", "2026-01-02")
        @test a.trigger_state.label == :confirmed
        @test a.overall_status == :not_supported
    end

    @testset "overall_status: trigger + 1dimensionでwatch" begin
        d = _fih_dataset(; nominal_shift_bps = 60.0, weak_credit_shift_bps = 40.0)
        a = assess_financial_instability(d, "2026-01-01", "2026-01-02")
        @test a.trigger_state.label == :confirmed
        @test a.weak_credit_state.label == :watch
        @test a.funding_state.label == :not_supported
        @test a.overall_status == :watch
        @test "weak_credit_state=watch" in a.overall_evidence
    end

    @testset "overall_status: trigger + 2dimensionでconfirmed" begin
        d = _fih_dataset(;
            nominal_shift_bps = 60.0, weak_credit_shift_bps = 40.0, funding_gap_bps = 15.0,
        )
        a = assess_financial_instability(d, "2026-01-01", "2026-01-02")
        @test a.trigger_state.label == :confirmed
        @test a.weak_credit_state.label == :watch
        @test a.funding_state.label == :watch
        @test a.overall_status == :confirmed
        @test length(a.overall_evidence) == 3
    end

    @testset "overall_status: triggerが動かなければ他が全部confirmed水準でもconfirmedにしない" begin
        d = _fih_dataset(;
            nominal_shift_bps = 0.0, weak_credit_shift_bps = 200.0, funding_gap_bps = 50.0,
        )
        a = assess_financial_instability(d, "2026-01-01", "2026-01-02")
        @test a.trigger_state.label == :not_supported
        @test a.weak_credit_state.label == :confirmed
        @test a.funding_state.label == :confirmed
        @test a.overall_status == :not_supported
    end

    @testset "insufficient_data: 全dimensionが欠測ならoverallもinsufficient_data" begin
        spec_n = financial_stress_spec(:long_nominal_yield)
        spec_c = financial_stress_spec(:cp_a2p2_nonfinancial_30d)
        spec_b = financial_stress_spec(:cp_aa_nonfinancial_30d)
        spec_s = financial_stress_spec(:sofr)
        spec_t = financial_stress_spec(:tgcr)
        spec_i = financial_stress_spec(:iorb)
        spec_r = financial_stress_spec(:long_real_yield)
        spec_ic = financial_stress_spec(:inflation_compensation)
        observations = Dict{Symbol, FinancialStressRawObservation}(
            :long_nominal_yield => _fih_missing(spec_n),
            :cp_a2p2_nonfinancial_30d => _fih_missing(spec_c),
            :cp_aa_nonfinancial_30d => _fih_missing(spec_b),
            :sofr => _fih_missing(spec_s),
            :tgcr => _fih_missing(spec_t),
            :iorb => _fih_missing(spec_i),
            :long_real_yield => _fih_missing(spec_r),
            :inflation_compensation => _fih_missing(spec_ic),
        )
        d = FinancialStressRawDataset(
            observations, FINANCIAL_STRESS_CATALOG_VERSION, "", Dict{String, Any}(),
        )
        # raw fetch自体の失敗（status != :ok）は例外を投げず :insufficient_data として
        # 吸収する（一部providerの不調でholdout全体を落とさない）。
        a = assess_financial_instability(d, "2026-01-01", "2026-01-02")
        @test a.trigger_state.label == :insufficient_data
        @test a.weak_credit_state.label == :insufficient_data
        @test a.funding_state.label == :insufficient_data
        @test a.overall_status == :insufficient_data
    end

    @testset "weak_credit_state: CP格付け階層差で判定し、入力のraw statusを残す（Issue #312）" begin
        @test FINANCIAL_INSTABILITY_HOLDOUT_VERSION == "financial-instability-holdout/2.0.0"
        @test FINANCIAL_INSTABILITY_RULE_VERSION == "financial-instability-rule/2.0.0"
        d = _fih_dataset(; weak_credit_shift_bps = 40.0)
        w = weak_credit_state(d, "2026-01-01", "2026-01-02")
        @test w.measure == WEAK_CREDIT_MEASURE == "cp_a2p2_minus_aa_nonfinancial_30d"
        @test w.divergence_shift_bps ≈ 40.0
        @test w.label == :watch
        @test w.lower_tier_rate_latest[1] == "2026-01-02"
        @test w.lower_tier_rate_latest[2] ≈ 4.80
        @test w.input_statuses == Dict(
            "cp_a2p2_nonfinancial_30d" => "ok", "cp_aa_nonfinancial_30d" => "ok",
        )
        dict = financial_instability_assessment_to_dict(
            assess_financial_instability(d, "2026-01-01", "2026-01-02"; generated_at = nothing),
        )
        wd = dict["weak_credit_state"]
        @test wd["measure"] == WEAK_CREDIT_MEASURE
        @test !haskey(wd, "ccc_oas_latest")
        @test wd["input_statuses"]["cp_aa_nonfinancial_30d"] == "ok"
        @test haskey(dict["trigger_state"], "input_statuses")
        @test haskey(dict["funding_state"], "input_statuses")
        @test any(c -> occursin("A2/P2", c), dict["caveats"])
    end

    @testset "EDPの提供停止（:distribution_stopped）は一時的な欠測と区別して残る（Issue #312）" begin
        d = _fih_dataset(; nominal_shift_bps = 60.0)
        spec = financial_stress_spec(:cp_aa_nonfinancial_30d)
        d.observations[:cp_aa_nonfinancial_30d] = FinancialStressRawObservation(;
            key = spec.key, spec = spec, status = :distribution_stopped, series = nothing,
            retrieved_at = nothing, mode = :rest_api,
            detail = "provider stopped distributing this series (HTTP 410 distribution_stopped)",
        )
        a = assess_financial_instability(d, "2026-01-01", "2026-01-02")
        @test a.weak_credit_state.label == :insufficient_data
        @test a.weak_credit_state.input_statuses["cp_aa_nonfinancial_30d"] == "distribution_stopped"
        @test a.weak_credit_state.input_statuses["cp_a2p2_nonfinancial_30d"] == "ok"
        # 他の dimension の判定を妨げない
        @test a.trigger_state.label == :confirmed

        # dataset に含まれない入力は not_requested（欠測・提供停止と混同しない）
        partial = build_financial_stress_raw_dataset(;
            client = DataProviderClient(mode = :fixture, fixture_dir = _FIH_FIXTURE_DIR),
            keys = [:sofr, :tgcr, :iorb],
        )
        w = weak_credit_state(partial, "2026-08-25", "2026-09-04")
        @test w.label == :insufficient_data
        @test w.input_statuses == Dict(
            "cp_a2p2_nonfinancial_30d" => "not_requested",
            "cp_aa_nonfinancial_30d" => "not_requested",
        )
    end

    @testset "insufficient_data: 日付が無い場合（取得は:okだが対象日を欠く）" begin
        d = _fih_dataset()
        a = assess_financial_instability(d, "2099-01-01", "2099-01-02")  # 存在しない日付
        @test a.trigger_state.label == :insufficient_data
        @test a.weak_credit_state.label == :insufficient_data
        @test a.funding_state.label in (:not_supported, :watch, :confirmed, :insufficient_data)
        @test a.overall_status in (:insufficient_data, :not_supported)
    end

    @testset "broad_conditions_state: 欠測とnot_supportedの区別" begin
        @test broad_conditions_state().label == :insufficient_data
        @test broad_conditions_state(; nfci_latest = ("2026-08", 0.1)).label == :not_supported
        @test broad_conditions_state(; sloos_latest = ("2026-Q2", 10.0)).label == :not_supported
    end

    @testset "value_on_date_spread: 整列結果に含まれない日付はmissing" begin
        spread = AlignedDailySpread(:a, :b, ["2026-01-01", "2026-01-02"], [10.0, 20.0], 2, 0, 0)
        @test value_on_date_spread(spread, "2026-01-01", "2026-01-02") == 10.0
        @test value_on_date_spread(spread, "2026-01-01", "2099-01-01") === missing
    end

    @testset "FINANCIAL_INSTABILITY_CAVEATS: 必須記載が含まれる" begin
        joined = join(FINANCIAL_INSTABILITY_CAVEATS, " ")
        @test occursin("危機確率", joined)
        @test occursin("投資判断", joined)
        @test occursin(":as_of", joined) || occursin("as_of", joined)
    end

    @testset "financial_instability_assessment_to_dict: 決定的でvolatileな時刻を除外する" begin
        d = _fih_dataset(; nominal_shift_bps = 60.0, weak_credit_shift_bps = 40.0)
        a1 = assess_financial_instability(
            d, "2026-01-01", "2026-01-02"; generated_at = DME.Dates.DateTime(2026, 1, 1),
        )
        a2 = assess_financial_instability(
            d, "2026-01-01", "2026-01-02"; generated_at = DME.Dates.DateTime(2099, 12, 31),
        )
        dict1 = financial_instability_assessment_to_dict(a1)
        dict2 = financial_instability_assessment_to_dict(a2)
        @test dict1["identity_hash"] == dict2["identity_hash"]  # generated_atはhash対象外
        @test dict1["as_of_generated"] != dict2["as_of_generated"]
        @test dict1["overall_status"] == "watch"
        @test startswith(dict1["identity_hash"], "sha256:")
    end

    @testset "save_financial_instability_assessment: ファイルへ書き出せる" begin
        d = _fih_dataset()
        a = assess_financial_instability(d, "2026-01-01", "2026-01-02")
        path = save_financial_instability_assessment(tempname() * ".json", a)
        @test isfile(path)
        @test filesize(path) > 0
        rm(path)
    end
end
