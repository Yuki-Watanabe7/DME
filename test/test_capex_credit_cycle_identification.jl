# CCC 実証識別層の契約テスト（Issue #245 / P-5）。
# 受け入れ条件は docs/architecture/capex_credit_cycle_empirical_integration.md §12.5
# （項目 39–42・44–46）と Issue #245 本文の受け入れ条件。

using DME:
    build_capex_empirical_dataset,
    calibrate_capex_credit_cycle,
    diagnose_capex_identification,
    validate_capex_estimation_blocks,
    capex_estimation_block,
    capex_identification_to_dict,
    save_capex_identification,
    capex_parameter_class,
    CapexEstimationBlockSpec,
    CapexIdentificationDiagnostic,
    CapexIdentificationConfig,
    CAPEX_CC_ESTIMATION_BLOCKS,
    CAPEX_CC_IDENTIFICATION_STATUSES,
    CAPEX_CC_WEAK_ID_ACTIONS,
    CAPEX_CC_IDENTIFICATION_RISKS,
    CAPEX_CC_IDENTIFICATION_VERSION,
    CAPEX_CC_PARAMETER_NAMES,
    CAPEX_CC_PARAMETER_DICT_PLACEHOLDERS,
    CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
    CapexSeriesSpec,
    CapexRawObservation,
    CapexRawDataset,
    DataSeries,
    Quarterly

# ---------------------------------------------------------------------------
# fixture ヘルパ
# ---------------------------------------------------------------------------

function _idq_dates(start_label::String, n::Int)
    y0, q0 =
        parse(Int, split(start_label, "-Q")[1]), parse(Int, split(start_label, "-Q")[2])
    base = y0 * 4 + (q0 - 1)
    return [string(idx ÷ 4, "-Q", idx % 4 + 1) for idx in base:(base + n - 1)]
end

function _id_spec(
    key::Symbol;
    role::Symbol = :calibration_required,
    observability::Symbol = :D,
    methodology::Symbol = :direct,
    model_vars::Vector{Symbol} = [key],
    allocation_key::Union{Symbol, Nothing} = nothing,
)
    scope_bias = methodology === :proxy ? :over : :none
    ak =
        methodology === :allocation ? something(allocation_key, :sector_sales_share) :
        allocation_key
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
        allocation_key = ak,
        availability_start = "2000-Q1",
        notes = "identification fixture entry",
    )
end

function _id_obs(spec::CapexSeriesSpec, series::DataSeries)
    return CapexRawObservation(
        spec.key,
        spec,
        :ok,
        series,
        "unit",
        Quarterly,
        "SA",
        missing,
        String[],
        nothing,
        :fixture,
        "",
    )
end

function _id_series(key::Symbol, values::Vector{Float64}, dates::Vector{String})
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

# entries: key => (values::Vector{Float64}, kwargs::NamedTuple for _id_spec)
function _id_dataset(entries::Vector; start::String = "2013-Q1")
    n = maximum(length(v[1]) for v in (e[2] for e in entries))
    dates = _idq_dates(start, n)
    obs = CapexRawObservation[]
    for (k, payload) in entries
        vals, kw = payload
        length(vals) == n || error("fixture 系列 $k の長さが不揃いです")
        spec = _id_spec(k; kw...)
        push!(obs, _id_obs(spec, _id_series(k, vals, dates)))
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

# 決定論的で相互相関の小さい系列（線形トレンド + 位相をずらした正弦）
function _wiggly(
    n::Int;
    amp::Float64 = 1.0,
    base::Float64 = 100.0,
    phase::Float64 = 0.0,
    slope::Float64 = 0.3,
)
    return Float64[base + slope * t + amp * sinpi((t + phase) / 3.7) for t in 1:n]
end

