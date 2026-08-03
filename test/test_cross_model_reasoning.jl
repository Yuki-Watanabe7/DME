# クロスモデル推論層（#132 / ADR 0006）のテスト

using Test
using DME

@testset "クロスモデル推論（#132 / ADR 0006）" begin

    # ---- ModelConceptCoverage / mapping 導出（fixture）---------------------
    @testset "mapping 導出: equivalent / proxy / partial / incompatible" begin
        # 定義・単位・measure が一致 → equivalent
        a_eq = ModelConceptCoverage(;
            model = :ramsey,
            concept = :steady_state_stability,
            treatment = :endogenous,
            variables = ["K"],
            definition = "修正黄金律",
            definition_key = :mgr,
            unit = "level (real)",
            measure = "level",
        )
        b_eq = ModelConceptCoverage(;
            model = :rbc,
            concept = :steady_state_stability,
            treatment = :endogenous,
            variables = ["K"],
            definition = "修正黄金律",
            definition_key = :mgr,
            unit = "level (real)",
            measure = "level",
        )
        @test derive_concept_mapping(a_eq, b_eq).mapping_type === :equivalent

        # 両方 endogenous だが定義が異なる → proxy
        b_px = ModelConceptCoverage(;
            model = :solow,
            concept = :steady_state_stability,
            treatment = :endogenous,
            variables = ["k"],
            definition = "効率労働単位",
            definition_key = :eff_unit,
            unit = "efficiency-unit ratio",
            measure = "ratio",
        )
        @test derive_concept_mapping(a_eq, b_px).mapping_type === :proxy

        # 片方 approximate → partial
        b_pt = ModelConceptCoverage(;
            model = :islm,
            concept = :steady_state_stability,
            treatment = :approximate,
            variables = ["Y"],
            definition = "静学均衡",
            definition_key = :static,
            unit = "level",
            measure = "level",
        )
        @test derive_concept_mapping(a_eq, b_pt).mapping_type === :partial

        # 片方 out_of_scope → incompatible
        b_ic = ModelConceptCoverage(;
            model = :rbc,
            concept = :steady_state_stability,
            treatment = :out_of_scope,
            definition = "対象外",
            definition_key = :none,
        )
        mp = derive_concept_mapping(a_eq, b_ic)
        @test mp.mapping_type === :incompatible
        @test any(occursin("比較不能", c) for c in mp.caveats)

        # concept 不一致は ArgumentError
        wrong = ModelConceptCoverage(;
            model = :rbc,
            concept = :shock_response,
            treatment = :endogenous,
            definition = "x",
            definition_key = :y,
        )
        @test_throws ArgumentError derive_concept_mapping(a_eq, wrong)

        # 未知 concept / treatment は ArgumentError
        @test_throws ArgumentError ModelConceptCoverage(;
            model = :x,
            concept = :bogus,
            treatment = :endogenous,
            definition = "d",
            definition_key = :k,
        )
        @test_throws ArgumentError ModelConceptCoverage(;
            model = :x,
            concept = :shock_response,
            treatment = :bogus,
            definition = "d",
            definition_key = :k,
        )
    end

    # ---- 安全性: 同名変数でも定義が異なれば同一視しない ------------------
    @testset "安全性: 同名変数の定義差を equivalent としない" begin
        # RBC の r（実質資本限界生産物）と IS-LM の r（名目）— 定義差
        rbc_r = ModelConceptCoverage(;
            model = :rbc,
            concept = :shock_response,
            treatment = :endogenous,
            variables = ["r"],
            definition = "実質資本限界生産物",
            definition_key = :real_mpk,
            unit = "level (real)",
            measure = "level",
        )
        islm_r = ModelConceptCoverage(;
            model = :islm,
            concept = :shock_response,
            treatment = :endogenous,
            variables = ["r"],
            definition = "名目利子率",
            definition_key = :nominal_rate,
            unit = "level",
            measure = "level",
        )
        mp = derive_concept_mapping(rbc_r, islm_r)
        @test mp.mapping_type !== :equivalent
        @test any(occursin("定義が異なる", c) for c in mp.caveats)
    end

    # ---- registry は docs 由来メタデータのみ -----------------------------
    @testset "MODEL_CONCEPT_REGISTRY: docs 参照付き・数値なし" begin
        @test !isempty(MODEL_CONCEPT_REGISTRY)
        for c in MODEL_CONCEPT_REGISTRY
            @test c.concept in CROSS_MODEL_CONCEPTS
            @test c.treatment in CROSS_MODEL_TREATMENTS
            @test !isempty(c.doc_ref)          # repository metadata の根拠
        end
        # Keen と CCC（部門別CAPEX・信用循環モデル）だけが民間債務・信用を内生化
        debt = model_concept_coverage(; concept = :private_debt_credit)
        endog = [c.model for c in debt if c.treatment === :endogenous]
        @test Set(endog) == Set([:keen, :capex_credit_cycle])
    end

    # ---- context builder ------------------------------------------------
    @testset "build_cross_model_comparison_context: 基本" begin
        ctx = build_cross_model_comparison_context(; models = [:keen, :rbc, :islm])
        @test ctx.contract_version == CROSS_MODEL_CONTEXT_CONTRACT_VERSION
        @test length(ctx.models) == 3
        @test !isempty(ctx.mappings)
        # 各 mapping の source が registry に登録されている
        for m in ctx.mappings
            for sid in m.source_ids
                @test haskey(ctx.sources, sid)
            end
        end
        # 安全性 warning が付く
        codes = [w.code for w in ctx.warnings]
        @test "FIT_COMPARISON_RESTRICTED" in codes
        @test "DEFINITION_MISMATCH" in codes  # r 等の定義差

        # models < 2 は ArgumentError
        @test_throws ArgumentError build_cross_model_comparison_context(; models = [:keen])
        # 未知 concept は ArgumentError
        @test_throws ArgumentError build_cross_model_comparison_context(;
            models = [:keen, :rbc],
            concepts = [:bogus],
        )
    end

    # ---- 比較不能なケースで insufficient_comparability を返す --------------
    @testset "insufficient_comparability の明示" begin
        # 民間債務は Keen のみ内生、他は out_of_scope → 全 mapping incompatible
        ctx = build_cross_model_comparison_context(;
            models = [:keen, :rbc, :ramsey],
            concepts = [:private_debt_credit],
        )
        @test insufficient_comparability_concepts(ctx) == [:private_debt_credit]
        @test any(w.code == "INSUFFICIENT_COMPARABILITY" for w in ctx.warnings)

        out = explain_cross_model_comparison(ctx)
        @test out.incomparable_or_insufficient.status === :insufficient_comparability
        @test !isempty(out.incomparable_or_insufficient.claims)
        # 統合・平均・単一ランキングへ潰さない旨
        @test any(
            occursin("insufficient_comparability", c.text) || occursin("比較不能", c.text)
            for c in out.incomparable_or_insufficient.claims
        )

        # 全モデルが同扱いの概念（比較可能あり）では section が insufficient にならない
        ctx2 = build_cross_model_comparison_context(;
            models = [:ramsey, :rbc],
            concepts = [:steady_state_stability],
        )
        @test isempty(insufficient_comparability_concepts(ctx2))
    end

    # ---- 決定的出力: 全必須 section と表示順 ------------------------------
    @testset "決定的出力: 必須 section・source 解決" begin
        ctx = build_cross_model_comparison_context(;
            models = [:keen, :rbc, :new_keynesian, :islm],
        )
        out = explain_cross_model_comparison(ctx)
        @test out.generation_status === :deterministic
        @test out.contract_version == CROSS_MODEL_OUTPUT_CONTRACT_VERSION
        for key in CROSS_MODEL_OUTPUT_SECTION_ORDER
            sec = DME._xm_section(out, key)
            @test sec.status in DME.CROSS_MODEL_SECTION_STATUSES
        end
        # 概念対応が明示される（受け入れ条件）
        @test out.concept_mappings.status === :available
        @test !isempty(out.concept_mappings.claims)
        @test all(c.epistemic_status === :mapping for c in out.concept_mappings.claims)

        # 全 claim の source_ids は registry に存在（1 件以上）
        for key in CROSS_MODEL_OUTPUT_SECTION_ORDER
            for cl in DME._xm_section(out, key).claims
                @test !isempty(cl.source_ids)
                for sid in cl.source_ids
                    @test haskey(ctx.sources, sid)
                end
            end
        end
        # source_references は重複なし
        ref_ids = [s.id for s in out.source_references]
        @test length(ref_ids) == length(unique(ref_ids))
        @test occursin("投資判断", out.disclaimer)
    end

    # ---- 同一データに対するモデル別説明が混線しない ----------------------
    @testset "モデル別説明の非混線" begin
        ctx = build_cross_model_comparison_context(; models = [:keen, :rbc, :solow])
        out = explain_cross_model_comparison(ctx)
        # mechanisms_by_model: 各 claim は 1 モデルの coverage source のみ参照
        for cl in out.mechanisms_by_model.claims
            models_referenced = Set{String}()
            for sid in cl.source_ids
                # sid = "concept.<model>.<concept>"
                parts = split(sid, ".")
                @test length(parts) >= 3
                push!(models_referenced, parts[2])
            end
            @test length(models_referenced) == 1  # 1 claim = 1 モデル
        end
        # metadata claim は model_concept source のみ（category 整合）
        for cl in out.mechanisms_by_model.claims
            @test cl.epistemic_status === :metadata
            for sid in cl.source_ids
                @test ctx.sources[sid].category === :model_concept
            end
        end
    end

    # ---- 相違点と原因（仮定）--------------------------------------------
    @testset "divergent_conclusions: 原因となる仮定を明示" begin
        ctx = build_cross_model_comparison_context(;
            models = [:keen, :rbc],
            concepts = [:demand_and_instability],
        )
        out = explain_cross_model_comparison(ctx)
        @test out.divergent_conclusions.status === :available
        @test any(
            occursin("仮定", c.text) || occursin("市場清算", c.text) for
            c in out.divergent_conclusions.claims
        )
    end

    # ---- parser roundtrip / provider fallback ---------------------------
    @testset "parser 検証と provider fallback" begin
        ctx = build_cross_model_comparison_context(; models = [:keen, :rbc, :islm])
        det = explain_cross_model_comparison(ctx)
        j = to_json(det)
        # 決定的出力の JSON は出力スキーマなので parser を通過し :parsed
        reparsed = parse_cross_model_response(j, ctx)
        @test reparsed !== nothing
        @test reparsed.generation_status === :parsed
        # 壊れた JSON → nothing
        @test parse_cross_model_response("{not json", ctx) === nothing
        # contract_version 不一致 → nothing
        @test parse_cross_model_response("{\"contract_version\":\"x\"}", ctx) === nothing

        # provider が正しい JSON → :parsed
        outp = explain_cross_model_comparison(ctx; provider = MockLLMProvider(j))
        @test outp.generation_status === :parsed
        # provider が不正応答 → :fallback（parser failure warning 付き）
        outf = explain_cross_model_comparison(ctx; provider = MockLLMProvider("garbage"))
        @test outf.generation_status === :fallback
        @test any(w.code == "OUTPUT_SCHEMA_INVALID" for w in outf.warnings)
    end

    # ---- 未登録 source_id / status 不整合を parser が拒否 -----------------
    @testset "parser: 未登録 source・category 不整合の拒否" begin
        ctx = build_cross_model_comparison_context(; models = [:keen, :rbc, :islm])
        det = explain_cross_model_comparison(ctx)
        d = to_dict(det)
        # 未登録 source_id を注入
        d2 = deepcopy(d)
        d2["mechanisms_by_model"]["claims"][1]["source_ids"] = ["concept.unknown.bogus"]
        @test parse_cross_model_response(DME.JSON3.write(d2), ctx) === nothing
        # metadata claim に concept_mapping source を与えて category 不整合
        d3 = deepcopy(d)
        # concept_mapping category の source id を 1 つ取得
        mapping_id = first(id for (id, s) in ctx.sources if s.category === :concept_mapping)
        d3["mechanisms_by_model"]["claims"][1]["source_ids"] = [mapping_id]
        @test parse_cross_model_response(DME.JSON3.write(d3), ctx) === nothing
    end

    # ---- 実証結果ありの経路（Keen 実証層）-------------------------------
    @testset "empirical_support: Keen 実証 context あり" begin
        lit = KEEN_LITERATURE_PARAMS
        m = KeenModel(
            lit.α,
            lit.β,
            lit.δ,
            lit.ν,
            lit.r,
            0.05,
            8.0e-5,
            -0.005,
            0.007,
            lit.κ2,
        )
        ss = DME.steady_state(m)
        n = 40
        ω, λ, d = ss.ω * 0.99, ss.λ * 0.999, ss.d * 1.01
        ωs, λs, ds = Float64[], Float64[], Float64[]
        for _ in 1:n
            push!(ωs, ω)
            push!(λs, λ)
            push!(ds, d)
            ω, λ, d = DME.keen_rk4_step(m, ω, λ, d, 0.25)
        end
        ql = ["$(2000 + (i - 1) ÷ 4)-Q$(((i - 1) % 4) + 1)" for i in 1:n]
        mk(id, unit, vals) = DataSeries(
            id = id,
            name = id,
            source = "TEST",
            frequency = Quarterly,
            unit = unit,
            dates = ql,
            values = convert(Vector{Union{Float64, Missing}}, vals),
        )
        macro_ds = MacroDataset(
            "syn",
            DataSeries[
                mk("OMEGA", "Percent", ωs .* 100),
                mk("LAMBDA", "Percent", (1 .- λs) .* 100),
                mk("DEBT", "Percent of GDP", ds .* 100),
                mk("RATE", "Percent", fill(m.r * 100, n)),
            ],
        )
        cfg = KeenEmpiricalDataConfig(;
            country = "TEST",
            omega = KeenSeriesSpec(;
                variable = :ω,
                source_id = "OMEGA",
                conversion = :ratio_from_percent,
                domain_lo = 0.0,
                domain_hi = 1.0,
                forbid_index = true,
            ),
            lambda = KeenSeriesSpec(;
                variable = :λ,
                source_id = "LAMBDA",
                conversion = :employment_from_unrate,
                domain_lo = 0.0,
                domain_hi = 1.0,
            ),
            debt = KeenSeriesSpec(;
                variable = :d,
                source_id = "DEBT",
                conversion = :ratio_from_percent,
                domain_lo = 0.0,
                domain_hi = 100.0,
            ),
            rate = KeenSeriesSpec(;
                variable = :r,
                source_id = "RATE",
                conversion = :ratio_from_percent,
                domain_lo = 0.0,
                domain_hi = 1.0,
            ),
            min_valid_obs = 8,
            validation_split = 0.3,
            r_mode = :sample_mean,
        )
        ds_e = build_keen_empirical_dataset(cfg, macro_ds)
        vres = validate_keen(ds_e, keen_default_validation_config(ds_e))
        kctx = KeenEmpiricalContext(ds_e, vres; mode = :fixture)

        ctx = build_cross_model_comparison_context(;
            models = [:keen, :rbc, :islm],
            empirical = kctx,
        )
        @test ctx.empirical !== nothing
        @test any(w.code == "EMPIRICAL_ONLY_FOR_KEEN" for w in ctx.warnings)

        out = explain_cross_model_comparison(ctx)
        @test out.empirical_support.status === :available
        @test !isempty(out.empirical_support.claims)
        # empirical claim は empirical_evidence source のみ参照
        for cl in out.empirical_support.claims
            if cl.epistemic_status === :empirical
                for sid in cl.source_ids
                    @test ctx.sources[sid].category === :empirical_evidence
                end
            end
        end
        # 安全性: fit 単純比較の制限と「失敗≠証明」の qualifier
        allq = vcat([c.qualifiers for c in out.empirical_support.claims]...)
        @test any(occursin("一致する場合に限", q) for q in allq)
        @test any(occursin("正しさの証明", q) for q in allq)
        # 相対的支持/反証は非当てはめモデルの反証にしない
        @test any(
            occursin("反証にも肯定にもならない", c.text) for
            c in out.empirical_support.claims
        )
    end

    # ---- 限界 section に安全性ルールが明記される ------------------------
    @testset "limitations: 安全性ルールの明記" begin
        ctx = build_cross_model_comparison_context(; models = [:keen, :rbc])
        out = explain_cross_model_comparison(ctx)
        @test out.limitations.status === :available
        txt = join([c.text for c in out.limitations.claims], " ")
        @test occursin("同名変数", txt)
        @test occursin("正しさの証明", txt)
        @test occursin("repository metadata", txt)
    end

    # ---- prompt に禁止解釈・source 要求が含まれる -----------------------
    @testset "build_cross_model_prompt: 安全性制約" begin
        ctx = build_cross_model_comparison_context(; models = [:keen, :rbc])
        prompt = build_cross_model_prompt(ctx)
        @test occursin("同名変数", prompt)
        @test occursin("repository metadata", prompt)
        @test occursin("source registry に存在", prompt)
        @test occursin("insufficient_comparability", prompt)
        @test occursin("投資", prompt)  # 免責
    end

    # ---- to_dict / to_json のラウンドトリップ ----------------------------
    @testset "to_dict / to_json" begin
        ctx = build_cross_model_comparison_context(; models = [:keen, :rbc, :islm])
        cd = to_dict(ctx)
        @test cd["contract_version"] == CROSS_MODEL_CONTEXT_CONTRACT_VERSION
        @test haskey(cd, "coverage") && haskey(cd, "mappings") && haskey(cd, "sources")
        @test to_json(ctx) isa String

        out = explain_cross_model_comparison(ctx)
        od = to_dict(out)
        for key in CROSS_MODEL_OUTPUT_SECTION_ORDER
            @test haskey(od, key)
        end
        @test to_json(out) isa String
    end
end
