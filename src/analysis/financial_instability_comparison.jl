# financial_instability_comparison.jl: pre/post-FOMC financial-instability holdout
# 比較と finance-checker handoff artifact（Issue #271 Part C・Part D）。
#
# 入力は `financial_instability_holdout.jl`（Issue #260 Part D）が生成する2つの JSON 契約
# （`financial_instability_assessment_to_dict` の出力、および
# `examples/financial_instability_holdout_demo.jl` の `run_manifest.json`、いずれも
# `Dict{String,Any}` として渡す）。本ファイルはEDP・FRED等への新規fetchを行わず、
# 既に保存された（または直前に構築した）2時点の観測から差分を計算するだけの読み取り専用層。
#
# 対象外（Issue #271 が本ファイルへ課す制約）:
#   - 2026-09観測を用いたparameter/threshold再較正（比較はrule/threshold/catalog versionの
#     一致を検証するのみで、値そのものは変更しない）。
#   - crisis / recession probability・投資助言・売買シグナルの算出。
#   - FOMC statementのLLM解釈をshock magnitudeへ変換すること。
#   - finance-checkerのbelief / Evidence / Hypothesisの自動更新（handoff artifactは
#     人間レビュー前提の構造化データに留める）。
#
# 設計契約: docs/examples/financial_instability_holdout_demo.md

# ------------------------------------------------------------
# バージョン・語彙
# ------------------------------------------------------------

"本ファイルの構造・フィールドの version。"
const FINANCIAL_INSTABILITY_COMPARISON_VERSION = "financial-instability-comparison/1.0.0"

"""
    FINANCIAL_INSTABILITY_COMPARISON_CONCLUSIONS

`FinancialInstabilityComparison.conclusion` の確定集合（Issue #271 Part C）。単一の
危機確率・景気後退確率スコアではなく、overall_statusの遷移とversion整合性から導く
human-readableな結論。
"""
const FINANCIAL_INSTABILITY_COMPARISON_CONCLUSIONS = (
    :hypothesis_strengthened,
    :hypothesis_weakened,
    :no_material_change,
    :insufficient_comparable_data,
)

# ------------------------------------------------------------
# dimension別の値差分ヘルパー
# ------------------------------------------------------------

"""数値2点の pre/post/delta（`nothing` はJSON上のmissing/欠測をそのまま伝播し、0へ変換
しない）。"""
function _fic_num_diff(pre, post)::Dict{String, Any}
    delta = (pre === nothing || post === nothing) ? nothing : Float64(post) - Float64(pre)
    return Dict{String, Any}("pre" => pre, "post" => post, "delta" => delta)
end

"""`{"date"=>...,"value"=>...}` 形式（`_fih_dict_tuple` の出力）2点の pre/post/差分。
`date_changed` は同じ観測日かどうか（低頻度系列の「更新の有無」を表す）。"""
function _fic_tuple_diff(pre, post)::Dict{String, Any}
    value_delta =
        (pre === nothing || post === nothing) ? nothing :
        Float64(post["value"]) - Float64(pre["value"])
    date_changed =
        (pre === nothing || post === nothing) ? nothing : pre["date"] != post["date"]
    return Dict{String, Any}(
        "pre" => pre,
        "post" => post,
        "value_delta" => value_delta,
        "date_changed" => date_changed,
    )
end

"""`manifest["series_provenance"]` から `key` の `latest_observation` を取り出す
（`assessment.json` 自体には broad_hy_oas の水準が含まれないため、`run_manifest.json`
（Issue #271 Part A）側から補う）。"""
function _fic_series_latest(manifest::Dict{String, Any}, key::AbstractString)
    for entry in get(manifest, "series_provenance", Any[])
        entry["key"] == key && return entry["latest_observation"]
    end
    return nothing
end

# ------------------------------------------------------------
# DimensionComparison
# ------------------------------------------------------------

"""
    DimensionComparison

1 dimension（`trigger_state`/`weak_credit_state`/`funding_state`/`broad_conditions_state`）の
pre/post比較（Issue #271 Part C）。`values` の形は dimension ごとに異なるため
`Dict{String,Any}` のまま保持する（`_fic_num_diff`/`_fic_tuple_diff` の出力を格納）。
"""
struct DimensionComparison
    dimension::Symbol
    pre_label::Symbol
    post_label::Symbol
    label_changed::Bool
    values::Dict{String, Any}
end

