# keen_empirical_prompts.jl: Keen 実証分析結果の根拠付き説明 API と専用プロンプト。
#
# 設計契約は docs/adr/0005-keen-ai-explanation-contract.md（§4 構造化出力・§5 warning・
# §6 禁止解釈・§7 fallback・§8 provider 境界）。
#   - 認識論的性質（観測 / 測定 / 推定 / モデル出力 / diagnostic proxy / 感応度 / 限界）を
#     epistemic_status で明示し、一文の中で混合しない。
#   - すべての claim は source registry（EvidenceSource）の安定 ID を参照する。
#   - warning severity を section status・許可される claim・provider 呼び出し可否へ反映する。
#   - provider 未接続でも context 生成・prompt 生成・決定的 fallback 出力を単体利用できる。
#   - provider 応答は JSON schema・source registry・安全性で検証し、失敗時は決定的 fallback。
#
# 本ファイルは LLM API を直接呼ばない（provider 抽象化経由でのみ呼ぶ）。数値の再計算も行わない。
# 実証層（keen_calibration.jl / keen_validation.jl）・データ層は本ファイルの追加で変更されない。

"""
    KEEN_AI_OUTPUT_CONTRACT_VERSION

Keen 実証説明出力契約（`KeenEmpiricalExplanationOutput`）の version（ADR 0005 §8.2）。必須
section・status 意味論・禁止解釈を変更する場合に major を上げる。
"""
const KEEN_AI_OUTPUT_CONTRACT_VERSION = "keen-ai-output/1.0.0"

# epistemic_status 固定語彙（ADR 0005 §1.3）
const KEEN_EPISTEMIC_STATUSES =
    (:observed, :measured, :estimated, :simulated, :diagnostic, :sensitivity, :limitation)

# section status 固定語彙（ADR 0005 §4.2）
const KEEN_SECTION_STATUSES = (:available, :not_available, :insufficient_evidence)

# category → epistemic_status 対応（ADR 0005 §1.3）
const _KEEN_CATEGORY_STATUS = Dict{Symbol, Symbol}(
    :observed_data => :observed,
    :measurement => :measured,
    :calibration => :estimated,
    :model_output => :simulated,
    :diagnostic_proxy => :diagnostic,
    :sensitivity => :sensitivity,
    :limitations => :limitation,
)

# 必須 section キーと表示順（ADR 0005 §4.3）
const KEEN_OUTPUT_SECTION_ORDER = (
    "executive_summary",
    "analysis_scope",
    "observed_evidence",
    "measurement_and_transformations",
    "calibration_interpretation",
    "validation_assessment",
    "regime_assessment",
    "sensitivity_and_robustness",
    "interpretation_scope",
    "limitations_and_alternatives",
)

# warning severity の順序（弱→強）
const _KEEN_SEVERITY_RANK =
    Dict{Symbol, Int}(:info => 1, :warning => 2, :error => 3, :blocking => 4)

# ===========================================================================
# 出力型（ADR 0005 §4.2 / §4.3）
# ===========================================================================

"""
    EvidenceClaim

根拠付き主張の最小単位（ADR 0005 §4.2）。1 claim は 1 つの `epistemic_status` を持ち、
`source_ids` は 1 件以上必須で、すべて context の source registry に存在しなければならない。

## フィールド
- `claim_id::String` : section 内で一意な安定 ID
- `text::String` : 主張本文
- `epistemic_status::Symbol` : `KEEN_EPISTEMIC_STATUSES` の 1 つ
- `source_ids::Vector{String}` : 参照する `EvidenceSource.id`（1 件以上）
- `qualifiers::Vector{String}` : 限定・注意（warning message など）
"""
struct EvidenceClaim
    claim_id::String
    text::String
    epistemic_status::Symbol
    source_ids::Vector{String}
    qualifiers::Vector{String}
end

function EvidenceClaim(;
    claim_id::String,
    text::String,
    epistemic_status::Symbol,
    source_ids::Vector{String},
    qualifiers::Vector{String} = String[],
)
    epistemic_status in KEEN_EPISTEMIC_STATUSES || throw(
        ArgumentError(
            "未知の epistemic_status: $(repr(epistemic_status))（有効: $(KEEN_EPISTEMIC_STATUSES)）",
        ),
    )
    EvidenceClaim(claim_id, text, epistemic_status, source_ids, qualifiers)
end

"""
    ExplanationSection

1 つの必須 section（ADR 0005 §4.2）。`status` は `:available`（全 claim が検証を通過）/
`:not_available`（入力自体が無い）/ `:insufficient_evidence`（入力はあるが欠損・warning・
不整合で結論を支えられない）のいずれか。空文字やセクション省略で代用しない。

## フィールド
- `status::Symbol` : `KEEN_SECTION_STATUSES` の 1 つ
- `claims::Vector{EvidenceClaim}`
- `missing_fields::Vector{String}` : 欠落・抑止された情報の説明
"""
struct ExplanationSection
    status::Symbol
    claims::Vector{EvidenceClaim}
    missing_fields::Vector{String}

    function ExplanationSection(
        status::Symbol,
        claims::Vector{EvidenceClaim} = EvidenceClaim[],
        missing_fields::Vector{String} = String[],
    )
        status in KEEN_SECTION_STATUSES || throw(
            ArgumentError(
                "未知の section status: $(repr(status))（有効: $(KEEN_SECTION_STATUSES)）",
            ),
        )
        new(status, claims, missing_fields)
    end
end

