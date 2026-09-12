# financial_instability_holdout.jl: 2026-09 financial-instability live holdout の
# 構造化診断（Issue #260 Part D）。
#
# Part A（src/scenarios/long_rate_funding_shock.jl）・Part B
# （src/data/financial_stress_provider.jl・src/analysis/financial_stress_diagnostics.jl）の
# 出力から、`trigger_state`・`weak_credit_state`・`funding_state`・
# `broad_conditions_state`・`model_amplification_state`・`minsky_diagnostic_state`の
# 6次元と、versioned rule-based な `overall_status` を構造化する。
#
# 対象外（Issue #260。本ファイルが徹底する制約）:
#   - 長期金利上昇を自動的にMinsky momentと判定しない（`overall_status = :confirmed` は
#     trigger 単独では成立しない。§「overall assessment」参照）。
#   - crisis / recession probability・投資助言・売買シグナルを出力しない。
#   - 2026-09データを使ったparameter tuningを行わない（`model_amplification_state`・
#     `minsky_diagnostic_state` は**既存の検証・診断capabilityの引用**であり、
#     2026-09データに対する新規のモデル実行・較正ではない。§「静的citation」参照）。
#   - missing / stale / unavailable dataをfalse/zeroへ変換しない
#     （dimension単位で `:insufficient_data` を返す）。
#
# 設計契約: docs/examples/financial_instability_holdout_demo.md・docs/data/financial_stress.md

# ------------------------------------------------------------
# バージョン・語彙
# ------------------------------------------------------------

"本ファイルの構造・フィールドの version。"
const FINANCIAL_INSTABILITY_HOLDOUT_VERSION = "financial-instability-holdout/1.0.0"

"閾値の版（後続issueでの較正を想定した versioned constant。#260は2026-09データを閾値較正に使わない）。"
const FINANCIAL_INSTABILITY_RULE_VERSION = "financial-instability-rule/1.0.0"

"""
    FINANCIAL_INSTABILITY_STATUSES

dimension単位・overall単位で共通の status 語彙（Issue #260 Part D）。`:insufficient_data`
は「データが無く判定できない」ことを表し、`:not_supported`（「判定できて、支持されない」）
と区別する（missing/stale/unavailableをfalse/zeroへ変換しない、という対象外事項の
帰結）。
"""
const FINANCIAL_INSTABILITY_STATUSES =
    (:insufficient_data, :not_supported, :watch, :confirmed)

"status の順序（`:confirmed` が最強）。dimension間の集約に用いる。"
const _FINANCIAL_INSTABILITY_STATUS_RANK =
    Dict(:insufficient_data => 0, :not_supported => 1, :watch => 2, :confirmed => 3)

_fih_status_rank(s::Symbol)::Int = _FINANCIAL_INSTABILITY_STATUS_RANK[s]

# ------------------------------------------------------------
# 閾値（暫定既定値。較正は別issue、Issue #260 対象外事項）
# ------------------------------------------------------------

"""
    FinancialInstabilityThresholds

dimension別 status を決める閾値（Issue #260 Part D）。**全て暫定既定値**であり、
2026-09の観測に基づいて事後選択していない（丸めた値を経済的な目安として置く。
`version` とともに明示的に記録・追跡する named constant）。較正は別issueで行う。

## フィールド
- `trigger_watch_bps` / `trigger_confirmed_bps::Float64`: `long_nominal_yield_shift_bps`
  の絶対値がこれを超えると `:watch`/`:confirmed`（既定 `25.0`/`50.0`）。
- `weak_credit_watch_bps` / `weak_credit_confirmed_bps::Float64`:
  `ccc_minus_broad_hy_oas_bp` の `from_date→to_date` の拡大幅（既定 `30.0`/`75.0`）。
- `funding_watch_bps` / `funding_confirmed_bps::Float64`: `sofr`/`tgcr` の `iorb` 対比
  乖離の絶対値（既定 `10.0`/`25.0`）。
- `version::String`
"""
Base.@kwdef struct FinancialInstabilityThresholds
    trigger_watch_bps::Float64 = 25.0
    trigger_confirmed_bps::Float64 = 50.0
    weak_credit_watch_bps::Float64 = 30.0
    weak_credit_confirmed_bps::Float64 = 75.0
    funding_watch_bps::Float64 = 10.0
    funding_confirmed_bps::Float64 = 25.0
    version::String = FINANCIAL_INSTABILITY_RULE_VERSION