function _fic_dimension_comparison(
    dimension::Symbol,
    pre_state::Dict{String, Any},
    post_state::Dict{String, Any},
    values::Dict{String, Any},
)::DimensionComparison
    pre_label = Symbol(pre_state["label"])
    post_label = Symbol(post_state["label"])
    return DimensionComparison(
        dimension,
        pre_label,
        post_label,
        pre_label != post_label,
        values,
    )
end

# ------------------------------------------------------------
# FinancialInstabilityComparison（Issue #271 Part C）
# ------------------------------------------------------------

"""
    FinancialInstabilityComparison

pre-FOMC/post-FOMC の `FinancialInstabilityAssessment` 2時点比較（Issue #271 Part C）。
単一score ではなく dimension 別の差分を保持し、`conclusion` はその圧縮結果
（`FINANCIAL_INSTABILITY_COMPARISON_CONCLUSIONS` のいずれか）に限定する。

`version_consistency["all_semantic_versions_match"]` が `false`（rule/threshold/catalog
versionのいずれかが pre/post で異なる）の場合、`conclusion` は常に
`:insufficient_comparable_data` になる（比較の前提となる「同じrule」が崩れているため）。
`dme_code_revision` の不一致は意味論的versionに含めない（コードのbugfixなど、計算結果に
影響しない差もありうるため。`version_consistency["dme_code_revision"]` に別掲する）。
"""
struct FinancialInstabilityComparison
    version::String
    generated_at::Union{DateTime, Nothing}
    pre_identity_hash::String
    post_identity_hash::String
    pre_window::Dict{String, Any}
    post_window::Dict{String, Any}
    pre_data_mode::String
    post_data_mode::String
    version_consistency::Dict{String, Any}
    dimensions::Vector{DimensionComparison}
    pre_overall_status::Symbol
    post_overall_status::Symbol
    overall_status_changed::Bool
    pre_overall_evidence::Vector{String}
    post_overall_evidence::Vector{String}
    conclusion::Symbol
    conclusion_reason::String
    caveats::Vector{String}
end

function _fic_version_consistency(
    pre_assessment::Dict{String, Any},
    pre_manifest::Dict{String, Any},
    post_assessment::Dict{String, Any},
    post_manifest::Dict{String, Any},
)::Dict{String, Any}
    rule = Dict{String, Any}(
        "pre" => pre_manifest["rule_version"],
        "post" => post_manifest["rule_version"],
        "match" => pre_manifest["rule_version"] == post_manifest["rule_version"],
    )
    assessment_version = Dict{String, Any}(
        "pre" => pre_assessment["version"],
        "post" => post_assessment["version"],
        "match" => pre_assessment["version"] == post_assessment["version"],
    )
    catalog = Dict{String, Any}(
        "pre" => pre_manifest["financial_stress_catalog_version"],
        "post" => post_manifest["financial_stress_catalog_version"],
        "match" =>
            pre_manifest["financial_stress_catalog_version"] ==
            post_manifest["financial_stress_catalog_version"],
    )
    thresholds = Dict{String, Any}(
        "pre" => pre_assessment["thresholds"],
        "post" => post_assessment["thresholds"],
        "match" => pre_assessment["thresholds"] == post_assessment["thresholds"],
    )
    code_revision = Dict{String, Any}(
        "pre" => get(pre_manifest, "dme_code_revision", nothing),
        "post" => get(post_manifest, "dme_code_revision", nothing),
        "match" =>
            get(pre_manifest, "dme_code_revision", nothing) ==
            get(post_manifest, "dme_code_revision", nothing),
    )
    all_semantic_match =
        rule["match"] &&
        assessment_version["match"] &&
        catalog["match"] &&
        thresholds["match"]
    return Dict{String, Any}(
        "rule_version" => rule,
        "assessment_version" => assessment_version,
        "financial_stress_catalog_version" => catalog,
        "thresholds" => thresholds,
        "dme_code_revision" => code_revision,
        "all_semantic_versions_match" => all_semantic_match,
    )
end