"""
    KeenEmpiricalExplanationOutput

Keen 実証結果の根拠付き構造化説明（ADR 0005 §4.3）。必須 section を常に持ち、情報が無い場合も
`not_available` / `insufficient_evidence` で表現する。`source_references` は claim から実際に
参照された registry entry だけを重複なく保持する。

## 生成モード（`generation_status`）
- `:deterministic` : provider 未接続。検証済み context だけから決定的に生成した安全出力
- `:parsed` : provider 応答が schema・source・安全性検証を通過
- `:fallback` : provider 応答が検証に失敗し、決定的 fallback へ落ちた（parser failure warning 付き）
"""
struct KeenEmpiricalExplanationOutput
    contract_version::String
    prompt_version::String
    generation_status::Symbol
    audience::Symbol
    detail::Symbol
    executive_summary::ExplanationSection
    analysis_scope::ExplanationSection
    observed_evidence::ExplanationSection
    measurement_and_transformations::ExplanationSection
    calibration_interpretation::ExplanationSection
    validation_assessment::ExplanationSection
    regime_assessment::ExplanationSection
    sensitivity_and_robustness::ExplanationSection
    interpretation_scope::ExplanationSection
    limitations_and_alternatives::ExplanationSection
    source_references::Vector{EvidenceSource}
    reproducibility::Dict{String, Any}
    warnings::Vector{ExplanationWarning}
    prompt::String
    disclaimer::String
end

# section キー → output field アクセサ（表示順の走査に使う）
function _keen_section(out::KeenEmpiricalExplanationOutput, key::String)
    key == "executive_summary" && return out.executive_summary
    key == "analysis_scope" && return out.analysis_scope
    key == "observed_evidence" && return out.observed_evidence
    key == "measurement_and_transformations" && return out.measurement_and_transformations
    key == "calibration_interpretation" && return out.calibration_interpretation
    key == "validation_assessment" && return out.validation_assessment
    key == "regime_assessment" && return out.regime_assessment
    key == "sensitivity_and_robustness" && return out.sensitivity_and_robustness
    key == "interpretation_scope" && return out.interpretation_scope
    key == "limitations_and_alternatives" && return out.limitations_and_alternatives
    throw(ArgumentError("未知の section key: $(repr(key))"))
end

# ===========================================================================
# system prompt（ADR 0005 §4 / §6 / §8）
# ===========================================================================

const _KEEN_EMPIRICAL_SYSTEM_PROMPT = """
あなたは動学的マクロ経済モデル（DME）の Keen 実証分析を説明する分析補助AIです。
Keen（Minsky系）モデルの実データ接続・限定キャリブレーション・検証・regime 診断・感応度分析の
結果を、認識論的性質を混同せずに構造化して説明します。

【役割】
- 観測事実・測定変換・推定値・モデル出力・diagnostic proxy・感応度・限界を明確に区別して説明する
- 各主張に対し、コンテキスト内の source ID（EvidenceSource.id）を対応付ける
- 情報が不足する場合は推測せず、欠落項目と追加検証候補を提示する

【必ず守る区別（epistemic_status）】
- observed（観測）: 公表系列に記録された値
- measured（測定・変換）: 観測方程式・単位変換・頻度集約を経てモデル単位へ変換した値
- estimated（推定）: 特定の標本・proxy・bounds・objective に依存する限定キャリブレーション推定値
- simulated（モデル出力）: literature / calibrated モデルの予測 trajectory と fit
- diagnostic（診断proxy）: 集計系列へ操作的診断式を適用した financing regime 区分
- sensitivity（感応度）: 実際に変更した仮定の範囲内での結論の安定性
- limitation（限界）: モデル・データ・測定・識別・診断上の制約

【Keen 実証説明の禁止事項】
1. calibrated parameter を経済構造の真値・因果 parameter・普遍定数として断定しない
   （特定の標本・proxy・bounds・objective のもとで得た限定推定値として述べる）
2. in-sample fit をモデル妥当性の十分条件としない
3. out-of-sample fit を因果的妥当性・将来予測保証・政策効果の証明へ昇格しない
   （holdout 区間での条件付き trajectory fit として限定する）
4. observed proxy regime を Keen 内部の endogenous regime や企業別実測分類と同一視しない
   （同じ診断式を集計 proxy へ適用した操作的区分として述べる）
5. 相関・転換点・timing 一致だけから危機の因果経路を確定しない
   （一致という記述と、代替説明・証拠不足を分離する）
6. 未検証範囲まで感応度の頑健性を外挿しない
7. 欠損・頻度変換・単位差・系列改定を無視して直接比較しない
8. 発散後の null / NaN を 0 や特定 regime へ読み替えない（欠損または発散として明示する）
9. コンテキストに無いデータ・文献・モデル特性を一般知識から補完しない
   （情報が無い場合は not_available / insufficient_evidence とする）
10. 投資助言・政策勧告・危機確率へ変換しない（学術的な条件付き分析と免責を示す）

【必ず含める情報】
- 分析対象（国・期間・取得モード・比較モデル）
- 観測事実・測定変換・推定・検証・regime・感応度の各 section（情報が無い場合も status を明示）
- 各主張の source ID
- モデル・データ・測定・識別・診断上の限界
- 免責文言（「本出力は投資判断・政策立案の根拠として使用することを意図していません」）
"""

# ===========================================================================
# prompt 構築（ADR 0005 §4.1 / §8）
# ===========================================================================