end

function _fih_magnitude_status(
    value::Union{Float64, Missing},
    watch::Float64,
    confirmed::Float64,
)::Symbol
    value === missing && return :insufficient_data
    av = abs(value)
    av >= confirmed && return :confirmed
    av >= watch && return :watch
    return :not_supported
end

# ------------------------------------------------------------
# trigger_state
# ------------------------------------------------------------

"""
    TriggerState

長期金利repricing（Issue #260 Part D の `trigger_state`）。`long_rate_shift_components`
（src/analysis/financial_stress_diagnostics.jl）の出力をそのまま保持し、
`long_nominal_yield_shift_bps` の絶対値で `label` を決める。
"""
struct TriggerState
    from_date::String
    to_date::String
    long_nominal_yield_shift_bps::Union{Float64, Missing}
    long_real_yield_shift_bps::Union{Float64, Missing}
    inflation_compensation_shift_bps::Union{Float64, Missing}
    label::Symbol
end

"""
    trigger_state(dataset, from_date, to_date; thresholds = FinancialInstabilityThresholds())
        -> TriggerState

`dataset`（`FinancialStressRawDataset`）の `:long_nominal_yield` 等から `trigger_state` を
構築する。
"""
function trigger_state(
    dataset::FinancialStressRawDataset,
    from_date::AbstractString,
    to_date::AbstractString;
    thresholds::FinancialInstabilityThresholds = FinancialInstabilityThresholds(),
)::TriggerState
    # `:long_nominal_yield` 等の raw fetch 自体が失敗している場合（status != :ok）、
    # `long_rate_shift_components` は ArgumentError を投げる。holdout artifact 全体を
    # 落とさず、この dimension だけ :insufficient_data として記録する
    # （missing/stale/unavailable を false や 0 へ変換しないことと同じ理由で、例外による
    # 完全停止でもなく、握りつぶした偽装成功でもない、明示的な第三の状態にする）。
    c = try
        long_rate_shift_components(dataset, from_date, to_date)
    catch e
        e isa ArgumentError || rethrow()
        (
            long_nominal_yield_shift_bps = missing,
            long_real_yield_shift_bps = missing,
            inflation_compensation_shift_bps = missing,
        )
    end
    label = _fih_magnitude_status(
        c.long_nominal_yield_shift_bps,
        thresholds.trigger_watch_bps,
        thresholds.trigger_confirmed_bps,
    )
    return TriggerState(
        String(from_date),
        String(to_date),
        c.long_nominal_yield_shift_bps,
        c.long_real_yield_shift_bps,
        c.inflation_compensation_shift_bps,
        label,
    )
end

# ------------------------------------------------------------
# weak_credit_state
# ------------------------------------------------------------

"""
    WeakCreditState

最弱信用層（CCC以下OAS）の水準・広範HYとの乖離拡大（Issue #260 Part D の
`weak_credit_state`）。`label` は `divergence_shift_bps`（`from_date→to_date` の
`ccc_minus_broad_hy_oas_bp` 拡大幅）で決める。「長期金利が高いだけ」では
`weak_credit_state` は動かない（水準ではなく信用spreadの相対乖離を見るため）。
"""
struct WeakCreditState
    from_date::String
    to_date::String
    ccc_oas_latest::Union{Tuple{String, Float64}, Nothing}
    divergence_latest_bps::Union{Tuple{String, Float64}, Nothing}
    divergence_shift_bps::Union{Float64, Missing}
    label::Symbol
end