function _fic_conclusion(
    version_consistency::Dict{String, Any},
    pre_status::Symbol,
    post_status::Symbol,
)::Tuple{Symbol, String}
    if !version_consistency["all_semantic_versions_match"]
        return (
            :insufficient_comparable_data,
            "rule_version/assessment_version/financial_stress_catalog_version/thresholds の" *
            "いずれかがpre/postで一致しない（version_consistency参照）。同じruleでの比較という" *
            "前提が崩れているため、hypothesis_strengthened/weakenedを判定しない。",
        )
    end
    if pre_status == :insufficient_data || post_status == :insufficient_data
        return (
            :insufficient_comparable_data,
            "pre（$pre_status）または post（$post_status）の overall_status が " *
            ":insufficient_data のため、有意な比較ができない。",
        )
    end
    pre_rank = findfirst(==(pre_status), FINANCIAL_INSTABILITY_STATUSES)
    post_rank = findfirst(==(post_status), FINANCIAL_INSTABILITY_STATUSES)
    if post_rank > pre_rank
        return (
            :hypothesis_strengthened,
            "overall_status が $pre_status → $post_status へ強まった（rank $(pre_rank-1) → " *
            "$(post_rank-1)、$(FINANCIAL_INSTABILITY_STATUSES)の順）。",
        )
    elseif post_rank < pre_rank
        return (
            :hypothesis_weakened,
            "overall_status が $pre_status → $post_status へ弱まった（rank $(pre_rank-1) → " *
            "$(post_rank-1)）。",
        )
    end
    return (
        :no_material_change,
        "overall_status は $pre_status のまま変化していない（dimension別のlabel遷移は" *
        "dimensions参照）。",
    )
end

"""
    FINANCIAL_INSTABILITY_COMPARISON_CAVEATS

`FinancialInstabilityComparison.caveats` へ必ず含める必須記載（Issue #271 対象外事項を反映）。
"""
const FINANCIAL_INSTABILITY_COMPARISON_CAVEATS = String[
    "本比較は危機確率・景気後退確率の推定ではない。",
    "本比較は投資判断・売買シグナルではない。",
    "conclusionはoverall_statusの遷移（rank比較）から導く versioned rule-based な圧縮結果" * "であり、単一scoreの経済的判断ではない。",
    "FOMC結果そのものをshock magnitudeへ変換していない。市場観測（金利・スプレッド等）の" * "変化のみから6 dimensionを再評価している。",
    "rule/threshold/catalog versionがpre/postで一致しない場合、conclusionは常に" * "insufficient_comparable_dataになる（version_consistency参照）。",
]

