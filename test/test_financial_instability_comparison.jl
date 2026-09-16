# pre/post-FOMC financial-instability holdout比較 + finance-checker handoff artifact
# （src/analysis/financial_instability_comparison.jl）のテスト（Issue #271 Part C・Part D）。

"""テスト用の最小 assessment dict（`financial_instability_assessment_to_dict` と同じ形）。
`overall_status`/`trigger_label`/`weak_credit_label`/`funding_label`/`broad_label` 以外は
比較ロジックに影響しない固定値を使う。"""
function _fic_test_assessment(;
    overall_status::Symbol,
    trigger_label::Symbol = :not_supported,
    weak_credit_label::Symbol = :not_supported,
    funding_label::Symbol = :not_supported,
    broad_label::Symbol = :not_supported,
    from_date::String = "2026-08-13",
    to_date::String = "2026-09-10",
    rule_version::String = FINANCIAL_INSTABILITY_RULE_VERSION,
    assessment_version::String = FINANCIAL_INSTABILITY_HOLDOUT_VERSION,
    identity_hash::String = "sha256:test",
    nominal_shift::Union{Float64, Nothing} = 10.0,
)
    return Dict{String, Any}(
        "version" => assessment_version,
        "identity_hash" => identity_hash,
        "from_date" => from_date,
        "to_date" => to_date,
        "thresholds" => Dict{String, Any}(
            "trigger_watch_bps" => 25.0, "trigger_confirmed_bps" => 50.0,
            "weak_credit_watch_bps" => 30.0, "weak_credit_confirmed_bps" => 75.0,
            "funding_watch_bps" => 10.0, "funding_confirmed_bps" => 25.0,
            "version" => rule_version,
        ),
        "trigger_state" => Dict{String, Any}(
            "from_date" => from_date, "to_date" => to_date,
            "long_nominal_yield_shift_bps" => nominal_shift,
            "long_real_yield_shift_bps" => nominal_shift === nothing ? nothing : nominal_shift / 2,
            "inflation_compensation_shift_bps" => nominal_shift === nothing ? nothing : nominal_shift / 2,
            "label" => String(trigger_label),
        ),
        "weak_credit_state" => Dict{String, Any}(
            "from_date" => from_date, "to_date" => to_date,
            "ccc_oas_latest" => Dict{String, Any}("date" => to_date, "value" => 10.0),
            "divergence_latest_bps" => Dict{String, Any}("date" => to_date, "value" => 800.0),
            "divergence_shift_bps" => 40.0,
            "label" => String(weak_credit_label),
        ),
        "funding_state" => Dict{String, Any}(
            "sofr_minus_iorb_latest_bps" => Dict{String, Any}("date" => to_date, "value" => -3.0),
            "tgcr_minus_iorb_latest_bps" => Dict{String, Any}("date" => to_date, "value" => -5.0),
            "label" => String(funding_label),
        ),
        "broad_conditions_state" => Dict{String, Any}(
            "nfci_latest" => Dict{String, Any}("date" => "2026-09", "value" => -0.5),
            "sloos_latest" => Dict{String, Any}("date" => "2026-Q3", "value" => 0.0),
            "label" => String(broad_label),
        ),
        "model_amplification_state" => Dict{String, Any}(
            "validated_capability" => true, "citation" => "Issue #247–#251", "caveats" => "",
        ),
        "minsky_diagnostic_state" => Dict{String, Any}(
            "capability_description" => "", "citation" => "ADR 0003", "caveats" => "",
        ),
        "overall_status" => String(overall_status),
        "overall_evidence" => ["trigger_state=$(trigger_label)"],
        "caveats" => copy(FINANCIAL_INSTABILITY_CAVEATS),
    )
end

"""テスト用の最小 run_manifest dict。"""
function _fic_test_manifest(;
    dme_code_revision::String = "abc123",
    rule_version::String = FINANCIAL_INSTABILITY_RULE_VERSION,
    catalog_version::String = "financial-stress-catalog/1.0.0",
    data_mode::String = "fixture",
    broad_hy_oas_value::Float64 = 3.10,
    broad_hy_oas_date::String = "2026-09-10",
    series_status::Symbol = :ok,
)
    return Dict{String, Any}(
        "dme_code_revision" => dme_code_revision,
        "rule_version" => rule_version,
        "financial_stress_catalog_version" => catalog_version,
        "data_mode" => data_mode,
        "provider_base" => "http://localhost:8000",
        "edp_identity" => nothing,
        "observation_window" => Dict{String, Any}("from_date" => "2026-08-13", "to_date" => "2026-09-10"),
        "run_timestamp" => "2026-09-12T10:00:00.000Z",
        "series_provenance" => [
            Dict{String, Any}(
                "key" => "broad_hy_oas", "status" => String(series_status), "mode" => data_mode,
                "detail" => series_status == :ok ? "" : "provider error",
                "latest_observation" => series_status == :ok ?
                    Dict{String, Any}("date" => broad_hy_oas_date, "value" => broad_hy_oas_value) : nothing,
            ),
        ],
    )