"""
    weak_credit_state(dataset, from_date, to_date; thresholds = FinancialInstabilityThresholds())
        -> WeakCreditState
"""
function weak_credit_state(
    dataset::FinancialStressRawDataset,
    from_date::AbstractString,
    to_date::AbstractString;
    thresholds::FinancialInstabilityThresholds = FinancialInstabilityThresholds(),
)::WeakCreditState
    # trigger_state と同じ理由（raw fetch 失敗を :insufficient_data として吸収する）。
    spread = _fih_safe_aligned_spread(
        ccc_minus_broad_hy_oas_bp,
        dataset,
        :ccc_oas,
        :broad_hy_oas,
    )
    ccc_series = get(dataset.observations, :ccc_oas, nothing)
    ccc_latest =
        (ccc_series !== nothing && ccc_series.status == :ok) ?
        _fih_latest_value(ccc_series.series) : nothing
    divergence_latest = latest_aligned(spread)
    shift = value_on_date_spread(spread, from_date, to_date)
    label = _fih_magnitude_status(
        shift,
        thresholds.weak_credit_watch_bps,
        thresholds.weak_credit_confirmed_bps,
    )
    return WeakCreditState(
        String(from_date),
        String(to_date),
        ccc_latest,
        divergence_latest,
        shift,
        label,
    )
end

function _fih_latest_value(s::FinancialStressSeries)::Union{Tuple{String, Float64}, Nothing}
    for i in length(s.dates):-1:1
        s.values[i] === missing || return (s.dates[i], s.values[i])
    end
    return nothing
end

"""
    value_on_date_spread(spread::AlignedDailySpread, from_date, to_date) -> Union{Float64,Missing}

`spread`（`AlignedDailySpread`、同日整列済み）の `from_date`→`to_date` の変化（bp）。
どちらかの日付が整列結果に含まれない（片方の原系列が欠測だった）ときは `missing`。
"""
function value_on_date_spread(
    spread::AlignedDailySpread,
    from_date::AbstractString,
    to_date::AbstractString,
)::Union{Float64, Missing}
    from_idx = findfirst(==(from_date), spread.dates)
    to_idx = findfirst(==(to_date), spread.dates)
    (from_idx === nothing || to_idx === nothing) && return missing
    return spread.values[to_idx] - spread.values[from_idx]
end

# ------------------------------------------------------------
# funding_state
# ------------------------------------------------------------

"""
    FundingState

secured funding市場の政策アンカーからの乖離（Issue #260 Part D の `funding_state`）。
`label` は SOFR・TGCRいずれかの `iorb` 対比乖離（最新日、絶対値）で決める
（大きい方を採用。secured funding dislocationは片方の指標だけに現れうるため）。
"""
struct FundingState
    sofr_minus_iorb_latest_bps::Union{Tuple{String, Float64}, Nothing}
    tgcr_minus_iorb_latest_bps::Union{Tuple{String, Float64}, Nothing}
    label::Symbol
end

"""raw fetch 失敗（status != :ok）を空の整列結果へ吸収する（trigger_state と同じ理由）。"""
function _fih_safe_aligned_spread(
    f::Function,
    dataset::FinancialStressRawDataset,
    a_key::Symbol,
    b_key::Symbol,
)
    try
        return f(dataset)
    catch e
        e isa ArgumentError || rethrow()
        return AlignedDailySpread(a_key, b_key, String[], Float64[], 0, 0, 0)
    end
end

"""
    funding_state(dataset; thresholds = FinancialInstabilityThresholds()) -> FundingState

`from_date`/`to_date` を取らない（水準の乖離そのものが funding stress の指標であり、
`trigger_state`/`weak_credit_state` と異なり「変化幅」ではなく「最新の乖離幅」を見る。
secured funding dislocationは短期間で急変しうるため、期首基準の変化より水準を優先する）。
"""
function funding_state(
    dataset::FinancialStressRawDataset;
    thresholds::FinancialInstabilityThresholds = FinancialInstabilityThresholds(),
)::FundingState
    sofr_iorb =
        latest_aligned(_fih_safe_aligned_spread(sofr_minus_iorb_bp, dataset, :sofr, :iorb))
    tgcr_iorb =
        latest_aligned(_fih_safe_aligned_spread(tgcr_minus_iorb_bp, dataset, :tgcr, :iorb))
    candidates = Union{Float64, Missing}[
        sofr_iorb === nothing ? missing : sofr_iorb[2],
        tgcr_iorb === nothing ? missing : tgcr_iorb[2],
    ]
    label = if all(ismissing, candidates)
        :insufficient_data
    else
        worst = maximum(abs(v) for v in candidates if v !== missing)
        _fih_magnitude_status(
            worst,
            thresholds.funding_watch_bps,
            thresholds.funding_confirmed_bps,
        )
    end
    return FundingState(sofr_iorb, tgcr_iorb, label)