# 出力 JSON schema の要求文（provider 非対応でも同じ schema を prompt で要求する）
function _keen_output_schema_instruction()
    sections = join(KEEN_OUTPUT_SECTION_ORDER, "\", \"")
    """
出力は次の JSON オブジェクト 1 個のみを返してください（前後に自由文・code fence を付けない）。
{
  "contract_version": "$(KEEN_AI_OUTPUT_CONTRACT_VERSION)",
  "generation_status": "parsed",
  "<各 section>": {
    "status": "available" | "not_available" | "insufficient_evidence",
    "claims": [
      {
        "claim_id": "<section 内で一意>",
        "text": "<主張本文>",
        "epistemic_status": "observed|measured|estimated|simulated|diagnostic|sensitivity|limitation",
        "source_ids": ["<context の sources に存在する id>", ...],
        "qualifiers": ["<限定・注意>", ...]
      }
    ],
    "missing_fields": ["<欠落・抑止した情報>", ...]
  }
}
必須 section（この順序）: ["$(sections)"]。
規則:
- source_ids は 1 件以上、すべて context の "sources" に存在する id のみ。
- epistemic_status と参照 source の category を整合させる（例: calibration の推定値は estimated）。
- warning の severity=error / blocking が該当する section は insufficient_evidence とし、
  肯定的な解釈 claim を生成しない（値の存在自体は qualifier 付きで報告可）。
- 情報が無い section は not_available、入力はあるが結論を支えられない場合は insufficient_evidence。
"""
end

"""
    build_keen_empirical_prompt(context::AnalysisContext; audience=:analyst, detail=:standard) -> String

`AnalysisContext.keen_empirical` から Keen 実証説明用のプロンプト全文を生成する（ADR 0005 §4.1）。

システム安全指示（§4 / §6）と、構造化コンテキスト（source registry・warning を含む）・出力
JSON schema・利用可能 source ID 一覧を埋め込んだユーザープロンプトを結合して返す。実際の LLM
呼び出しは行わない。`detail=:brief` の場合は observed 系列の生配列を落とした compact context を使う。

`keen_empirical` が `nothing` の場合は `ArgumentError` を送出する。
"""
function build_keen_empirical_prompt(
    context::AnalysisContext;
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
)::String
    kctx = context.keen_empirical
    isnothing(kctx) && throw(
        ArgumentError(
            "build_keen_empirical_prompt requires keen_empirical in AnalysisContext. " *
            "実証層成果物から KeenEmpiricalContext を構築して設定してください。",
        ),
    )

    ctx_dict = detail === :brief ? to_compact_dict(kctx) : to_dict(kctx)
    ctx_json = JSON3.write(ctx_dict)
    source_ids = sort!(collect(keys(kctx.sources)))
    ids_str = isempty(source_ids) ? "（なし）" : join(source_ids, ", ")

    sc = kctx.analysis_scope
    val_period =
        sc.validation_period === nothing ? "なし" :
        "$(sc.validation_period[1])〜$(sc.validation_period[2])"

    warn_lines = String[]
    for w in kctx.warnings
        push!(
            warn_lines,
            "  - [$(w.severity)] $(w.code): $(w.message)" * (
                isempty(w.affected_sections) ? "" :
                "（section: $(join(w.affected_sections, "/"))）"
            ),
        )
    end
    warn_str = isempty(warn_lines) ? "  （警告なし）" : join(warn_lines, "\n")

    user_prompt = """
以下の Keen 実証分析コンテキストを、認識論的性質を区別しながら構造化して説明してください。

対象読者: $(audience)
詳細度: $(detail)

分析対象:
  国: $(sc.country)
  標本期間: $(sc.sample_start)〜$(sc.sample_end)（観測数: $(sc.n_obs)、取得モード: $(sc.mode)）
  比較モデル: $(join(String.(sc.comparison_models), ", "))
  キャリブレーション期間: $(sc.calibration_period[1])〜$(sc.calibration_period[2])
  検証期間: $(val_period)

warning（severity が section status・許可される claim を規定する）:
$(warn_str)

利用可能な source ID（claim はこの中の id のみ参照可）:
  $(ids_str)

構造化コンテキスト（JSON。数値・期間・系列・診断・感応度と source registry を含む）:
$(ctx_json)

$(_keen_output_schema_instruction())
必ず次の免責を出力の一部として含めてください:
  「$(replace(_DISCLAIMER_JA, "\n" => " "))」
"""

    _KEEN_EMPIRICAL_SYSTEM_PROMPT * "\n---\n" * user_prompt
end

# ===========================================================================
# 決定的 fallback / deterministic 出力（ADR 0005 §7.2）
# ===========================================================================

# section に影響する warning の最大 severity（無ければ nothing）
function _keen_section_severity(warnings::Vector{ExplanationWarning}, section::String)
    sev = nothing
    for w in warnings
        section in w.affected_sections || continue
        if sev === nothing || _KEEN_SEVERITY_RANK[w.severity] > _KEEN_SEVERITY_RANK[sev]
            sev = w.severity
        end
    end
    sev
end

# section に影響する warning message（qualifier / missing_fields 用）
function _keen_section_warning_messages(
    warnings::Vector{ExplanationWarning},
    section::String,
)
    msgs = String[]
    for w in warnings
        section in w.affected_sections && push!(msgs, "[$(w.code)] $(w.message)")
    end
    msgs
end

# 入力有無と warning severity から section status を決める
function _keen_resolve_status(has_input::Bool, sev::Union{Symbol, Nothing})
    has_input || return :not_available
    (sev === :error || sev === :blocking) && return :insufficient_evidence
    :available
end

_keen_round(x::Real; digits = 4) = isfinite(x) ? round(Float64(x); digits = digits) : x
_keen_fmt(x::Real) = string(_keen_round(x))
_keen_fmt(::Nothing) = "null"

# 変数別 fit を可読文字列へ
function _keen_fmt_fit(f::ValidationVariableFit)
    parts = ["$(f.variable): n=$(f.n_pairs)"]
    f.rmse === nothing || push!(parts, "RMSE=$(_keen_fmt(f.rmse))")
    f.mae === nothing || push!(parts, "MAE=$(_keen_fmt(f.mae))")
    f.correlation === nothing ||
        push!(parts, "corr=$(_keen_round(f.correlation; digits = 3))")
    join(parts, ", ")