"""
    compare_financial_instability_assessments(pre_assessment, pre_manifest,
        post_assessment, post_manifest; generated_at = Dates.now(Dates.UTC))
        -> FinancialInstabilityComparison

Issue #271 Part C。`pre_assessment`/`post_assessment` は
`financial_instability_assessment_to_dict` の出力（またはそれと同じ形の `assessment.json` を
読み込んだ `Dict{String,Any}`）、`pre_manifest`/`post_manifest` は
`examples/financial_instability_holdout_demo.jl` が保存する `run_manifest.json` を読み込んだ
`Dict{String,Any}`。4引数とも新規のEDP/FRED fetchを行わない（読み取り専用の差分計算）。
"""
function compare_financial_instability_assessments(
    pre_assessment::Dict{String, Any},
    pre_manifest::Dict{String, Any},
    post_assessment::Dict{String, Any},
    post_manifest::Dict{String, Any};
    generated_at::Union{DateTime, Nothing} = Dates.now(Dates.UTC),
)::FinancialInstabilityComparison
    pre_t, post_t = pre_assessment["trigger_state"], post_assessment["trigger_state"]
    pre_w, post_w =
        pre_assessment["weak_credit_state"], post_assessment["weak_credit_state"]
    pre_f, post_f = pre_assessment["funding_state"], post_assessment["funding_state"]
    pre_b, post_b =
        pre_assessment["broad_conditions_state"], post_assessment["broad_conditions_state"]

    trigger_values = Dict{String, Any}(
        "long_nominal_yield_shift_bps" => _fic_num_diff(
            pre_t["long_nominal_yield_shift_bps"],
            post_t["long_nominal_yield_shift_bps"],
        ),
        "long_real_yield_shift_bps" => _fic_num_diff(
            pre_t["long_real_yield_shift_bps"],
            post_t["long_real_yield_shift_bps"],
        ),
        "inflation_compensation_shift_bps" => _fic_num_diff(
            pre_t["inflation_compensation_shift_bps"],
            post_t["inflation_compensation_shift_bps"],
        ),
        "pre_window" => Dict{String, Any}(
            "from_date" => pre_t["from_date"],
            "to_date" => pre_t["to_date"],
        ),
        "post_window" => Dict{String, Any}(
            "from_date" => post_t["from_date"],
            "to_date" => post_t["to_date"],
        ),
    )
    weak_credit_values = Dict{String, Any}(
        "ccc_oas_latest" =>
            _fic_tuple_diff(pre_w["ccc_oas_latest"], post_w["ccc_oas_latest"]),
        "broad_hy_oas_latest" => _fic_tuple_diff(
            _fic_series_latest(pre_manifest, "broad_hy_oas"),
            _fic_series_latest(post_manifest, "broad_hy_oas"),
        ),
        "divergence_latest_bps" => _fic_tuple_diff(
            pre_w["divergence_latest_bps"],
            post_w["divergence_latest_bps"],
        ),
        "divergence_shift_bps" => _fic_num_diff(
            pre_w["divergence_shift_bps"],
            post_w["divergence_shift_bps"],
        ),
    )
    funding_values = Dict{String, Any}(
        "sofr_minus_iorb_latest_bps" => _fic_tuple_diff(
            pre_f["sofr_minus_iorb_latest_bps"],
            post_f["sofr_minus_iorb_latest_bps"],
        ),
        "tgcr_minus_iorb_latest_bps" => _fic_tuple_diff(
            pre_f["tgcr_minus_iorb_latest_bps"],
            post_f["tgcr_minus_iorb_latest_bps"],
        ),
    )
    broad_values = Dict{String, Any}(
        "nfci_latest" => _fic_tuple_diff(pre_b["nfci_latest"], post_b["nfci_latest"]),
        "sloos_latest" =>
            _fic_tuple_diff(pre_b["sloos_latest"], post_b["sloos_latest"]),
    )

    dimensions = [
        _fic_dimension_comparison(:trigger_state, pre_t, post_t, trigger_values),
        _fic_dimension_comparison(:weak_credit_state, pre_w, post_w, weak_credit_values),
        _fic_dimension_comparison(:funding_state, pre_f, post_f, funding_values),
        _fic_dimension_comparison(:broad_conditions_state, pre_b, post_b, broad_values),
    ]

    version_consistency = _fic_version_consistency(
        pre_assessment,
        pre_manifest,
        post_assessment,
        post_manifest,
    )
    pre_status = Symbol(pre_assessment["overall_status"])
    post_status = Symbol(post_assessment["overall_status"])
    conclusion, conclusion_reason =
        _fic_conclusion(version_consistency, pre_status, post_status)

    return FinancialInstabilityComparison(
        FINANCIAL_INSTABILITY_COMPARISON_VERSION,
        generated_at,
        pre_assessment["identity_hash"],
        post_assessment["identity_hash"],
        Dict{String, Any}(
            "from_date" => pre_assessment["from_date"],
            "to_date" => pre_assessment["to_date"],
        ),
        Dict{String, Any}(
            "from_date" => post_assessment["from_date"],
            "to_date" => post_assessment["to_date"],
        ),
        String(get(pre_manifest, "data_mode", "unknown")),
        String(get(post_manifest, "data_mode", "unknown")),
        version_consistency,
        dimensions,
        pre_status,
        post_status,
        pre_status != post_status,
        String.(pre_assessment["overall_evidence"]),
        String.(post_assessment["overall_evidence"]),
        conclusion,
        conclusion_reason,
        copy(FINANCIAL_INSTABILITY_COMPARISON_CAVEATS),
    )
end

# ------------------------------------------------------------
# FinancialInstabilityHandoff（Issue #271 Part D）
# ------------------------------------------------------------

"""
    FINANCIAL_INSTABILITY_HANDOFF_CLASSIFICATION

finance-checker handoff artifact に必ず含める、データの位置づけの区分（Issue #271 Part D
受け入れ条件「観測事実／DME rule-based interpretation／未検証の経済解釈を区別する
metadata」）。`unverified_economic_interpretation` を空にすることが本artifactの契約であり、
finance-checker側がHypothesis/Evidenceとして構築する経済的解釈をDME側では一切含めない。
"""
const FINANCIAL_INSTABILITY_HANDOFF_CLASSIFICATION = Dict{String, Any}(
    "observed_facts" =>
        "trigger_state/weak_credit_state/funding_state/broad_conditions_state の" *
        "bp変化・水準・観測日、およびcomparison.dimensionsの数値差分は観測事実である。",
    "dme_rule_based_interpretation" =>
        "各dimensionのlabel・overall_status・" *
        "comparison.conclusionは、versioned rule（rule_version/thresholds、" *
        "FinancialInstabilityThresholds）を観測事実へ機械的に適用した結果であり、経済学的な" *
        "判断ではない。",
    "unverified_economic_interpretation" =>
        "本artifactは経済的解釈（Minsky moment確定・" *
        "危機確率・景気後退確率・投資判断・売買シグナル）を一切含まない。そのような解釈は" *
        "finance-checker側でHypothesis/Evidenceとして人間レビューを経て構築すること。DME側は" *
        "belief・Evidence・Hypothesisの自動更新を行わない。",
)