end

# ------------------------------------------------------------
# broad_conditions_state
# ------------------------------------------------------------

"""
    BroadConditionsState

NFCI・SLOOSなど既存のDME catalogにある financial-condition observations（Issue #260
Part D の `broad_conditions_state`）。本ファイルはNFCI/SLOOSの取得方法を知らない
（`src/data/fred.jl`・`src/data/capex_credit_cycle_catalog.jl` が既に持つ経路を呼び出し側
（holdout demo）が使い、水準と日付をそのまま渡す）。閾値による status 判定は行わない
（NFCI/SLOOSは「引き締まっているかどうか」の一次情報であり、Issue #260は本dimensionの
閾値較正を範囲に含めない。`label` は常に `:not_supported`（動かない）と
`:insufficient_data`（欠測）のみを区別する）。
"""
struct BroadConditionsState
    nfci_latest::Union{Tuple{String, Float64}, Nothing}
    sloos_latest::Union{Tuple{String, Float64}, Nothing}
    label::Symbol
end

"""
    broad_conditions_state(; nfci_latest = nothing, sloos_latest = nothing) -> BroadConditionsState

`nfci_latest`・`sloos_latest` は `(date_label, value)` または `nothing`（取得できない場合。
0や欠測を偽装しない）。
"""
function broad_conditions_state(;
    nfci_latest::Union{Tuple{String, Float64}, Nothing} = nothing,
    sloos_latest::Union{Tuple{String, Float64}, Nothing} = nothing,
)::BroadConditionsState
    label =
        (nfci_latest === nothing && sloos_latest === nothing) ? :insufficient_data :
        :not_supported
    return BroadConditionsState(nfci_latest, sloos_latest, label)
end

# ------------------------------------------------------------
# model_amplification_state / minsky_diagnostic_state（静的citation）
# ------------------------------------------------------------

"""
    ModelAmplificationState

`CapexCreditCycleModel` のhistorical validation（Issue #247–#251）が確認した
credit amplification / propagation能力への**静的citation**（Issue #260 Part D）。

**2026-09データに対する新規のモデル実行・較正ではない。** `validate_capex_empirical` は
既知の結果を持つ完了済みhistorical episodeに対してのみ意味を持ち、進行中の
2026-09状況を「episode」として新規に検証することはできない（対象外事項）。
"""
struct ModelAmplificationState
    validated_capability::Bool
    citation::String
    caveats::String
end

"""
    model_amplification_state() -> ModelAmplificationState

固定の citation を返す（引数を取らない。2026-09の観測値に一切依存しない）。
"""
function model_amplification_state()::ModelAmplificationState
    return ModelAmplificationState(
        true,
        "Issue #247–#251（履歴再生候補選定・実行・fit/転換点/信用増幅/波及経路" *
        "validation・robustness・E2E統合）。docs/models/capex_credit_cycle_empirical_strategy.md・" *
        "docs/adr/0018-capex-credit-cycle-empirical-runtime-contract.md 参照。",
        "本状態はCCCモデルの過去のhistorical validation結果への引用であり、2026-09時点の" *
        "CCCモデル実行結果ではない。2026-09データを用いた新規の検証・較正は行っていない" *
        "（Issue #260対象外事項）。validated_capability=trueは「CCCが過去episodeで" *
        "credit amplification機構を検証された」ことを意味し、「2026-09の状況で増幅が" *
        "実際に起きている」ことを意味しない。",
    )
end

"""
    MinskyDiagnosticState

Keen/Minsky系モデルのHedge/Speculative/Ponzi診断機構（ADR 0003・
docs/models/minsky_regime_diagnostics.md）への**静的citation**（Issue #260 Part D）。

**2026-09の実体経済・信用市場データを用いてKeenモデルを較正・実行した結果ではない。**
Keenモデルの資金調達区分診断は個々のシナリオ・シミュレーション実行に対して定義される
（`minsky_diagnostics`、src/analysis/minsky_diagnostics.jl）。2026-09時点で有効な
「現在のKeenモデル状態」をDMEは維持していない。
"""
struct MinskyDiagnosticState
    capability_description::String
    citation::String
    caveats::String
end