end

# --- 各 section の決定的 claim 生成 ---------------------------------------

function _keen_scope_section(kctx::KeenEmpiricalContext, src_ref::Vector{String})
    sc = kctx.analysis_scope
    val_period =
        sc.validation_period === nothing ? "なし" :
        "$(sc.validation_period[1])〜$(sc.validation_period[2])"
    claims = EvidenceClaim[
        EvidenceClaim(;
            claim_id = "scope.extent",
            text = "分析対象は $(sc.country)、標本期間 $(sc.sample_start)〜$(sc.sample_end)" *
                   "（観測数 $(sc.n_obs)、取得モード $(sc.mode)）。",
            epistemic_status = :measured,
            source_ids = copy(src_ref),
        ),
        EvidenceClaim(;
            claim_id = "scope.split",
            text = "比較モデル: $(join(String.(sc.comparison_models), ", "))。" *
                   "キャリブレーション期間 $(sc.calibration_period[1])〜$(sc.calibration_period[2])、" *
                   "検証期間 $(val_period)。",
            epistemic_status = :measured,
            source_ids = copy(src_ref),
        ),
    ]
    ExplanationSection(:available, claims, String[])
end

function _keen_observed_section(kctx::KeenEmpiricalContext)
    isempty(kctx.observed_data) &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["observed_data"])
    claims = EvidenceClaim[]
    for o in kctx.observed_data
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "obs.$(o.variable)",
                text = "観測系列 $(o.variable)（$(o.provider)/$(o.series_id)）は $(o.n_used) 点を採用" *
                       "（source 欠損 $(o.n_source_missing)、無効 $(o.n_invalid)）。" *
                       "期間 $(o.period_start)〜$(o.period_end)。",
                epistemic_status = :observed,
                source_ids = copy(o.source_ids),
                qualifiers = [
                    "変換後 unit=$(o.unit)（元 unit=$(o.original_unit)、変換=$(o.conversion_formula)）は" *
                    "測定・変換であり生の公表値ではない",
                ],
            ),
        )
    end
    ExplanationSection(:available, claims, String[])
end

function _keen_measurement_section(kctx::KeenEmpiricalContext)
    m = kctx.measurement
    m === nothing &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["measurement"])
    mapping = join(["$(k)←$(v)" for (k, v) in sort(collect(m.series_mapping))], ", ")
    conv = join(["$(k): $(v)" for (k, v) in sort(collect(m.conversion_formulas))], "; ")
    claims = EvidenceClaim[EvidenceClaim(;
        claim_id = "measurement.mapping",
        text = "観測方程式・系列対応: $(mapping)。変換式: $(conv)。" *
               "r_mode=$(m.r_mode)（r_param=$(_keen_fmt(m.r_param))）、" *
               "欠損により除外した日付 $(length(m.dropped_dates)) 件。",
        epistemic_status = :measured,
        source_ids = copy(m.source_ids),
        qualifiers = ["単位差・頻度変換・系列改定を伴うため観測値とは区別する"],
    ),]
    ExplanationSection(:available, claims, String[])
end

function _keen_calibration_section(kctx::KeenEmpiricalContext)
    c = kctx.calibration
    c === nothing &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["calibration"])
    sev = _keen_section_severity(kctx.warnings, "calibration_interpretation")
    notes = _keen_section_warning_messages(kctx.warnings, "calibration_interpretation")
    status = _keen_resolve_status(true, sev)

    est =
        join(["$(k)=$(_keen_fmt(v))" for (k, v) in sort(collect(c.estimated_values))], ", ")
    base_qual = [
        "特定の標本・proxy・bounds・objective に依存する限定推定値であり、構造の真値・因果parameter・普遍定数ではない",
    ]
    append!(base_qual, notes)

    claims = EvidenceClaim[]
    if status === :insufficient_evidence
        # error（未収束など）: 解釈 claim を生成せず、値の存在のみ報告
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "calibration.trial",
                text = "採用試行の推定値は $(est)（objective_method=$(c.objective_method), " *
                       "objective=$(_keen_fmt(c.objective_value)), converged=$(c.converged)）。" *
                       "これは未収束の推定試行であり calibrated model の肯定評価には用いない。",
                epistemic_status = :estimated,
                source_ids = copy(c.source_ids),
                qualifiers = base_qual,
            ),
        )
    else
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "calibration.estimates",
                text = "限定キャリブレーションの採用推定値: $(est)" *
                       "（objective_method=$(c.objective_method), objective=$(_keen_fmt(c.objective_value)), " *
                       "iterations=$(c.iterations), converged=$(c.converged)）。",
                epistemic_status = :estimated,
                source_ids = copy(c.source_ids),
                qualifiers = base_qual,
            ),
        )
        if !isempty(c.fixed_params)
            fixed = join(
                ["$(k)=$(_keen_fmt(v))" for (k, v) in sort(collect(c.fixed_params))],
                ", ",
            )
            push!(
                claims,
                EvidenceClaim(;
                    claim_id = "calibration.fixed",
                    text = "固定パラメータ: $(fixed)（推定対象外）。",
                    epistemic_status = :estimated,
                    source_ids = copy(c.source_ids),
                ),
            )
        end
    end
    missing =
        status === :insufficient_evidence ? vcat(["converged=false"], notes) : String[]
    ExplanationSection(status, claims, missing)
end