"""
    FinancialInstabilityHandoff

finance-checkerへの受け渡しartifact（Issue #271 Part D）。`pre`/`post` は assessment dict を
そのまま埋め込み、`comparison` は `FinancialInstabilityComparison` を保持する。belief・
Evidence・Hypothesisの登録・更新は行わない（構造化データの受け渡しのみ）。
"""
struct FinancialInstabilityHandoff
    version::String
    generated_at::Union{DateTime, Nothing}
    pre::Dict{String, Any}
    post::Dict{String, Any}
    pre_provenance_summary::Dict{String, Any}
    post_provenance_summary::Dict{String, Any}
    comparison::FinancialInstabilityComparison
    classification::Dict{String, Any}
    historical_validation_citation::String
    minsky_diagnostic_citation::String
    unavailable_evidence::Vector{String}
    limitations::Vector{String}
    caveats::Vector{String}
end

"""manifest から人が読める provenance summary（系列別status/mode/最新observation日）だけを
抜粋する（生の series_provenance 全件は pre/post 双方の run_manifest.json 参照）。"""
function _fic_provenance_summary(manifest::Dict{String, Any})::Dict{String, Any}
    entries = get(manifest, "series_provenance", Any[])
    return Dict{String, Any}(
        "dme_code_revision" => get(manifest, "dme_code_revision", nothing),
        "data_mode" => get(manifest, "data_mode", nothing),
        "provider_base" => get(manifest, "provider_base", nothing),
        "edp_identity" => get(manifest, "edp_identity", nothing),
        "observation_window" => get(manifest, "observation_window", nothing),
        "run_timestamp" => get(manifest, "run_timestamp", nothing),
        "series_status" => Dict{String, Any}(
            entry["key"] => Dict{String, Any}(
                "status" => entry["status"],
                "mode" => entry["mode"],
                "latest_observation" => entry["latest_observation"],
            ) for entry in entries
        ),
    )
end

"""status が `:ok` でない系列（pre・post いずれか）を「未取得のevidence」として列挙する
（missing/staleを黙って落とさない、Issue #260/#271 対象外事項の帰結）。"""
function _fic_unavailable_evidence(
    pre_manifest::Dict{String, Any},
    post_manifest::Dict{String, Any},
)::Vector{String}
    notes = String[]
    for (label, manifest) in (("pre", pre_manifest), ("post", post_manifest))
        for entry in get(manifest, "series_provenance", Any[])
            entry["status"] == "ok" || push!(
                notes,
                "$label: $(entry["key"]) status=$(entry["status"]) ($(entry["detail"]))",
            )
        end
    end
    return notes
end

"""
    build_financial_instability_handoff(pre_assessment, pre_manifest, post_assessment,
        post_manifest; generated_at = Dates.now(Dates.UTC)) -> FinancialInstabilityHandoff

Issue #271 Part D。内部で `compare_financial_instability_assessments`（Part C）を呼び、その
結果を含む finance-checker handoff artifact を構築する。belief・Evidence・Hypothesisの登録・
更新は行わない。
"""
function build_financial_instability_handoff(
    pre_assessment::Dict{String, Any},
    pre_manifest::Dict{String, Any},
    post_assessment::Dict{String, Any},
    post_manifest::Dict{String, Any};
    generated_at::Union{DateTime, Nothing} = Dates.now(Dates.UTC),
)::FinancialInstabilityHandoff
    comparison = compare_financial_instability_assessments(
        pre_assessment,
        pre_manifest,
        post_assessment,
        post_manifest;
        generated_at = generated_at,
    )
    limitations = vcat(
        copy(FINANCIAL_INSTABILITY_CAVEATS),
        String["model_amplification_state/minsky_diagnostic_stateはIssue #247–#251/ADR 0003への" * "静的citationであり、pre/postいずれの実行でも2026-09データを用いた新規のモデル" * "較正ではない。",],
    )
    return FinancialInstabilityHandoff(
        FINANCIAL_INSTABILITY_COMPARISON_VERSION,
        generated_at,
        pre_assessment,
        post_assessment,
        _fic_provenance_summary(pre_manifest),
        _fic_provenance_summary(post_manifest),
        comparison,
        copy(FINANCIAL_INSTABILITY_HANDOFF_CLASSIFICATION),
        post_assessment["model_amplification_state"]["citation"],
        post_assessment["minsky_diagnostic_state"]["citation"],
        _fic_unavailable_evidence(pre_manifest, post_manifest),
        limitations,
        copy(FINANCIAL_INSTABILITY_COMPARISON_CAVEATS),
    )