"""
    minsky_diagnostic_state() -> MinskyDiagnosticState
"""
function minsky_diagnostic_state()::MinskyDiagnosticState
    return MinskyDiagnosticState(
        "Hedge/Speculative/Ponzi資金調達区分の診断（カバレッジ比率・マージン・regime滞在" *
        "比率・peak/minimum・発散時点）と連続診断指標。",
        "ADR 0003（資金調達区分診断層の分離）・docs/models/minsky_regime_diagnostics.md・" *
        "docs/models/minsky_diagnostics_summary.md 参照。",
        "本状態は診断機構の存在への引用であり、2026-09時点の実際のKeenモデル実行結果では" *
        "ない。DMEは2026-09の市場データで較正した「現在のKeenモデル状態」を維持していない" *
        "（Issue #260対象外事項：2026-09データを使ったparameter tuningを行わない）。",
    )
end

# ------------------------------------------------------------
# overall assessment
# ------------------------------------------------------------

"""
    FinancialInstabilityAssessment

Issue #260 Part D の holdout artifact 本体。6 dimension（`trigger_state`・
`weak_credit_state`・`funding_state`・`broad_conditions_state`・
`model_amplification_state`・`minsky_diagnostic_state`）と、versioned rule-based な
`overall_status`・`overall_evidence`（dimension別根拠）を保持する。

`overall_status` は `trigger_state.label` 単独では `:confirmed` にならない（受け入れ条件
「long-rate上昇だけで`confirmed`にならない」）。§`assess_financial_instability` の
ルールを参照。
"""
struct FinancialInstabilityAssessment
    version::String
    as_of_generated::Union{DateTime, Nothing}
    from_date::String
    to_date::String
    thresholds::FinancialInstabilityThresholds
    trigger_state::TriggerState
    weak_credit_state::WeakCreditState
    funding_state::FundingState
    broad_conditions_state::BroadConditionsState
    model_amplification_state::ModelAmplificationState
    minsky_diagnostic_state::MinskyDiagnosticState
    overall_status::Symbol
    overall_evidence::Vector{String}
    caveats::Vector{String}
end

"""
    FINANCIAL_INSTABILITY_CAVEATS

`FinancialInstabilityAssessment.caveats` へ必ず含める必須記載（Issue #260 対象外事項・
受け入れ条件を反映する）。llm_safety.md の禁止表現チェックリストと併せて適用する。
"""
const FINANCIAL_INSTABILITY_CAVEATS = String[
    "本assessmentは危機確率・景気後退確率の推定ではない。",
    "本assessmentは投資判断・売買シグナルではない。",
    "長期金利の上昇のみでは overall_status = :confirmed にならない（trigger_state に加え" * "weak_credit_state・funding_state・broad_conditions_state のうち複数dimensionの" * "evidenceを要求する）。",
    "model_amplification_state・minsky_diagnostic_stateは既存capabilityへの静的citationで" * "あり、2026-09データを用いた新規のモデル実行・較正ではない。",
    "`:as_of` は実装していない。known_atは監査属性であり「その時点で判断できた」という" * "主張には用いない。",
    "dimension単位で `:insufficient_data` を返す場合があり、missing/stale/unavailableな" * "データを false や 0 へ変換していない。",
]