function _keen_validation_section(kctx::KeenEmpiricalContext)
    v = kctx.validation
    v === nothing &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["validation"])
    sev = _keen_section_severity(kctx.warnings, "validation_assessment")
    notes = _keen_section_warning_messages(kctx.warnings, "validation_assessment")
    status = _keen_resolve_status(!isempty(v.evaluations), sev)
    isempty(v.evaluations) &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["evaluations"])

    base_qual = [
        "標本内/外の条件付き trajectory fit であり、因果妥当性・将来予測保証・政策効果ではない",
    ]
    append!(base_qual, notes)

    claims = EvidenceClaim[]
    for e in v.evaluations
        fit_str =
            isempty(e.fits) ? "（fit metric なし）" : join(_keen_fmt_fit.(e.fits), " | ")
        div_note =
            e.diverged ? "（発散: offset=$(e.divergence_offset)、発散後は補間しない）" : ""
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "validation.$(e.model_label).$(e.period).$(e.initial_state_mode)",
                text = "$(e.model_label) / $(e.period) / $(e.initial_state_mode): " *
                       "n=$(e.n_obs)。$(fit_str)$(div_note)。",
                epistemic_status = :simulated,
                source_ids = [e.source_id],
                qualifiers = copy(base_qual),
            ),
        )
    end
    # 集計比較（calibrated が literature より悪化しているか）
    push!(
        claims,
        EvidenceClaim(;
            claim_id = "validation.aggregate",
            text = "集計 RMSE（$(v.aggregate_rmse_period)）: literature=$(_keen_fmt(v.aggregate_rmse_literature))、" *
                   "calibrated=$(_keen_fmt(v.aggregate_rmse_calibrated))。" *
                   "calibrated が literature より悪化: $(v.calibrated_worse_than_literature)。",
            epistemic_status = :simulated,
            source_ids = copy(v.source_ids),
            qualifiers = copy(base_qual),
        ),
    )
    missing = status === :insufficient_evidence ? notes : String[]
    ExplanationSection(status, claims, missing)
end

function _keen_regime_section(kctx::KeenEmpiricalContext)
    isempty(kctx.regime_diagnostics) &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["regime_diagnostics"])
    sev = _keen_section_severity(kctx.warnings, "regime_assessment")
    notes = _keen_section_warning_messages(kctx.warnings, "regime_assessment")
    status = _keen_resolve_status(true, sev)

    claims = EvidenceClaim[]
    for r in kctx.regime_diagnostics
        share = join(
            [
                "$(k)=$(_keen_round(v; digits = 3))" for
                (k, v) in sort(collect(r.regime_share))
            ],
            ", ",
        )
        qual = [r.proxy_limitation]
        if r.subject === :observed_proxy
            push!(
                qual,
                "集計 proxy への操作的診断であり、Keen 内部の endogenous regime や企業別実測分類ではない",
            )
        end
        append!(qual, notes)
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "regime.$(r.subject)",
                text = "$(r.subject) の financing regime 診断: 滞在比率 [$(share)]、" *
                       "first_speculative=$(r.first_speculative_time)、first_ponzi=$(r.first_ponzi_time)、" *
                       "peak_debt_ratio=$(_keen_fmt(r.peak_debt_ratio))" *
                       (r.diverged ? "（発散: time=$(r.divergence_time)）" : "") *
                       "。",
                epistemic_status = :diagnostic,
                source_ids = copy(r.source_ids),
                qualifiers = qual,
            ),
        )
    end
    missing = status === :insufficient_evidence ? notes : String[]
    ExplanationSection(status, claims, missing)
end

function _keen_sensitivity_section(kctx::KeenEmpiricalContext)
    isempty(kctx.sensitivity) &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["sensitivity"])
    sev = _keen_section_severity(kctx.warnings, "sensitivity_and_robustness")
    notes = _keen_section_warning_messages(kctx.warnings, "sensitivity_and_robustness")
    # SENSITIVITY_UNSTABLE は warning だが、頑健性主張を抑止するため insufficient に落とす
    unstable = any(s -> s.robustness_status === :unstable, kctx.sensitivity)
    status = if unstable
        :insufficient_evidence
    else
        _keen_resolve_status(true, sev)
    end

    claims = EvidenceClaim[]
    for s in kctx.sensitivity
        est_delta =
            isempty(s.estimated_delta_vs_base) ? "（base）" :
            join(
                [
                    "Δ$(k)=$(_keen_fmt(v))" for
                    (k, v) in sort(collect(s.estimated_delta_vs_base))
                ],
                ", ",
            )
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "sensitivity.$(s.scenario_name)",
                text = "シナリオ「$(s.scenario_name)」（$(s.kind)）: $(est_delta)、" *
                       "objective_Δ=$(_keen_fmt(s.objective_delta_vs_base))、符号反転=$(s.sign_reversal)、" *
                       "発散=$(s.diverged)、robustness=$(s.robustness_status)。",
                epistemic_status = :sensitivity,
                source_ids = copy(s.source_ids),
                qualifiers = vcat(
                    ["実際に変更した仮定と検証済み範囲内でのみ成立し、範囲外へ外挿しない"],
                    notes,
                ),
            ),
        )
    end
    missing =
        unstable ? vcat(["robustness_unstable"], notes) :
        (status === :insufficient_evidence ? notes : String[])
    ExplanationSection(status, claims, missing)
end

function _keen_interpretation_scope_section(lim_ref::Vector{String})
    claims = EvidenceClaim[EvidenceClaim(;
        claim_id = "interpretation.boundary",
        text = "本説明は、観測系列と測定変換、限定キャリブレーション推定値、標本内/外の条件付き fit、" *
               "集計 proxy への regime 診断、検証済み感応度シナリオに限定される。" *
               "因果効果・将来予測・政策効果・危機確率へは拡張できない。",
        epistemic_status = :limitation,
        source_ids = copy(lim_ref),
    ),]
    ExplanationSection(:available, claims, String[])
end