# EB-3 の必須 6 系列がすべて direct・十分な変動・低相関で揃った 16 四半期 dataset
function _eb3_ok_dataset(; n::Int = 16)
    return _id_dataset([
        :inv_s2 => (_wiggly(n; amp = 4.0, base = 60.0, phase = 0.0), (;)),
        :inv_s3 => (_wiggly(n; amp = 3.0, base = 55.0, phase = 1.3), (;)),
        :ship_s2 => (_wiggly(n; amp = 5.0, base = 120.0, phase = 2.1, slope = 0.5), (;)),
        :ship_s3 => (_wiggly(n; amp = 6.0, base = 110.0, phase = 3.0, slope = 0.4), (;)),
        :order_s2 => (_wiggly(n; amp = 7.0, base = 125.0, phase = 0.7, slope = 0.6), (;)),
        :backlog_s2 => (_wiggly(n; amp = 8.0, base = 200.0, phase = 1.9, slope = 0.2), (;)),
    ])
end

@testset "CCC 実証識別層（Issue #245 / P-5）" begin
    # -----------------------------------------------------------------------
    # §12.5-39: ブロックが 7 件・EST 総数 35
    # -----------------------------------------------------------------------
    @testset "§12.5-39 ブロック 7 件・EST 総数 35・正典 1:1" begin
        @test length(CAPEX_CC_ESTIMATION_BLOCKS) == 7
        @test sum(length(b.est_params) for b in CAPEX_CC_ESTIMATION_BLOCKS) == 35
        @test validate_capex_estimation_blocks() === nothing

        by_id = Dict(b.id => b for b in CAPEX_CC_ESTIMATION_BLOCKS)
        @test Set(keys(by_id)) == Set((:EB1, :EB2, :EB3, :EB4, :EB5, :EB6, :EB7))
        # 固定推定順序（#170 §7.4-2）
        @test [by_id[i].order for i in (:EB1, :EB3, :EB4, :EB6, :EB7, :EB5, :EB2)] == 1:7
        # ブロック別 EST 個数（実証統合設計 §8.4）
        @test length(by_id[:EB1].est_params) == 4
        @test length(by_id[:EB2].est_params) == 3
        @test length(by_id[:EB3].est_params) == 4
        @test length(by_id[:EB4].est_params) == 4
        @test length(by_id[:EB5].est_params) == 9
        @test length(by_id[:EB6].est_params) == 9
        @test length(by_id[:EB7].est_params) == 2
        # 式 ID・識別リスク・W action が取得できる（#245 受け入れ条件）
        @test by_id[:EB1].equation_ids == ["E5-01", "E5-04", "E5-06"]
        @test by_id[:EB3].identification_risks == [:ID4]
        @test by_id[:EB1].preassigned_actions[:bh_spread_cov] == :W2
        @test by_id[:EB5].preassigned_actions[:bh_alpha_capex_s1] == :W3
        @test by_id[:EB5].preassigned_actions[:bh_cc_elas_s1] == :W2
        @test capex_estimation_block(:EB7).est_params == [:bh_mpc, :bh_cons_adj]
        @test_throws ArgumentError capex_estimation_block(:EB9)
    end

    # -----------------------------------------------------------------------
    # §12.5-40: bh_emp_*_s4 がどのブロックにも現れない
    # -----------------------------------------------------------------------
    @testset "§12.5-40 辞書上の空き値がブロックに現れない" begin
        all_block_params = Symbol[]
        for b in CAPEX_CC_ESTIMATION_BLOCKS
            append!(all_block_params, b.est_params)
            append!(all_block_params, b.fixed_params)
        end
        for p in CAPEX_CC_PARAMETER_DICT_PLACEHOLDERS
            @test !(p in all_block_params)
        end
        @test :bh_emp_up_s4 in CAPEX_CC_PARAMETER_DICT_PLACEHOLDERS
        # s5 は空き値ではないので EB-6 に含まれる
        @test :bh_emp_up_s5 in capex_estimation_block(:EB6).est_params
    end

    # -----------------------------------------------------------------------
    # §12.5-46: FIX/CAL-SS/CAL-OBS/SCN/SENS を est_params に入れると拒否
    # -----------------------------------------------------------------------
    @testset "§12.5-46 非 EST を est_params に入れると拒否" begin
        eb3 = capex_estimation_block(:EB3)
        # CAL-OBS を混入
        bad = CapexEstimationBlockSpec(
            eb3.id,
            eb3.order,
            vcat(eb3.est_params, [:bh_util_max_s2]),   # CAL-OBS
            eb3.fixed_params,
            eb3.required_keys,
            eb3.supporting_keys,
            eb3.equation_ids,
            eb3.identification_risks,
            eb3.preassigned_actions,
        )
        blocks = [b.id === :EB3 ? bad : b for b in CAPEX_CC_ESTIMATION_BLOCKS]
        @test_throws ArgumentError validate_capex_estimation_blocks(blocks)

        # 辞書上の空き値を混入
        bad2 = CapexEstimationBlockSpec(
            eb3.id,
            eb3.order,
            vcat(eb3.est_params, [:bh_emp_up_s4]),
            eb3.fixed_params,
            eb3.required_keys,
            eb3.supporting_keys,
            eb3.equation_ids,
            eb3.identification_risks,
            eb3.preassigned_actions,
        )
        blocks2 = [b.id === :EB3 ? bad2 : b for b in CAPEX_CC_ESTIMATION_BLOCKS]
        @test_throws ArgumentError validate_capex_estimation_blocks(blocks2)

        # EST 総数がずれる
        eb7 = capex_estimation_block(:EB7)
        short7 = CapexEstimationBlockSpec(
            eb7.id,
            eb7.order,
            [:bh_mpc],
            eb7.fixed_params,
            eb7.required_keys,
            eb7.supporting_keys,
            eb7.equation_ids,
            eb7.identification_risks,
            eb7.preassigned_actions,
        )
        blocks3 = [b.id === :EB7 ? short7 : b for b in CAPEX_CC_ESTIMATION_BLOCKS]
        @test_throws ArgumentError validate_capex_estimation_blocks(blocks3)
    end

    # -----------------------------------------------------------------------
    # estimable path（EB-3。会計恒等式で最も識別が良いブロック）
    # -----------------------------------------------------------------------
    @testset "estimable: EB-3 は direct 観測が揃えば推定可能" begin
        ds = _eb3_ok_dataset()
        diags = diagnose_capex_identification(ds)
        @test diags isa Vector{CapexIdentificationDiagnostic}
        @test length(diags) == 7
        # 固定推定順序で返る
        @test [d.block for d in diags] == [:EB1, :EB3, :EB4, :EB6, :EB7, :EB5, :EB2]
        eb3 = diags[2]
        @test eb3.block == :EB3
        @test eb3.status == :estimable
        @test eb3.status in CAPEX_CC_IDENTIFICATION_STATUSES
        @test isempty(eb3.missing_keys)
        @test isempty(eb3.proxy_only_keys)
        @test isempty(eb3.applied_actions)
        @test isempty(eb3.armed_actions)
        @test Set(eb3.effective_est_params) == Set(eb3.est_params)
        @test eb3.n_obs == 16
    end

    # -----------------------------------------------------------------------
    # weakly_identified: EB-1 は bh_spread_cov のみ W2 armed（他は点推定可）
    # -----------------------------------------------------------------------
    @testset "weakly_identified: EB-1 は事前固定 W2 が発火待ちになる" begin
        n = 16
        ds = _id_dataset([
            :fin_cond =>
                (_wiggly(n; amp = 0.5, base = 0.0, phase = 0.0, slope = 0.0), (;)),
            :spread =>
                (_wiggly(n; amp = 30.0, base = 250.0, phase = 1.1, slope = 0.0), (;)),
            :lend_stance =>
                (_wiggly(n; amp = 0.4, base = 0.0, phase = 2.3, slope = 0.0), (;)),
            :policy_rate =>
                (_wiggly(n; amp = 0.6, base = 2.0, phase = 3.1, slope = 0.05), (;)),
        ])
        diags = diagnose_capex_identification(ds)
        eb1 = first(d for d in diags if d.block === :EB1)
        @test eb1.status == :weakly_identified
        @test eb1.armed_actions[:bh_spread_cov] == :W2
        # 金融系列のみで推定できる 3 本は armed されない
        @test !haskey(eb1.armed_actions, :bh_fc_pol)
        @test !haskey(eb1.armed_actions, :bh_spread_fc)
        @test !haskey(eb1.armed_actions, :bh_lend_spread)
        @test isempty(eb1.applied_actions)
    end

    # -----------------------------------------------------------------------
    # §12.5-42: proxy / allocation のみのキーは direct と別扱い → weakly_identified
    # -----------------------------------------------------------------------
    @testset "§12.5-42 proxy/allocation のみのキーは direct と区別される" begin
        n = 16
        ds = _id_dataset([
            :price_s2 =>
                (_wiggly(n; amp = 0.05, base = 1.0, phase = 0.2, slope = 0.0), (;)),
            :price_s3 =>
                (_wiggly(n; amp = 0.04, base = 1.0, phase = 1.7, slope = 0.0), (;)),
            # util は proxy 観測（catalog observability = :P）
            :util_s2 => (
                _wiggly(n; amp = 0.06, base = 0.8, phase = 0.9),
                (observability = :P, methodology = :proxy),
            ),
            :util_s3 => (
                _wiggly(n; amp = 0.05, base = 0.78, phase = 2.6),
                (observability = :P, methodology = :proxy),
            ),
        ])
        diags = diagnose_capex_identification(ds)
        eb4 = first(d for d in diags if d.block === :EB4)
        @test eb4.status == :weakly_identified
        @test Set(eb4.proxy_only_keys) == Set([:util_s2, :util_s3])
        @test !(:price_s2 in eb4.proxy_only_keys)
        # proxy 依存が理由 → 事前固定の無い候補にも W2 が armed される（#170 §8.3 W2）
        for p in eb4.est_params
            @test eb4.armed_actions[p] == :W2
        end
        @test any(r -> occursin("proxy_or_allocation_only", r), eb4.reasons)
    end

    # -----------------------------------------------------------------------
    # §12.5-41: 必須系列欠損・短標本・変動不足・近似特異が別 status
    # -----------------------------------------------------------------------
    @testset "§12.5-41 missing required series → :insufficient_data" begin
        n = 16
        entries = [
            :inv_s3 => (_wiggly(n; amp = 3.0, base = 55.0), (;)),
            :ship_s2 => (_wiggly(n; amp = 5.0, base = 120.0, phase = 2.1), (;)),
            :ship_s3 => (_wiggly(n; amp = 6.0, base = 110.0, phase = 3.0), (;)),
            :order_s2 => (_wiggly(n; amp = 7.0, base = 125.0, phase = 0.7), (;)),
            :backlog_s2 => (_wiggly(n; amp = 8.0, base = 200.0, phase = 1.9), (;)),
        ]  # :inv_s2 を欠く
        diags = diagnose_capex_identification(_id_dataset(entries))
        eb3 = first(d for d in diags if d.block === :EB3)
        @test eb3.status == :insufficient_data
        @test :inv_s2 in eb3.missing_keys
        @test any(r -> occursin("missing_required_series", r), eb3.reasons)
        # W4 事前適用: 候補が est_params から外れる（§12.5-44）
        for p in eb3.est_params
            @test eb3.applied_actions[p] == :W4
        end
        @test isempty(eb3.effective_est_params)
    end

    @testset "§12.5-41 short sample → :insufficient_data（missing と別 reason）" begin
        ds = _eb3_ok_dataset(; n = 10)   # min_obs 既定 12 未満
        diags = diagnose_capex_identification(ds)
        eb3 = first(d for d in diags if d.block === :EB3)
        @test eb3.status == :insufficient_data
        @test eb3.n_obs == 10
        @test isempty(eb3.missing_keys)
        @test any(r -> occursin("short_sample", r), eb3.reasons)
        @test !any(r -> occursin("missing_required_series", r), eb3.reasons)
    end

    @testset "§12.5-41 変動不足 → :not_identified" begin
        n = 16
        entries = [
            :inv_s2 => (_wiggly(n; amp = 4.0, base = 60.0), (;)),
            :inv_s3 => (_wiggly(n; amp = 3.0, base = 55.0, phase = 1.3), (;)),
            :ship_s2 => (_wiggly(n; amp = 5.0, base = 120.0, phase = 2.1), (;)),
            :ship_s3 => (_wiggly(n; amp = 6.0, base = 110.0, phase = 3.0), (;)),
            :order_s2 => (fill(125.0, n), (;)),   # 定数系列
            :backlog_s2 => (_wiggly(n; amp = 8.0, base = 200.0, phase = 1.9), (;)),
        ]
        diags = diagnose_capex_identification(_id_dataset(entries))
        eb3 = first(d for d in diags if d.block === :EB3)
        @test eb3.status == :not_identified
        @test any(r -> occursin("no_variation", r), eb3.reasons)
        @test eb3.variation[:order_s2] == 0.0
        @test eb3.variation[:inv_s2] > 0.0
    end

    @testset "§12.5-41 近似特異 → :weakly_identified" begin
        n = 16
        base_ship = _wiggly(n; amp = 5.0, base = 120.0, phase = 2.1)
        entries = [
            :inv_s2 => (_wiggly(n; amp = 4.0, base = 60.0), (;)),
            :inv_s3 => (_wiggly(n; amp = 3.0, base = 55.0, phase = 1.3), (;)),
            :ship_s2 => (base_ship, (;)),
            :ship_s3 => (2.0 .* base_ship .+ 5.0, (;)),   # ship_s2 の線形変換 → |r|=1
            :order_s2 => (_wiggly(n; amp = 7.0, base = 125.0, phase = 0.7), (;)),
            :backlog_s2 => (_wiggly(n; amp = 8.0, base = 200.0, phase = 1.9), (;)),
        ]
        diags = diagnose_capex_identification(_id_dataset(entries))
        eb3 = first(d for d in diags if d.block === :EB3)
        @test eb3.status == :weakly_identified
        @test any(r -> occursin("near_singular", r), eb3.reasons)
        @test eb3.collinearity[(:ship_s2, :ship_s3)] > 0.995
        for p in eb3.est_params
            @test eb3.armed_actions[p] == :W2
        end
    end

    # -----------------------------------------------------------------------
    # not_identified: 候補がすべて W1 事前適用（構造的に識別できない）
    # -----------------------------------------------------------------------
    @testset "not_identified: 全候補が W1 事前適用のブロック" begin
        n = 16
        eb2 = capex_estimation_block(:EB2)
        all_w1 = CapexEstimationBlockSpec(
            eb2.id,
            eb2.order,
            eb2.est_params,
            eb2.fixed_params,
            eb2.required_keys,
            eb2.supporting_keys,
            eb2.equation_ids,
            eb2.identification_risks,
            Dict(p => :W1 for p in eb2.est_params),
        )
        ds = _id_dataset([
            :spread => (_wiggly(n; amp = 30.0, base = 250.0), (;)),
            :equity_val => (_wiggly(n; amp = 0.1, base = 1.0, phase = 1.4), (;)),
            :policy_rate => (_wiggly(n; amp = 0.6, base = 2.0, phase = 3.1), (;)),
        ])
        diags = diagnose_capex_identification(ds; blocks = [all_w1])
        @test length(diags) == 1
        @test diags[1].status == :not_identified
        @test isempty(diags[1].effective_est_params)
        for p in eb2.est_params
            @test diags[1].applied_actions[p] == :W1
        end
    end

    # -----------------------------------------------------------------------
    # EB-2（正典どおり）: bh_cc_* は W1 で est_params になく、残り 3 本は W2 armed
    # -----------------------------------------------------------------------
    @testset "§12.5-44 EB-2 の bh_cc_* は W1 で est_params から外れている" begin
        eb2 = capex_estimation_block(:EB2)
        for p in (:bh_cc_lend, :bh_cc_equity, :bh_cc_fc)
            @test !(p in eb2.est_params)
            @test p in eb2.fixed_params
            @test eb2.preassigned_actions[p] == :W1
        end
        n = 16
        ds = _id_dataset([
            :spread => (_wiggly(n; amp = 30.0, base = 250.0), (;)),
            :equity_val => (_wiggly(n; amp = 0.1, base = 1.0, phase = 1.4), (;)),
            :policy_rate => (_wiggly(n; amp = 0.6, base = 2.0, phase = 3.1), (;)),
        ])
        d2 = first(d for d in diagnose_capex_identification(ds) if d.block === :EB2)
        @test d2.status == :weakly_identified
        for p in (:bh_ev_elas, :bh_coll_elas, :bh_roll_slope)
            @test d2.armed_actions[p] == :W2
        end
    end

    # -----------------------------------------------------------------------
    # 決定性・artifact serialization（#245 受け入れ条件）
    # -----------------------------------------------------------------------
    @testset "決定性: 同一 dataset/spec から同一 diagnostic" begin
        ds1 = _eb3_ok_dataset()
        ds2 = _eb3_ok_dataset()
        d1 = capex_identification_to_dict(diagnose_capex_identification(ds1))
        d2 = capex_identification_to_dict(diagnose_capex_identification(ds2))
        @test d1["identification_hash"] == d2["identification_hash"]
        @test d1["est_total"] == 35
        @test d1["identification_version"] == CAPEX_CC_IDENTIFICATION_VERSION

        # config を変えると hash が変わる
        d3 = capex_identification_to_dict(
            diagnose_capex_identification(
                ds1;
                config = CapexIdentificationConfig(; min_obs = 20),
            );
            config = CapexIdentificationConfig(; min_obs = 20),
        )
        @test d3["identification_hash"] != d1["identification_hash"]

        mktempdir() do dir
            path = save_capex_identification(
                joinpath(dir, "id.json"),
                diagnose_capex_identification(ds1),
            )
            @test isfile(path)
            g = DME.JSON3.read(read(path, String))
            @test g["est_total"] == 35
            @test haskey(g, "block_specs")
            @test length(g["diagnostics"]) == 7
        end
    end

    @testset "推定順に依存せず同一結果（観測順のシャッフル耐性）" begin
        ds = _eb3_ok_dataset()
        a = diagnose_capex_identification(ds)
        b = diagnose_capex_identification(ds; blocks = reverse(CAPEX_CC_ESTIMATION_BLOCKS))
        @test [x.block for x in a] == [x.block for x in b]
        @test [x.status for x in a] == [x.status for x in b]
    end

    # -----------------------------------------------------------------------
    # 較正結果との突き合わせ（cal を渡す経路）
    # -----------------------------------------------------------------------
    @testset "cal を渡すと 6 区分の二重防御が働き、hash を連結できる" begin
        # calibration テストの roundtrip fixture を最小構成で再現
        b = DME.capex_credit_cycle_default_targets().values
        vals = Dict{Symbol, Float64}(
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
            :wagebill_tot =>
                b.wagebill_s5 + b.wagebill_s1 + b.wagebill_s2 + b.wagebill_s3,
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
        entries = [k => (fill(v, 12), (;)) for (k, v) in vals]
        ds = _id_dataset(entries)
        cal = calibrate_capex_credit_cycle(
            ds;
            baseline_start = "2014-Q1",
            baseline_end = "2015-Q4",
            literature = (
                cost_capital_intercept_s1 = b.cost_capital_s1 - b.spread / 100,
                cost_capital_intercept_s2 = b.cost_capital_s2 - b.spread / 100,
                cost_capital_intercept_s3 = b.cost_capital_s3 - b.spread / 100,
            ),
            assumptions = (cons_s1 = b.cons_s1,),
        )
        diags = diagnose_capex_identification(ds, cal)
        @test length(diags) == 7
        d = capex_identification_to_dict(
            diags;
            dataset_hash = cal.dataset_hash,
            targets_hash = cal.targets_hash,
        )
        @test d["dataset_hash"] == cal.dataset_hash
        @test d["targets_hash"] == cal.targets_hash
        @test startswith(d["identification_hash"], "sha256:")
    end
end