end

# ------------------------------------------------------------
# シリアライズ
# ------------------------------------------------------------

function _fic_dimension_to_dict(d::DimensionComparison)::Dict{String, Any}
    return Dict{String, Any}(
        "dimension" => String(d.dimension),
        "pre_label" => String(d.pre_label),
        "post_label" => String(d.post_label),
        "label_changed" => d.label_changed,
        "values" => d.values,
    )
end

"""
    financial_instability_comparison_to_dict(c::FinancialInstabilityComparison) -> Dict{String,Any}

`c` をJSONシリアライズ可能な `Dict` へ変換する（Issue #271 Part C）。
"""
function financial_instability_comparison_to_dict(
    c::FinancialInstabilityComparison,
)::Dict{String, Any}
    return Dict{String, Any}(
        "version" => c.version,
        "generated_at" =>
            c.generated_at === nothing ? nothing :
            Dates.format(c.generated_at, dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"),
        "pre_identity_hash" => c.pre_identity_hash,
        "post_identity_hash" => c.post_identity_hash,
        "pre_window" => c.pre_window,
        "post_window" => c.post_window,
        "pre_data_mode" => c.pre_data_mode,
        "post_data_mode" => c.post_data_mode,
        "version_consistency" => c.version_consistency,
        "dimensions" => [_fic_dimension_to_dict(d) for d in c.dimensions],
        "pre_overall_status" => String(c.pre_overall_status),
        "post_overall_status" => String(c.post_overall_status),
        "overall_status_changed" => c.overall_status_changed,
        "pre_overall_evidence" => c.pre_overall_evidence,
        "post_overall_evidence" => c.post_overall_evidence,
        "conclusion" => String(c.conclusion),
        "conclusion_reason" => c.conclusion_reason,
        "caveats" => c.caveats,
    )
end

"""
    save_financial_instability_comparison(path, c::FinancialInstabilityComparison) -> path
"""
function save_financial_instability_comparison(
    path::AbstractString,
    c::FinancialInstabilityComparison,
)::String
    open(path, "w") do io
        JSON3.pretty(io, financial_instability_comparison_to_dict(c))
    end
    return String(path)
end

"""
    financial_instability_handoff_to_dict(h::FinancialInstabilityHandoff) -> Dict{String,Any}

`h` をJSONシリアライズ可能な `Dict` へ変換する（Issue #271 Part D）。
"""
function financial_instability_handoff_to_dict(
    h::FinancialInstabilityHandoff,
)::Dict{String, Any}
    return Dict{String, Any}(
        "version" => h.version,
        "generated_at" =>
            h.generated_at === nothing ? nothing :
            Dates.format(h.generated_at, dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"),
        "pre" => h.pre,
        "post" => h.post,
        "pre_provenance_summary" => h.pre_provenance_summary,
        "post_provenance_summary" => h.post_provenance_summary,
        "comparison" => financial_instability_comparison_to_dict(h.comparison),
        "classification" => h.classification,
        "historical_validation_citation" => h.historical_validation_citation,
        "minsky_diagnostic_citation" => h.minsky_diagnostic_citation,
        "unavailable_evidence" => h.unavailable_evidence,
        "limitations" => h.limitations,
        "caveats" => h.caveats,
    )
end

"""
    save_financial_instability_handoff(path, h::FinancialInstabilityHandoff) -> path
"""
function save_financial_instability_handoff(
    path::AbstractString,
    h::FinancialInstabilityHandoff,
)::String
    open(path, "w") do io
        JSON3.pretty(io, financial_instability_handoff_to_dict(h))
    end
    return String(path)
end