function _keen_limitations_section(kctx::KeenEmpiricalContext, lim_ref::Vector{String})
    claims = EvidenceClaim[]
    for l in kctx.limitations
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "limitation.$(l.code)",
                text = l.text,
                epistemic_status = :limitation,
                source_ids = copy(l.source_ids),
            ),
        )
    end
    # warning を代替説明・限界 claim へ。claim は limitation category（epistemic_status=:limitation）
    # の source のみ参照し、影響を受ける source / section は qualifier に記録する（category と
    # epistemic_status の整合を保つ。ADR 0005 §2.2）。
    for w in kctx.warnings
        w.severity === :info && continue
        quals = String[]
        isempty(w.affected_source_ids) ||
            push!(quals, "影響 source: $(join(w.affected_source_ids, ", "))")
        isempty(w.affected_sections) ||
            push!(quals, "影響 section: $(join(w.affected_sections, ", "))")
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "limitation.warning.$(w.code)",
                text = "[$(w.severity)] $(w.code): $(w.message)",
                epistemic_status = :limitation,
                source_ids = copy(lim_ref),
                qualifiers = quals,
            ),
        )
    end
    status = isempty(claims) ? :not_available : :available
    ExplanationSection(status, claims, isempty(claims) ? ["limitations"] : String[])
end

function _keen_executive_summary(
    kctx::KeenEmpiricalContext,
    sections::Dict{String, ExplanationSection},
    src_ref::Vector{String},
    lim_ref::Vector{String},
)
    sc = kctx.analysis_scope
    # section status の要約（新しい事実を追加しない）
    flagged = [
        k for k in KEEN_OUTPUT_SECTION_ORDER if
        k != "executive_summary" && sections[k].status === :insufficient_evidence
    ]
    high_warn = [w for w in kctx.warnings if w.severity in (:error, :warning, :blocking)]

    claims = EvidenceClaim[EvidenceClaim(;
        claim_id = "exec.overview",
        text = "$(sc.country)（$(sc.sample_start)〜$(sc.sample_end)、$(sc.mode)）の Keen 実証分析を、" *
               "観測・測定・推定・モデル出力・診断proxy・感応度・限界に分離して評価した。",
        epistemic_status = :measured,
        source_ids = copy(src_ref),
    ),]
    if !isempty(flagged) || !isempty(high_warn)
        codes = join(unique(w.code for w in high_warn), ", ")
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "exec.caution",
                text = "結論を支えられない section: $(isempty(flagged) ? "なし" : join(flagged, ", "))。" *
                       "反映すべき警告: $(isempty(codes) ? "なし" : codes)。" *
                       "これらの section では肯定的結論を示さない。",
                epistemic_status = :limitation,
                source_ids = copy(lim_ref),
            ),
        )
    end
    ExplanationSection(:available, claims, String[])
end

# section の全 claim が参照する source id を registry entry へ解決（重複排除・登録済のみ）
function _keen_collect_source_references(
    sections::Dict{String, ExplanationSection},
    sources::Dict{String, EvidenceSource},
)
    seen = String[]
    refs = EvidenceSource[]
    for key in KEEN_OUTPUT_SECTION_ORDER
        for cl in sections[key].claims
            for id in cl.source_ids
                (id in seen) && continue
                haskey(sources, id) || continue
                push!(seen, id)
                push!(refs, sources[id])
            end
        end
    end
    refs
end

function _keen_reproducibility(kctx::KeenEmpiricalContext, audience::Symbol, detail::Symbol)
    m = kctx.measurement
    d = Dict{String, Any}(
        "context_contract_version" => kctx.contract_version,
        "output_contract_version" => KEEN_AI_OUTPUT_CONTRACT_VERSION,
        "prompt_version" => kctx.prompt_version,
        "audience" => string(audience),
        "detail" => string(detail),
        "country" => kctx.analysis_scope.country,
        "sample_start" => kctx.analysis_scope.sample_start,
        "sample_end" => kctx.analysis_scope.sample_end,
        "mode" => kctx.analysis_scope.mode,
    )
    if m !== nothing
        d["measurement_version"] = m.measurement_version
        d["calibration_version"] = m.calibration_version
        d["validation_version"] = m.validation_version
        d["diagnostic_version"] = m.diagnostic_version
        d["seed"] = m.seed
    end
    d
end

# 決定的出力を組み立てる（deterministic / fallback 共通）
function _keen_build_deterministic(
    kctx::KeenEmpiricalContext,
    prompt::String,
    generation_status::Symbol,
    audience::Symbol,
    detail::Symbol,
    extra_warnings::Vector{ExplanationWarning},
)
    # category と epistemic_status を整合させるため、scope / exec は measurement category、
    # interpretation / limitation は limitations category の source のみ参照する。
    _ids_of_category(cat) = sort!([id for (id, s) in kctx.sources if s.category === cat])
    src_ref =
        kctx.measurement === nothing ? _ids_of_category(:measurement) :
        copy(kctx.measurement.source_ids)
    isempty(src_ref) && (
        src_ref =
            isempty(kctx.sources) ? String[] : [first(sort!(collect(keys(kctx.sources))))]
    )
    lim_ref = _ids_of_category(:limitations)
    isempty(lim_ref) && (lim_ref = copy(src_ref))

    sections = Dict{String, ExplanationSection}(
        "analysis_scope" => _keen_scope_section(kctx, src_ref),
        "observed_evidence" => _keen_observed_section(kctx),
        "measurement_and_transformations" => _keen_measurement_section(kctx),
        "calibration_interpretation" => _keen_calibration_section(kctx),
        "validation_assessment" => _keen_validation_section(kctx),
        "regime_assessment" => _keen_regime_section(kctx),
        "sensitivity_and_robustness" => _keen_sensitivity_section(kctx),
        "interpretation_scope" => _keen_interpretation_scope_section(lim_ref),
        "limitations_and_alternatives" => _keen_limitations_section(kctx, lim_ref),
    )
    sections["executive_summary"] =
        _keen_executive_summary(kctx, sections, src_ref, lim_ref)

    all_warnings = vcat(copy(kctx.warnings), extra_warnings)
    refs = _keen_collect_source_references(sections, kctx.sources)

    KeenEmpiricalExplanationOutput(
        KEEN_AI_OUTPUT_CONTRACT_VERSION,
        kctx.prompt_version,
        generation_status,
        audience,
        detail,
        sections["executive_summary"],
        sections["analysis_scope"],
        sections["observed_evidence"],
        sections["measurement_and_transformations"],
        sections["calibration_interpretation"],
        sections["validation_assessment"],
        sections["regime_assessment"],
        sections["sensitivity_and_robustness"],
        sections["interpretation_scope"],
        sections["limitations_and_alternatives"],
        refs,
        _keen_reproducibility(kctx, audience, detail),
        all_warnings,
        prompt,
        _DISCLAIMER_JA,
    )