"""
    assess_financial_instability(dataset, from_date, to_date;
        thresholds = FinancialInstabilityThresholds(),
        nfci_latest = nothing, sloos_latest = nothing,
        generated_at = Dates.now(Dates.UTC))
        -> FinancialInstabilityAssessment

Issue #260 Part D の holdout artifact を構築する。

## overall_status のルール（受け入れ条件「long-rate上昇だけで`confirmed`にならない」を
型で強制する）

1. `trigger_state.label` が `:insufficient_data` かつ他の全dimensionも
   `:insufficient_data` のとき、`overall_status = :insufficient_data`。
2. それ以外で `trigger_state.label ∈ (:not_supported, :insufficient_data)` のとき、
   `overall_status = :not_supported`（trigger無しでは`:watch`/`:confirmed`にしない。
   trigger_stateが本Issueの前提となる長期金利repricingそのものであるため）。
3. `trigger_state.label ∈ (:watch, :confirmed)` のとき、`weak_credit_state`・
   `funding_state`・`broad_conditions_state` のうち `:watch` 以上の件数を数える。
   - 2件以上 → `overall_status = :confirmed`
   - 1件 → `overall_status = :watch`
   - 0件 → `overall_status = :not_supported`（長期金利は動いたが他に証拠が無い）

`overall_evidence` にはどのdimensionが根拠となったかを記録する。`model_amplification_state`・
`minsky_diagnostic_state` は overall_status の算出に使わない（静的citationであり、
2026-09固有の証拠ではないため）。ただし artifact には必ず含め、参照可能にする。
"""
function assess_financial_instability(
    dataset::FinancialStressRawDataset,
    from_date::AbstractString,
    to_date::AbstractString;
    thresholds::FinancialInstabilityThresholds = FinancialInstabilityThresholds(),
    nfci_latest::Union{Tuple{String, Float64}, Nothing} = nothing,
    sloos_latest::Union{Tuple{String, Float64}, Nothing} = nothing,
    generated_at::Union{DateTime, Nothing} = Dates.now(Dates.UTC),
)::FinancialInstabilityAssessment
    trigger = trigger_state(dataset, from_date, to_date; thresholds = thresholds)
    weak_credit = weak_credit_state(dataset, from_date, to_date; thresholds = thresholds)
    funding = funding_state(dataset; thresholds = thresholds)
    broad = broad_conditions_state(; nfci_latest = nfci_latest, sloos_latest = sloos_latest)
    amplification = model_amplification_state()
    minsky = minsky_diagnostic_state()

    supporting = [
        (:weak_credit_state, weak_credit.label),
        (:funding_state, funding.label),
        (:broad_conditions_state, broad.label),
    ]
    n_supporting =
        count(pair -> _fih_status_rank(pair[2]) >= _fih_status_rank(:watch), supporting)
    evidence = String[]
    push!(evidence, "trigger_state=$(trigger.label)")
    for (name, label) in supporting
        _fih_status_rank(label) >= _fih_status_rank(:watch) &&
            push!(evidence, "$(name)=$(label)")
    end

    overall_status =
        if trigger.label == :insufficient_data &&
           all(l -> l == :insufficient_data, last.(supporting))
            :insufficient_data
        elseif trigger.label in (:not_supported, :insufficient_data)
            :not_supported
        elseif n_supporting >= 2
            :confirmed
        elseif n_supporting == 1
            :watch
        else
            :not_supported
        end

    return FinancialInstabilityAssessment(
        FINANCIAL_INSTABILITY_HOLDOUT_VERSION,
        generated_at,
        String(from_date),
        String(to_date),
        thresholds,
        trigger,
        weak_credit,
        funding,
        broad,
        amplification,
        minsky,
        overall_status,
        evidence,
        copy(FINANCIAL_INSTABILITY_CAVEATS),
    )
end

# ------------------------------------------------------------
# シリアライズ
# ------------------------------------------------------------

_fih_dict_tuple(t::Union{Tuple{String, Float64}, Nothing}) =
    t === nothing ? nothing : Dict{String, Any}("date" => t[1], "value" => t[2])
_fih_dict_float(v::Union{Float64, Missing}) = v === missing ? nothing : v

function _fih_trigger_to_dict(s::TriggerState)::Dict{String, Any}
    return Dict{String, Any}(
        "from_date" => s.from_date,
        "to_date" => s.to_date,
        "long_nominal_yield_shift_bps" => _fih_dict_float(s.long_nominal_yield_shift_bps),
        "long_real_yield_shift_bps" => _fih_dict_float(s.long_real_yield_shift_bps),
        "inflation_compensation_shift_bps" =>
            _fih_dict_float(s.inflation_compensation_shift_bps),
        "label" => String(s.label),
    )
end

function _fih_weak_credit_to_dict(s::WeakCreditState)::Dict{String, Any}
    return Dict{String, Any}(
        "from_date" => s.from_date,
        "to_date" => s.to_date,
        "ccc_oas_latest" => _fih_dict_tuple(s.ccc_oas_latest),
        "divergence_latest_bps" => _fih_dict_tuple(s.divergence_latest_bps),
        "divergence_shift_bps" => _fih_dict_float(s.divergence_shift_bps),
        "label" => String(s.label),
    )