end

@testset "financial_instability_comparison（Issue #271 Part C・Part D）" begin
    @testset "no_material_change: overall_statusが同じ" begin
        pre = _fic_test_assessment(; overall_status = :not_supported, weak_credit_label = :not_supported)
        post = _fic_test_assessment(; overall_status = :not_supported, weak_credit_label = :watch)
        cmp = compare_financial_instability_assessments(pre, _fic_test_manifest(), post, _fic_test_manifest())
        @test cmp.conclusion == :no_material_change
        @test cmp.pre_overall_status == cmp.post_overall_status == :not_supported
        @test !cmp.overall_status_changed
        wc = only(filter(d -> d.dimension == :weak_credit_state, cmp.dimensions))
        @test wc.label_changed
        @test wc.pre_label == :not_supported
        @test wc.post_label == :watch
    end

    @testset "hypothesis_strengthened: overall_statusのrankが上がる" begin
        pre = _fic_test_assessment(; overall_status = :not_supported)
        post = _fic_test_assessment(; overall_status = :watch)
        cmp = compare_financial_instability_assessments(pre, _fic_test_manifest(), post, _fic_test_manifest())
        @test cmp.conclusion == :hypothesis_strengthened
        @test cmp.overall_status_changed
    end

    @testset "hypothesis_weakened: overall_statusのrankが下がる" begin
        pre = _fic_test_assessment(; overall_status = :confirmed)
        post = _fic_test_assessment(; overall_status = :watch)
        cmp = compare_financial_instability_assessments(pre, _fic_test_manifest(), post, _fic_test_manifest())
        @test cmp.conclusion == :hypothesis_weakened
    end

    @testset "insufficient_comparable_data: どちらかがinsufficient_data" begin
        pre = _fic_test_assessment(; overall_status = :insufficient_data, nominal_shift = nothing)
        post = _fic_test_assessment(; overall_status = :watch)
        cmp = compare_financial_instability_assessments(pre, _fic_test_manifest(), post, _fic_test_manifest())
        @test cmp.conclusion == :insufficient_comparable_data
    end

    @testset "insufficient_comparable_data: rule_versionがpre/postで異なる" begin
        pre = _fic_test_assessment(; overall_status = :watch, rule_version = "financial-instability-rule/1.0.0")
        post = _fic_test_assessment(; overall_status = :watch, rule_version = "financial-instability-rule/2.0.0")
        pre_m = _fic_test_manifest(; rule_version = "financial-instability-rule/1.0.0")
        post_m = _fic_test_manifest(; rule_version = "financial-instability-rule/2.0.0")
        cmp = compare_financial_instability_assessments(pre, pre_m, post, post_m)
        @test cmp.conclusion == :insufficient_comparable_data
        @test !cmp.version_consistency["all_semantic_versions_match"]
        @test !cmp.version_consistency["rule_version"]["match"]
    end

    @testset "dme_code_revisionの不一致は意味論的versionに含めない" begin
        pre = _fic_test_assessment(; overall_status = :watch)
        post = _fic_test_assessment(; overall_status = :watch)
        pre_m = _fic_test_manifest(; dme_code_revision = "aaa111")
        post_m = _fic_test_manifest(; dme_code_revision = "bbb222")
        cmp = compare_financial_instability_assessments(pre, pre_m, post, post_m)
        @test cmp.version_consistency["all_semantic_versions_match"]
        @test !cmp.version_consistency["dme_code_revision"]["match"]
        @test cmp.conclusion == :no_material_change
    end

    @testset "broad_hy_oas_latestはmanifestのseries_provenanceから補われる" begin
        pre = _fic_test_assessment(; overall_status = :watch)
        post = _fic_test_assessment(; overall_status = :watch)
        pre_m = _fic_test_manifest(; broad_hy_oas_value = 3.10, broad_hy_oas_date = "2026-08-13")
        post_m = _fic_test_manifest(; broad_hy_oas_value = 3.16, broad_hy_oas_date = "2026-09-10")
        cmp = compare_financial_instability_assessments(pre, pre_m, post, post_m)
        wc = only(filter(d -> d.dimension == :weak_credit_state, cmp.dimensions))
        diff = wc.values["broad_hy_oas_latest"]
        @test diff["pre"]["value"] == 3.10
        @test diff["post"]["value"] == 3.16
        @test diff["value_delta"] ≈ 0.06 atol = 1e-9
        @test diff["date_changed"] == true
    end

    @testset "conclusionが確定集合に収まる" begin
        for (pre_status, post_status) in [
            (:not_supported, :not_supported), (:not_supported, :watch), (:watch, :confirmed),
            (:confirmed, :watch), (:insufficient_data, :watch),
        ]
            pre = _fic_test_assessment(; overall_status = pre_status)
            post = _fic_test_assessment(; overall_status = post_status)
            cmp = compare_financial_instability_assessments(pre, _fic_test_manifest(), post, _fic_test_manifest())
            @test cmp.conclusion in FINANCIAL_INSTABILITY_COMPARISON_CONCLUSIONS
        end
    end

    @testset "決定性: 同じ入力から同じconclusion/reasonになる" begin
        pre = _fic_test_assessment(; overall_status = :not_supported)
        post = _fic_test_assessment(; overall_status = :watch)
        c1 = compare_financial_instability_assessments(pre, _fic_test_manifest(), post, _fic_test_manifest())
        c2 = compare_financial_instability_assessments(pre, _fic_test_manifest(), post, _fic_test_manifest())
        @test c1.conclusion == c2.conclusion
        @test c1.conclusion_reason == c2.conclusion_reason
    end

    @testset "financial_instability_comparison_to_dict / save" begin
        pre = _fic_test_assessment(; overall_status = :not_supported)
        post = _fic_test_assessment(; overall_status = :watch)
        cmp = compare_financial_instability_assessments(pre, _fic_test_manifest(), post, _fic_test_manifest())
        d = financial_instability_comparison_to_dict(cmp)
        @test d["conclusion"] == "hypothesis_strengthened"
        @test length(d["dimensions"]) == 4
        @test haskey(d, "version_consistency")

        path = joinpath(mktempdir(), "comparison.json")
        saved = save_financial_instability_comparison(path, cmp)
        @test isfile(saved)
        @test filesize(saved) > 0
    end

    @testset "build_financial_instability_handoff: classificationと必須記載" begin
        pre = _fic_test_assessment(; overall_status = :not_supported)
        post = _fic_test_assessment(; overall_status = :watch)
        handoff = build_financial_instability_handoff(pre, _fic_test_manifest(), post, _fic_test_manifest())
        @test handoff.comparison.conclusion == :hypothesis_strengthened
        @test haskey(handoff.classification, "observed_facts")
        @test haskey(handoff.classification, "dme_rule_based_interpretation")
        @test haskey(handoff.classification, "unverified_economic_interpretation")
        @test occursin("経済的解釈", handoff.classification["unverified_economic_interpretation"])
        @test occursin("危機確率", join(handoff.caveats, " "))
        @test occursin("投資判断", join(handoff.caveats, " "))
        @test isempty(handoff.unavailable_evidence)
    end

    @testset "build_financial_instability_handoff: unavailable_evidenceにstatus!=okが列挙される" begin
        pre = _fic_test_assessment(; overall_status = :not_supported)
        post = _fic_test_assessment(; overall_status = :watch)
        pre_m = _fic_test_manifest(; series_status = :provider_error)
        post_m = _fic_test_manifest()
        handoff = build_financial_instability_handoff(pre, pre_m, post, post_m)
        @test !isempty(handoff.unavailable_evidence)
        @test any(occursin("provider_error", n) for n in handoff.unavailable_evidence)
    end

    @testset "financial_instability_handoff_to_dict / save" begin
        pre = _fic_test_assessment(; overall_status = :not_supported)
        post = _fic_test_assessment(; overall_status = :watch)
        handoff = build_financial_instability_handoff(pre, _fic_test_manifest(), post, _fic_test_manifest())
        d = financial_instability_handoff_to_dict(handoff)
        @test d["comparison"]["conclusion"] == "hypothesis_strengthened"
        @test haskey(d, "classification")
        @test haskey(d, "limitations")

        path = joinpath(mktempdir(), "handoff.json")
        saved = save_financial_instability_handoff(path, handoff)
        @test isfile(saved)
        @test filesize(saved) > 0
    end

    @testset "belief/Evidence/Hypothesisという語を出力に含めない（自動更新しないことの明記のみ許可）" begin
        pre = _fic_test_assessment(; overall_status = :not_supported)
        post = _fic_test_assessment(; overall_status = :watch)
        handoff = build_financial_instability_handoff(pre, _fic_test_manifest(), post, _fic_test_manifest())
        # classification内の説明文以外に、危機確率・投資判断等の禁止表現を出力していないことを確認
        all_text = join(
            [
                handoff.classification["unverified_economic_interpretation"],
                join(handoff.caveats, " "), join(handoff.limitations, " "),
            ], " ",
        )
        @test !occursin("crisis probability", lowercase(all_text))
        @test !occursin("buy", lowercase(all_text))
        @test !occursin("sell", lowercase(all_text))
    end
end