end

# parser failure warning（fallback 時に必ず付ける。ADR 0005 §7.2）
_keen_parser_failure_warning(reason::String) = ExplanationWarning(;
    code = "OUTPUT_SCHEMA_INVALID",
    severity = :blocking,
    message = "provider 応答の検証に失敗したため決定的 fallback を採用しました: $(reason)",
    affected_sections = collect(KEEN_OUTPUT_SECTION_ORDER),
)

# ===========================================================================
# provider 応答の検証（ADR 0005 §7.1）
# ===========================================================================

# JSON claim を EvidenceClaim へ検証・変換。失敗時は理由文字列を throw する。
function _keen_parse_claim(raw, section::String, sources::Dict{String, EvidenceSource})
    (raw isa AbstractDict) || error("$(section): claim が object ではありません")
    for k in ("claim_id", "text", "epistemic_status", "source_ids")
        haskey(raw, k) || error("$(section): claim に必須 field '$(k)' がありません")
    end
    status = Symbol(String(raw["epistemic_status"]))
    status in KEEN_EPISTEMIC_STATUSES ||
        error("$(section): 不正な epistemic_status '$(status)'")
    sids = raw["source_ids"]
    (sids isa AbstractVector && !isempty(sids)) ||
        error("$(section): source_ids は 1 件以上必要です")
    source_ids = String[]
    for id in sids
        sid = String(id)
        haskey(sources, sid) || error("$(section): 未登録の source_id '$(sid)'")
        # category と epistemic_status の整合（§7.1-5）
        expected = get(_KEEN_CATEGORY_STATUS, sources[sid].category, nothing)
        expected === nothing ||
            expected === status ||
            error(
                "$(section): source '$(sid)'（$(sources[sid].category)）と status '$(status)' が不整合",
            )
        push!(source_ids, sid)
    end
    quals = get(raw, "qualifiers", String[])
    qualifiers = quals isa AbstractVector ? String[String(q) for q in quals] : String[]
    EvidenceClaim(
        String(raw["claim_id"]),
        String(raw["text"]),
        status,
        source_ids,
        qualifiers,
    )
end

function _keen_parse_section(raw, section::String, sources::Dict{String, EvidenceSource})
    (raw isa AbstractDict) || error("section '$(section)' が object ではありません")
    haskey(raw, "status") || error("section '$(section)' に status がありません")
    status = Symbol(String(raw["status"]))
    status in KEEN_SECTION_STATUSES ||
        error("section '$(section)' の status '$(status)' が不正です")
    claims_raw = get(raw, "claims", [])
    (claims_raw isa AbstractVector) ||
        error("section '$(section)' の claims が配列ではありません")
    claims = EvidenceClaim[_keen_parse_claim(c, section, sources) for c in claims_raw]
    mf_raw = get(raw, "missing_fields", String[])
    missing_fields =
        mf_raw isa AbstractVector ? String[String(x) for x in mf_raw] : String[]
    ExplanationSection(status, claims, missing_fields)
end

"""
    parse_keen_empirical_response(raw, kctx; audience=:analyst, detail=:standard, prompt="") -> Union{KeenEmpiricalExplanationOutput, Nothing}

provider の raw 応答（JSON 文字列）を ADR 0005 §7.1 の順で検証し、成功時に
`generation_status=:parsed` の [`KeenEmpiricalExplanationOutput`](@ref) を返す。検証に失敗した
場合は `nothing` を返す（呼び出し側が決定的 fallback を採用する）。

Markdown code fence や前後の自由文は暗黙採用しない。source_ids は input registry に存在し、
category と epistemic_status が整合しなければならない。source_references は claim から実際に
参照された registry entry へ再構築し、context の warning と共通免責を必ず付与する。
"""
function parse_keen_empirical_response(
    raw::AbstractString,
    kctx::KeenEmpiricalContext;
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
    prompt::String = "",
)::Union{KeenEmpiricalExplanationOutput, Nothing}
    parsed = try
        JSON3.read(raw, Dict{String, Any})
    catch
        return nothing
    end
    try
        # contract_version と必須 section の存在
        get(parsed, "contract_version", "") == KEEN_AI_OUTPUT_CONTRACT_VERSION ||
            error("contract_version 不一致")
        secs = Dict{String, ExplanationSection}()
        for key in KEEN_OUTPUT_SECTION_ORDER
            haskey(parsed, key) || error("必須 section '$(key)' がありません")
            secs[key] = _keen_parse_section(parsed[key], key, kctx.sources)
        end
        refs = _keen_collect_source_references(secs, kctx.sources)
        return KeenEmpiricalExplanationOutput(
            KEEN_AI_OUTPUT_CONTRACT_VERSION,
            kctx.prompt_version,
            :parsed,
            audience,
            detail,
            secs["executive_summary"],
            secs["analysis_scope"],
            secs["observed_evidence"],
            secs["measurement_and_transformations"],
            secs["calibration_interpretation"],
            secs["validation_assessment"],
            secs["regime_assessment"],
            secs["sensitivity_and_robustness"],
            secs["interpretation_scope"],
            secs["limitations_and_alternatives"],
            refs,
            _keen_reproducibility(kctx, audience, detail),
            copy(kctx.warnings),
            prompt,
            _DISCLAIMER_JA,
        )
    catch
        return nothing
    end