end

function _fih_funding_to_dict(s::FundingState)::Dict{String, Any}
    return Dict{String, Any}(
        "sofr_minus_iorb_latest_bps" => _fih_dict_tuple(s.sofr_minus_iorb_latest_bps),
        "tgcr_minus_iorb_latest_bps" => _fih_dict_tuple(s.tgcr_minus_iorb_latest_bps),
        "label" => String(s.label),
    )
end

function _fih_broad_to_dict(s::BroadConditionsState)::Dict{String, Any}
    return Dict{String, Any}(
        "nfci_latest" => _fih_dict_tuple(s.nfci_latest),
        "sloos_latest" => _fih_dict_tuple(s.sloos_latest),
        "label" => String(s.label),
    )
end

function _fih_amplification_to_dict(s::ModelAmplificationState)::Dict{String, Any}
    return Dict{String, Any}(
        "validated_capability" => s.validated_capability,
        "citation" => s.citation,
        "caveats" => s.caveats,
    )
end

function _fih_minsky_to_dict(s::MinskyDiagnosticState)::Dict{String, Any}
    return Dict{String, Any}(
        "capability_description" => s.capability_description,
        "citation" => s.citation,
        "caveats" => s.caveats,
    )
end

function _fih_thresholds_to_dict(t::FinancialInstabilityThresholds)::Dict{String, Any}
    return Dict{String, Any}(
        "trigger_watch_bps" => t.trigger_watch_bps,
        "trigger_confirmed_bps" => t.trigger_confirmed_bps,
        "weak_credit_watch_bps" => t.weak_credit_watch_bps,
        "weak_credit_confirmed_bps" => t.weak_credit_confirmed_bps,
        "funding_watch_bps" => t.funding_watch_bps,
        "funding_confirmed_bps" => t.funding_confirmed_bps,
        "version" => t.version,
    )
end

"""
    financial_instability_assessment_to_dict(a::FinancialInstabilityAssessment) -> Dict{String,Any}

`a` をJSONシリアライズ可能な `Dict` へ変換する（Issue #260 Part D）。`identity_hash` は
`as_of_generated`（実行時刻、volatile）を除いた内容のsha256であり、同じ入力
（`dataset`・`from_date`・`to_date`・`thresholds`・`nfci_latest`・`sloos_latest`）から
常に同じ値になる（受け入れ条件「同じdata snapshot + model/parameter/rule versionから
同じartifactを生成する」）。
"""
function financial_instability_assessment_to_dict(
    a::FinancialInstabilityAssessment,
)::Dict{String, Any}
    body = Dict{String, Any}(
        "version" => a.version,
        "from_date" => a.from_date,
        "to_date" => a.to_date,
        "thresholds" => _fih_thresholds_to_dict(a.thresholds),
        "trigger_state" => _fih_trigger_to_dict(a.trigger_state),
        "weak_credit_state" => _fih_weak_credit_to_dict(a.weak_credit_state),
        "funding_state" => _fih_funding_to_dict(a.funding_state),
        "broad_conditions_state" => _fih_broad_to_dict(a.broad_conditions_state),
        "model_amplification_state" =>
            _fih_amplification_to_dict(a.model_amplification_state),
        "minsky_diagnostic_state" => _fih_minsky_to_dict(a.minsky_diagnostic_state),
        "overall_status" => String(a.overall_status),
        "overall_evidence" => a.overall_evidence,
        "caveats" => a.caveats,
    )
    identity_hash = "sha256:" * sha256_hex_of_canonical(body)
    return merge(
        body,
        Dict{String, Any}(
            "as_of_generated" =>
                a.as_of_generated === nothing ? nothing :
                Dates.format(a.as_of_generated, dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"),
            "identity_hash" => identity_hash,
        ),
    )
end

"""
    save_financial_instability_assessment(path, a::FinancialInstabilityAssessment) -> path

`financial_instability_assessment_to_dict(a)` をpretty-printed JSONとして `path` へ書き出す。
"""
function save_financial_instability_assessment(
    path::AbstractString,
    a::FinancialInstabilityAssessment,
)::String
    open(path, "w") do io
        JSON3.pretty(io, financial_instability_assessment_to_dict(a))
    end
    return String(path)
end