end

# ===========================================================================
# 公開 API（ADR 0005 §4.1）
# ===========================================================================

# context に blocking warning があるか（provider を呼ばず fallback にする）
_keen_has_blocking(kctx::KeenEmpiricalContext) =
    any(w -> w.severity === :blocking, kctx.warnings)

"""
    explain_keen_empirical_result(context::AnalysisContext; audience=:analyst, detail=:standard,
                                  provider=nothing) -> KeenEmpiricalExplanationOutput

`AnalysisContext.keen_empirical` から Keen 実証結果の根拠付き構造化説明を生成する
（ADR 0005 §4）。認識論的性質を分離した必須 section・source 参照・警告・免責を常に含む。

## 動作モード
- `provider === nothing`（既定）: LLM を呼ばず、検証済み context だけから決定的に生成する
  （`generation_status=:deterministic`）。provider 未接続でも単体利用できる。
- `provider` を指定: `build_keen_empirical_prompt` で prompt を生成して provider へ送信し、
  応答を [`parse_keen_empirical_response`](@ref) で検証する。通過すれば `:parsed`、失敗すれば
  parser failure warning を付けて決定的 fallback（`:fallback`）へ落とす。context に
  `blocking` warning がある場合は provider を呼ばず fallback にする（§5）。

`keen_empirical` が `nothing` の場合は `ArgumentError` を送出する。
"""
function explain_keen_empirical_result(
    context::AnalysisContext;
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
    provider::Union{AbstractLLMProvider, Nothing} = nothing,
    max_tokens::Int = 3000,
    temperature::Float64 = 0.2,
)::KeenEmpiricalExplanationOutput
    kctx = context.keen_empirical
    isnothing(kctx) && throw(
        ArgumentError(
            "explain_keen_empirical_result requires keen_empirical in AnalysisContext. " *
            "実証層成果物から KeenEmpiricalContext を構築して設定してください。",
        ),
    )

    prompt = build_keen_empirical_prompt(context; audience = audience, detail = detail)

    # provider 未接続: 決定的出力
    provider === nothing && return _keen_build_deterministic(
        kctx,
        prompt,
        :deterministic,
        audience,
        detail,
        ExplanationWarning[],
    )

    # blocking warning: provider を呼ばず fallback
    if _keen_has_blocking(kctx)
        return _keen_build_deterministic(
            kctx,
            prompt,
            :fallback,
            audience,
            detail,
            [_keen_parser_failure_warning("context に blocking warning があります")],
        )
    end

    # provider 呼び出し → 検証 → parsed / fallback
    response = try
        complete_from_prompt(
            provider,
            prompt;
            max_tokens = max_tokens,
            temperature = temperature,
        )
    catch e
        return _keen_build_deterministic(
            kctx,
            prompt,
            :fallback,
            audience,
            detail,
            [_keen_parser_failure_warning("provider 呼び出しに失敗しました: $(e)")],
        )
    end

    parsed = parse_keen_empirical_response(
        response.content,
        kctx;
        audience = audience,
        detail = detail,
        prompt = prompt,
    )
    parsed === nothing || return parsed

    _keen_build_deterministic(
        kctx,
        prompt,
        :fallback,
        audience,
        detail,
        [
            _keen_parser_failure_warning(
                "応答 JSON が schema / source / 安全性検証を通過しませんでした",
            ),
        ],
    )
end

# ===========================================================================
# JSON 化（to_dict）
# ===========================================================================

to_dict(c::EvidenceClaim) = Dict{String, Any}(
    "claim_id" => c.claim_id,
    "text" => c.text,
    "epistemic_status" => string(c.epistemic_status),
    "source_ids" => copy(c.source_ids),
    "qualifiers" => copy(c.qualifiers),
)

to_dict(s::ExplanationSection) = Dict{String, Any}(
    "status" => string(s.status),
    "claims" => Any[to_dict(c) for c in s.claims],
    "missing_fields" => copy(s.missing_fields),
)

"""
    to_dict(out::KeenEmpiricalExplanationOutput) -> Dict{String, Any}

`KeenEmpiricalExplanationOutput` を JSON 化可能な `Dict` へ変換する。section は表示順で保持し、
`source_references` は claim から参照された registry entry のみを含む。
"""
function to_dict(out::KeenEmpiricalExplanationOutput)
    d = Dict{String, Any}(
        "contract_version" => out.contract_version,
        "prompt_version" => out.prompt_version,
        "generation_status" => string(out.generation_status),
        "audience" => string(out.audience),
        "detail" => string(out.detail),
        "source_references" => Any[to_dict(s) for s in out.source_references],
        "reproducibility" => out.reproducibility,
        "warnings" => Any[to_dict(w) for w in out.warnings],
        "disclaimer" => out.disclaimer,
    )
    for key in KEEN_OUTPUT_SECTION_ORDER
        d[key] = to_dict(_keen_section(out, key))
    end
    d
end

"""
    to_json(out::KeenEmpiricalExplanationOutput) -> String

`KeenEmpiricalExplanationOutput` を JSON 文字列へ変換する。
"""
to_json(out::KeenEmpiricalExplanationOutput) = JSON3.write(to_dict(out))
