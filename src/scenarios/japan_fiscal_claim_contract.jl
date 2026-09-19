# japan_fiscal_claim_contract.jl: #274 の capability findings を downstream（#275 の scenario
# schema・#276 の result artifact・Market Analyzer consumer）へ lossless に伝播するための
# claim-level / coverage 契約（Issue #285 / Phase 3）。
#
# #274 は「どの scenario family をどのモデルでどこまで表現できるか」を確定した。本ファイルは
# その結論を **artifact と consumer が守るべき規則** へ翻訳する。
#
# 設計方針（Issue #285 受け入れ条件）:
#   - `claim_level` ごとに、artifact が主張してよい診断（peak / onset / duration 等）と、
#     数値系列に付けなければならない意味づけ（`numeric_semantics`）を機械可読に固定する。
#   - 現在の 55 セルに `claim_level = :magnitude` が 0 件であることを invariant として検査する。
#   - representability（表現可能性）と coverage（概念・出力・チャネルの被覆）を別々に追跡する。
#   - family 名だけを見て「全チャネルをモデル化した」と解釈できないよう、family ごとの
#     因果チャネルと被覆状況を宣言する（F1 の成長・F3 の JGB 吸収・F5 の sovereign leg）。
#   - 未較正モデルの数値を日本固有の magnitude として提示させない。
#   - 将来の日本較正で `claim_level` を上げる条件と version 規則を先に固定し、consumer 側の
#     暗黙昇格を禁じる。
#
# 本ファイルは**宣言と検証のみ**であり、scenario catalog（#275）・adapter / runner（#276）・
# consumer UI は実装しない。モデル方程式も #274 の registry も変更しない。
#
# 依存: scenarios/japan_fiscal_capability.jl（#274 の registry・語彙・照会 API）。
#
# 設計契約:
#   docs/architecture/japan_fiscal_claim_level_contract.md
#   docs/adr/0021-japan-fiscal-claim-level-contract.md

# ===========================================================================
# 契約 version と固定語彙
# ===========================================================================

"""
claim-level / coverage 契約の version。`JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION`（#274）とは
独立に上げられるが、`claim_level` の上限を緩める変更は両方の version 更新を要する
（[`JAPAN_FISCAL_CLAIM_UPGRADE_RULE`](@ref)）。
"""
const JAPAN_FISCAL_CLAIM_CONTRACT_VERSION = "japan-fiscal-claim-contract/1.0.0"

"""
result artifact が主張しうる診断の語彙。

`claim_level` ごとに、このうち**どれを主張してよいか**が決まる
（[`JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY`](@ref)）。保持した数値系列そのものの扱いは
`numeric_semantics` が別に定める。
"""
const JAPAN_FISCAL_DIAGNOSTICS = (
    :direction,                   # baseline に対する符号
    :sign_of_delta,               # 各変数の差分の符号
    :relative_ordering,           # 複数変数・複数シナリオ間の前後関係
    :peak,                        # 山（時点と相対的な大きさ）
    :trough,                      # 谷
    :onset,                       # 効果が現れ始める時点
    :duration,                    # 効果が続く期間
    :recovery,                    # baseline へ戻る時点
    :contribution_decomposition,  # 反実仮想による寄与分解
    :relative_delta,              # baseline 比（比率）
    :absolute_delta,              # 絶対差
    :level_path,                  # 水準経路そのもの
)

"""
artifact が保持する数値系列に付けなければならない意味づけ。

- `:none` … 数値系列を保持しない（実行しない）
- `:model_unit_relative` … モデル単位の相対値。baseline との差の符号のみが意味を持つ
- `:normalized_deviation` … baseline で正規化した偏差。時間形状の比較に使える
- `:japan_magnitude` … 日本の量として提示してよい（`claim_level = :magnitude` のときのみ）
"""
const JAPAN_FISCAL_NUMERIC_SEMANTICS =
    (:none, :model_unit_relative, :normalized_deviation, :japan_magnitude)

"""
較正の地理。`calibration_basis`（#274）から一意に決まる派生属性。

- `:jp` … 日本データで較正済み（現時点で該当するモデルは無い）
- `:us` … 米国データで較正済み（CCC）
- `:none` … 較正・推定を持たない（教科書パラメータ・手入力係数）
"""
const JAPAN_FISCAL_CALIBRATION_GEOGRAPHIES = (:jp, :us, :none)

"""
family の因果チャネルの被覆状況。

- `:covered` … その family の採用モデルの少なくとも 1 つがこのチャネルを内生的に扱う
- `:partially_covered` … 採用モデルが扱うが、family が求める形（入力・出力・時間軸）を満たさない
- `:unsupported` … 採用モデルのいずれも扱わない
"""
const JAPAN_FISCAL_CHANNEL_STATUSES = (:covered, :partially_covered, :unsupported)

"""
result を読み替えてはならない主張の種類。artifact・API・UI のいずれもこれらを生成しない。
"""
const JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS = (
    :forecast,
    :probability,
    :crisis_probability,
    :default_probability,
    :japan_realized_magnitude,
    :observed_outcome,
    :investment_recommendation,
    :debt_sustainability_judgment,
)

"downstream handoff requirement の対象。"
const JAPAN_FISCAL_HANDOFF_AUDIENCES = (
    :dme_scenario_schema,   # #275
    :dme_result_artifact,   # #276
    :dme_e2e_fixture,       # #277
    :consumer,              # Market Analyzer #283 / #285 / #286
)

"claim 検証で返す違反コード。"
const JAPAN_FISCAL_CLAIM_VIOLATION_CODES = (
    :diagnostic_not_permitted,
    :numeric_semantics_exceeds_claim,
    :magnitude_without_japan_calibration,
    :unsupported_concept_hidden,
    :unsupported_output_hidden,
    :forbidden_claim_kind,
    :family_presented_as_complete,
)

# ===========================================================================
# JapanFiscalClaimLevelSpec
# ===========================================================================

"""
    JapanFiscalClaimLevelSpec

`claim_level` 1 段階の意味論。artifact が主張してよい診断・数値系列の意味づけ・必須 caveat・
consumer 側の規則を保持する。

## フィールド
- `claim_level::Symbol` : `JAPAN_FISCAL_CLAIM_LEVELS` のいずれか
- `display_name::String` / `definition::String`
- `permitted_diagnostics::Vector{Symbol}` : 主張してよい `JAPAN_FISCAL_DIAGNOSTICS`
- `numeric_semantics::Symbol` : 保持する数値系列に付ける意味づけ
- `required_caveats::Vector{String}` : artifact に必ず載せる注意
- `consumer_rules::Vector{String}` : consumer（API・UI）が守る規則
- `doc_ref::String`

`forbidden_diagnostics` はフィールドとして持たず、`JAPAN_FISCAL_DIAGNOSTICS` の補集合として
導出する（[`japan_fiscal_forbidden_diagnostics`](@ref)）。二重保持による食い違いを避ける。
"""
struct JapanFiscalClaimLevelSpec
    claim_level::Symbol
    display_name::String
    definition::String
    permitted_diagnostics::Vector{Symbol}
    numeric_semantics::Symbol
    required_caveats::Vector{String}
    consumer_rules::Vector{String}
    doc_ref::String
end

function JapanFiscalClaimLevelSpec(;
    claim_level::Symbol,
    display_name::String,
    definition::String,
    numeric_semantics::Symbol,
    permitted_diagnostics::Vector{Symbol} = Symbol[],
    required_caveats::Vector{String} = String[],
    consumer_rules::Vector{String} = String[],
    doc_ref::String = "docs/architecture/japan_fiscal_claim_level_contract.md",
)
    _jf_check(claim_level, JAPAN_FISCAL_CLAIM_LEVELS, "claim_level")
    _jf_check(numeric_semantics, JAPAN_FISCAL_NUMERIC_SEMANTICS, "numeric_semantics")
    _jf_check_subset(permitted_diagnostics, JAPAN_FISCAL_DIAGNOSTICS, "diagnostic")
    if claim_level === :none
        isempty(permitted_diagnostics) || throw(
            ArgumentError(
                "claim_level=:none は診断を主張できません（permitted_diagnostics=$(permitted_diagnostics)）",
            ),
        )
        numeric_semantics === :none || throw(
            ArgumentError(
                "claim_level=:none は numeric_semantics=:none でなければなりません（実値: $(repr(numeric_semantics))）",
            ),
        )
    else
        isempty(permitted_diagnostics) && throw(
            ArgumentError(
                "claim_level=$(repr(claim_level)) は少なくとも 1 つの診断を主張できなければなりません",
            ),
        )
    end
    if numeric_semantics === :japan_magnitude && claim_level !== :magnitude
        throw(
            ArgumentError(
                "numeric_semantics=:japan_magnitude は claim_level=:magnitude のときのみ許されます（実値: $(repr(claim_level))）",
            ),
        )
    end
    return JapanFiscalClaimLevelSpec(
        claim_level,
        display_name,
        definition,
        permitted_diagnostics,
        numeric_semantics,
        required_caveats,
        consumer_rules,
        doc_ref,
    )
end

"""
    JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY

`claim_level` 4 段階の意味論。上位段階は下位段階の `permitted_diagnostics` を包含する
（登録時に検査する）。
"""
const JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY = Dict{Symbol, JapanFiscalClaimLevelSpec}(
    :none => JapanFiscalClaimLevelSpec(;
        claim_level = :none,
        display_name = "主張なし（実行しない）",
        definition = "Phase 3 で実行しない mapping。result artifact を生成しない。",
        numeric_semantics = :none,
        required_caveats = [
            "この (family, model) は Phase 3 で実行対象外である。結果が無いことを『影響が無い』と読み替えない。",
        ],
        consumer_rules = ["この組み合わせを scenario の選択肢として提示しない。"],
    ),
    :direction_only => JapanFiscalClaimLevelSpec(;
        claim_level = :direction_only,
        display_name = "方向のみ",
        definition = "baseline に対する符号（増える / 減る）だけを主張できる。時間形状は主張できない。静学 1 点解のモデル（IS-LM・AD-AS・Mundell-Fleming）と、軌道の時間形状がパラメータに過敏なモデル（Keen）が該当する。",
        permitted_diagnostics = [:direction, :sign_of_delta],
        numeric_semantics = :model_unit_relative,
        required_caveats = [
            "数値はモデル単位の相対値であり、日本の量ではない。",
            "静学モデルでは時間経路そのものが存在しない（均衡 1 点のみ）。",
            "Keen では双安定性により軌道の時間形状が初期値とパラメータに過敏であり、時点の主張を支えない。",
        ],
        consumer_rules = [
            "peak / onset / duration / recovery を要求・表示しない。",
            "数値の大きさを比較軸として使わない（符号のみ）。",
            "複数シナリオの「どちらが早いか」を表示しない。",
        ],
    ),
    :direction_and_relative_timing => JapanFiscalClaimLevelSpec(;
        claim_level = :direction_and_relative_timing,
        display_name = "方向と相対的な時間形状",
        definition = "符号に加えて、peak / onset / duration / recovery の**相対的な**順序と時間形状、および反実仮想による寄与分解を主張できる。baseline 比の相対差は正規化偏差として扱う。日本固有の量は主張できない。",
        permitted_diagnostics = [
            :direction,
            :sign_of_delta,
            :relative_ordering,
            :peak,
            :trough,
            :onset,
            :duration,
            :recovery,
            :contribution_decomposition,
            :relative_delta,
        ],
        numeric_semantics = :normalized_deviation,
        required_caveats = [
            "数値は baseline で正規化した偏差であり、日本の実現幅・予測幅ではない。",
            "時点は assumption を置いた四半期を起点とする相対的なものであり、暦上の予測時期ではない。",
            "較正は日本データに基づかない（`calibration_geography` を併記する）。",
        ],
        consumer_rules = [
            "時点は「ショック後 n 期」として表示し、暦日・暦四半期の予測として表示しない。",
            "相対差を「日本の GDP が X% 変化する」と読み替えない。",
            "絶対差・水準経路を主要な結論として表示しない。",
        ],
    ),
    :magnitude => JapanFiscalClaimLevelSpec(;
        claim_level = :magnitude,
        display_name = "日本の量",
        definition = "絶対差・水準経路を日本の量として主張できる。`calibration_basis = :japan_calibrated` の mapping にのみ許される。現在の契約では該当する mapping が 0 件である。",
        permitted_diagnostics = collect(JAPAN_FISCAL_DIAGNOSTICS),
        numeric_semantics = :japan_magnitude,
        required_caveats = [
            "較正の vintage・対象期間・推定手法を併記する。",
            "model-implied counterfactual であり、予測でも観測でもない。",
        ],
        consumer_rules = [
            "日本較正の根拠（較正 Issue・データ vintage）を同時に表示する。",
            "それでも forecast・probability としては表示しない。",
        ],
    ),
)

let
    order = (:none, :direction_only, :direction_and_relative_timing, :magnitude)
    for i in 2:length(order)
        lo = JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY[order[i - 1]].permitted_diagnostics
        hi = JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY[order[i]].permitted_diagnostics
        issubset(Set(lo), Set(hi)) || error(
            "claim_level の permitted_diagnostics が単調でありません: $(order[i-1]) ⊄ $(order[i])",
        )
    end
    Set(keys(JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY)) == Set(JAPAN_FISCAL_CLAIM_LEVELS) || error(
        "JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY が JAPAN_FISCAL_CLAIM_LEVELS と一致しません",
    )
end

"""
    japan_fiscal_claim_level_spec(level::Symbol) -> JapanFiscalClaimLevelSpec

`claim_level` の意味論を返す。
"""
function japan_fiscal_claim_level_spec(level::Symbol)
    haskey(JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY, level) || throw(
        ArgumentError(
            "未登録の claim_level: $(repr(level))（登録済み: $(JAPAN_FISCAL_CLAIM_LEVELS)）",
        ),
    )
    return JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY[level]
end

"""
    japan_fiscal_claim_level_permits(level::Symbol, diagnostic::Symbol) -> Bool

`claim_level` がその診断の主張を許すか。
"""
function japan_fiscal_claim_level_permits(level::Symbol, diagnostic::Symbol)
    _jf_check(diagnostic, JAPAN_FISCAL_DIAGNOSTICS, "diagnostic")
    return diagnostic in japan_fiscal_claim_level_spec(level).permitted_diagnostics
end

"""
    japan_fiscal_forbidden_diagnostics(level::Symbol) -> Vector{Symbol}

`claim_level` が主張できない診断（`JAPAN_FISCAL_DIAGNOSTICS` の補集合）。
"""
function japan_fiscal_forbidden_diagnostics(level::Symbol)
    permitted = Set(japan_fiscal_claim_level_spec(level).permitted_diagnostics)
    return Symbol[d for d in JAPAN_FISCAL_DIAGNOSTICS if !(d in permitted)]
end

"""
    japan_fiscal_calibration_geography(m::JapanFiscalModelMapping) -> Symbol

mapping の較正地理（`JAPAN_FISCAL_CALIBRATION_GEOGRAPHIES`）。`calibration_basis` から
一意に決まる派生属性であり、独立したフィールドとして二重保持しない。
"""
function japan_fiscal_calibration_geography(m::JapanFiscalModelMapping)
    b = m.calibration_basis
    return b === :japan_calibrated ? :jp : b === :non_japan_calibrated ? :us : :none
end

# ===========================================================================
# JapanFiscalChannel（family の因果チャネルと被覆状況）
# ===========================================================================

"""
    JapanFiscalChannel

scenario family が本来含む因果チャネル 1 本と、その被覆状況。

family 名（例「JGB funding-cost ショック」）だけを見ると全チャネルをモデル化したように
見えるため、**何が覆われていないか**を family と同じ粒度で宣言する。

## フィールド
- `channel_id::Symbol` : family 内で一意なチャネル ID
- `family::Symbol` : 所属 family
- `display_name::String` / `description::String`
- `status::Symbol` : `JAPAN_FISCAL_CHANNEL_STATUSES`
- `covered_by::Vector{Symbol}` : このチャネルを扱う採用モデル（`:unsupported` のとき空）
- `limitation::String` : `:partially_covered` / `:unsupported` の内容
- `gap_ids::Vector{String}` : 関連する #274 の gap
- `doc_ref::String`
"""
struct JapanFiscalChannel
    channel_id::Symbol
    family::Symbol
    display_name::String
    description::String
    status::Symbol
    covered_by::Vector{Symbol}
    limitation::String
    gap_ids::Vector{String}
    doc_ref::String
end

function JapanFiscalChannel(;
    channel_id::Symbol,
    family::Symbol,
    display_name::String,
    description::String,
    status::Symbol,
    covered_by::Vector{Symbol} = Symbol[],
    limitation::String = "",
    gap_ids::Vector{String} = String[],
    doc_ref::String = "docs/architecture/japan_fiscal_claim_level_contract.md",
)
    _jf_check(family, JAPAN_FISCAL_SCENARIO_FAMILIES, "scenario family")
    _jf_check(status, JAPAN_FISCAL_CHANNEL_STATUSES, "channel status")
    _jf_check_subset(covered_by, JAPAN_FISCAL_CANDIDATE_MODELS, "model")
    if status === :unsupported
        isempty(covered_by) || throw(
            ArgumentError(
                ":unsupported のチャネルは covered_by が空でなければなりません（channel=$(channel_id), covered_by=$(covered_by)）",
            ),
        )
        isempty(limitation) && throw(
            ArgumentError(
                ":unsupported のチャネルは limitation（覆われていない内容）が必須です（channel=$(channel_id)）",
            ),
        )
    else
        isempty(covered_by) && throw(
            ArgumentError(
                "$(repr(status)) のチャネルは covered_by が空であってはいけません（channel=$(channel_id)）",
            ),
        )
    end
    status === :partially_covered &&
        isempty(limitation) &&
        throw(
            ArgumentError(
                ":partially_covered のチャネルは limitation が必須です（channel=$(channel_id)）",
            ),
        )
    return JapanFiscalChannel(
        channel_id,
        family,
        display_name,
        description,
        status,
        covered_by,
        limitation,
        gap_ids,
        doc_ref,
    )
end

"""
    JAPAN_FISCAL_CHANNEL_REGISTRY

5 family の因果チャネル 25 本。`covered_by` は当該 family の採用モデル
（`adoption != :not_adopted`）に限る（登録時に検査する）。
"""
const JAPAN_FISCAL_CHANNEL_REGISTRY = JapanFiscalChannel[

    # ---- F1 低成長 + 高金利 ----
    JapanFiscalChannel(;
        channel_id = :growth_assumption_transmission,
        family = :low_growth_high_rates,
        display_name = "成長率 assumption の波及",
        description = "低い実質 GDP 成長率という assumption を受けて、産出・投資・金利が応答する経路。",
        status = :unsupported,
        limitation = "GDP 成長率パスを外生入力として受け取るモデルが存在しない。主候補 CCC の baseline は成長率ゼロの定常状態と定義されており、成長regimeそのものを表現しない。",
        gap_ids = ["G-03", "G-12"],
    ),
    JapanFiscalChannel(;
        channel_id = :policy_rate_transmission,
        family = :low_growth_high_rates,
        display_name = "政策金利の波及",
        description = "短期名目政策金利の変化が借入コスト・投資・産出へ波及する経路。",
        status = :covered,
        covered_by = [:capex_credit_cycle, :new_keynesian],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :long_rate_funding_transmission,
        family = :low_growth_high_rates,
        display_name = "長期金利・funding 条件の波及",
        description = "長期金利・funding スプレッドの上昇が民間の実効借入コストへ波及する経路。",
        status = :covered,
        covered_by = [:capex_credit_cycle, :keen],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :term_structure,
        family = :low_growth_high_rates,
        display_name = "期間構造",
        description = "短期金利と長期金利を同時に保持し、イールドカーブの形状変化を表現する経路。",
        status = :unsupported,
        limitation = "期間構造を持つモデルが存在しない。CCC は `policy_rate` と `spread_shock_ex` の 2 スロットを持つが、これは「短期金利 + 加算スプレッド」であり期間構造ではない。",
        gap_ids = ["G-06"],
    ),
    JapanFiscalChannel(;
        channel_id = :sovereign_debt_dynamics,
        family = :low_growth_high_rates,
        display_name = "政府債務動学",
        description = "低成長と高金利が `r − g` を通じて債務残高/GDP・利払費へ効く経路。",
        status = :unsupported,
        limitation = "利付き政府債務ストックを持つモデルが存在しない。債務残高/GDP・利払費・`r − g` 動学のいずれも返らない。",
        gap_ids = ["G-01"],
    ),

    # ---- F2 財政再建 ----
    JapanFiscalChannel(;
        channel_id = :government_spending_multiplier,
        family = :fiscal_consolidation,
        display_name = "政府支出の乗数",
        description = "政府支出の削減が需要・産出・所得へ波及する経路。",
        status = :covered,
        covered_by = [:sim, :islm, :adas, :mundell_fleming],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :taxation,
        family = :fiscal_consolidation,
        display_name = "税の効果",
        description = "増税が可処分所得・消費・産出へ波及する経路。",
        status = :covered,
        covered_by = [:sim, :islm, :adas, :mundell_fleming],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :primary_balance_path,
        family = :fiscal_consolidation,
        display_name = "プライマリーバランスの経路",
        description = "歳出削減・増税が財政収支へ現れる経路。",
        status = :partially_covered,
        covered_by = [:sim],
        limitation = "SIM のみが税収 `T = θ·Y` を内生化し財政収支を出力として返す。IS-LM・AD-AS・Mundell-Fleming では `T` が定額税の入力であり `T − G` は入力の差にすぎない。PB を assumption として与える場合は閉じ変数を固定した逆算が要り、組は一意でない。",
        gap_ids = ["G-07"],
    ),
    JapanFiscalChannel(;
        channel_id = :debt_interest_burden,
        family = :fiscal_consolidation,
        display_name = "債務残高と利払費",
        description = "財政収支の改善が債務残高・利払費を通じて将来の財政余地へ効く経路。",
        status = :unsupported,
        limitation = "利付き政府債務ストックを持つモデルが存在しない。SIM の `H` は無利子の政府貨幣であり国債ではない。",
        gap_ids = ["G-01"],
    ),
    JapanFiscalChannel(;
        channel_id = :external_adjustment,
        family = :fiscal_consolidation,
        display_name = "対外調整（為替・純輸出）",
        description = "財政緊縮が為替・純輸出を通じて産出へ効く経路。",
        status = :partially_covered,
        covered_by = [:mundell_fleming],
        limitation = "開放経済かつ財政を持つモデルは Mundell-Fleming のみで、変動相場・完全資本移動・小国という構造仮定の帰結として財政乗数が恒等的にゼロになる。これはモデル構造の帰結であり日本についての実証的発見ではない。",
        gap_ids = ["G-08"],
    ),

    # ---- F3 金融抑圧 ----
    JapanFiscalChannel(;
        channel_id = :policy_rate_path,
        family = :financial_repression,
        display_name = "名目政策金利の低位維持",
        description = "中央銀行が名目政策金利を政策反応ルールが示す水準より低く据え置く経路。",
        status = :covered,
        covered_by = [:new_keynesian],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :inflation_path,
        family = :financial_repression,
        display_name = "インフレの上昇",
        description = "インフレ目標の引き上げ等によりインフレが上昇する経路。",
        status = :covered,
        covered_by = [:new_keynesian],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :real_rate_derivation,
        family = :financial_repression,
        display_name = "実質金利の負化",
        description = "名目金利とインフレ期待から事前的実質金利 `i − E[π]` が決まる経路。",
        status = :covered,
        covered_by = [:new_keynesian],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :cb_jgb_absorption,
        family = :financial_repression,
        display_name = "中央銀行の JGB 吸収",
        description = "中央銀行の国債買入・保有残高（イールドカーブ・コントロールを含む）が金利と国債市場へ効く経路。",
        status = :unsupported,
        limitation = "中央銀行のバランスシートを持つモデルが存在しない。IS-LM 系の `M` は名目マネーサプライであり資産構成（国債保有残高）ではない。この概念はすべてのモデルで受け取れない。",
        gap_ids = ["G-04"],
    ),
    JapanFiscalChannel(;
        channel_id = :debt_real_value_erosion,
        family = :financial_repression,
        display_name = "政府債務の実質価値圧縮",
        description = "負の実質金利が政府債務の実質価値を圧縮し、家計から政府へ移転が生じる経路。",
        status = :unsupported,
        limitation = "利付き政府債務ストックを持つモデルが存在しないため、圧縮額・移転額のいずれも算出できない。",
        gap_ids = ["G-01"],
    ),

    # ---- F4 高成長 / 生産性ショック ----
    JapanFiscalChannel(;
        channel_id = :productivity_to_output,
        family = :high_growth_productivity,
        display_name = "生産性から産出へ",
        description = "労働生産性・TFP の改善が産出へ波及する経路。",
        status = :covered,
        covered_by = [:solow, :rbc],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :capital_accumulation,
        family = :high_growth_productivity,
        display_name = "資本蓄積",
        description = "生産性改善が投資・資本ストックの移行経路を動かす経路。",
        status = :covered,
        covered_by = [:solow, :rbc],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :growth_regime_change,
        family = :high_growth_productivity,
        display_name = "成長regimeの変化",
        description = "成長『率』そのものが恒久的に変わる経路。",
        status = :partially_covered,
        covered_by = [:solow, :keen],
        limitation = "成長率パラメータを持つのは Solow の `g` と Keen の `α` のみ。RBC の TFP ショックは `ρ < 1` で平均回帰し、AD-AS の `Y_n` は潜在産出の『水準』であって率ではない。CCC は baseline が成長率ゼロの定常状態であり成長regimeを表現しない。",
        gap_ids = ["G-03"],
    ),
    JapanFiscalChannel(;
        channel_id = :price_level_response,
        family = :high_growth_productivity,
        display_name = "物価水準の応答",
        description = "潜在産出の上昇が物価水準へ及ぼす（デフレ方向の）効果。",
        status = :partially_covered,
        covered_by = [:adas],
        limitation = "AD-AS のみが物価を内生化するが静学 1 点解であり、物価『水準』の比較のみでインフレ『率』の経路を返さない。",
        gap_ids = ["G-05"],
    ),
    JapanFiscalChannel(;
        channel_id = :debt_denominator_effect,
        family = :high_growth_productivity,
        display_name = "債務比率の分母効果",
        description = "成長による GDP 拡大が債務残高/GDP を押し下げる経路。",
        status = :unsupported,
        limitation = "政府部門・政府債務ストックを持つ成長モデルが存在しない。Solow・RBC・Keen のいずれも政府を持たない。",
        gap_ids = ["G-01"],
    ),

    # ---- F5 JGB funding-cost ショック ----
    JapanFiscalChannel(;
        channel_id = :private_pass_through,
        family = :jgb_funding_cost,
        display_name = "民間へのパススルー",
        description = "長期金利・funding 条件の上昇が民間企業の実効借入コスト・投資・産出へ波及する経路。",
        status = :covered,
        covered_by = [:capex_credit_cycle, :keen],
        gap_ids = String[],
    ),
    JapanFiscalChannel(;
        channel_id = :sovereign_funding_cost,
        family = :jgb_funding_cost,
        display_name = "政府の調達コスト",
        description = "JGB 利回りの上昇が政府の新規発行・借換コストを押し上げる経路。",
        status = :unsupported,
        limitation = "`:LongRateFundingShock` → `spread_shock_ex` の写像は企業の実効借入コストへの加算であり、政府の調達コストではない。政府部門を持つモデルが金利を持たず、金利を持つモデルが政府を持たない。",
        gap_ids = ["G-01", "G-14"],
    ),
    JapanFiscalChannel(;
        channel_id = :interest_burden_to_fiscal_balance,
        family = :jgb_funding_cost,
        display_name = "利払費から財政収支へ",
        description = "調達コストの上昇が利払費を通じて財政収支・債務動学へ効く経路。",
        status = :unsupported,
        limitation = "利付き政府債務ストックを持つモデルが存在しないため、利払費が定義されない。",
        gap_ids = ["G-01"],
    ),
    JapanFiscalChannel(;
        channel_id = :term_structure_shape,
        family = :jgb_funding_cost,
        display_name = "イールドカーブの形状変化",
        description = "年限ごとに異なる利回り変化（ベア・スティープニング等）を表現する経路。",
        status = :unsupported,
        limitation = "期間構造を持つモデルが存在しない。長期金利は単一の加算スプレッドとしてのみ表現される。",
        gap_ids = ["G-06"],
    ),
    JapanFiscalChannel(;
        channel_id = :jp_observation_supply,
        family = :jgb_funding_cost,
        display_name = "日本の観測系列からの構成",
        description = "10年 JGB 利回り・TONA / GC レポ・日銀政策金利・JGB breakeven から `FundingShockComponents` を構成する経路。",
        status = :unsupported,
        limitation = "financial-stress 観測系列は米国 8 系列のみで、日本の対応系列は未実装。`FundingShockComponents` は観測からではなく明示的 Scenario Assumption として与えるしかない。",
        gap_ids = ["G-15"],
    ),
]

let
    seen = Set{Tuple{Symbol, Symbol}}()
    for c in JAPAN_FISCAL_CHANNEL_REGISTRY
        key = (c.family, c.channel_id)
        key in seen &&
            error("JAPAN_FISCAL_CHANNEL_REGISTRY に重複したチャネルがあります: $(key)")
        push!(seen, key)
        adopted = Set(japan_fiscal_implementation_candidates(c.family))
        bad = setdiff(Set(c.covered_by), adopted)
        isempty(bad) || error(
            "チャネル $(key) の covered_by に family の採用モデル以外が含まれています: $(sort(collect(bad)))（採用: $(sort(collect(adopted)))）",
        )
        known = Set(g.gap_id for g in JAPAN_FISCAL_GAP_REGISTER)
        badgaps = setdiff(Set(c.gap_ids), known)
        isempty(badgaps) || error(
            "チャネル $(key) が未登録の gap_id を参照しています: $(sort(collect(badgaps)))",
        )
    end
    for f in JAPAN_FISCAL_SCENARIO_FAMILIES
        cs = [c for c in JAPAN_FISCAL_CHANNEL_REGISTRY if c.family === f]
        isempty(cs) && error("family=$(f) にチャネルが登録されていません")
        any(c -> c.status === :unsupported, cs) || error(
            "family=$(f) に :unsupported のチャネルがありません。#274 の gap register（全 family が G-01 の影響下にある）と矛盾します。",
        )
    end
end

"""
    japan_fiscal_channels(; family=nothing, status=nothing) -> Vector{JapanFiscalChannel}

因果チャネルを絞り込んで返す。
"""
function japan_fiscal_channels(;
    family::Union{Symbol, Nothing} = nothing,
    status::Union{Symbol, Nothing} = nothing,
)
    family === nothing ||
        _jf_check(family, JAPAN_FISCAL_SCENARIO_FAMILIES, "scenario family")
    status === nothing || _jf_check(status, JAPAN_FISCAL_CHANNEL_STATUSES, "channel status")
    out = JapanFiscalChannel[]
    for c in JAPAN_FISCAL_CHANNEL_REGISTRY
        family === nothing || c.family === family || continue
        status === nothing || c.status === status || continue
        push!(out, c)
    end
    return out
end

"""
    japan_fiscal_channel(family::Symbol, channel_id::Symbol) -> JapanFiscalChannel

1 チャネルを引く。未登録は `ArgumentError`。
"""
function japan_fiscal_channel(family::Symbol, channel_id::Symbol)
    idx = findfirst(
        c -> c.family === family && c.channel_id === channel_id,
        JAPAN_FISCAL_CHANNEL_REGISTRY,
    )
    idx === nothing &&
        throw(ArgumentError("未登録のチャネル: family=$(family), channel_id=$(channel_id)"))
    return JAPAN_FISCAL_CHANNEL_REGISTRY[idx]
end

# ===========================================================================
# JapanFiscalCoverage（artifact が保持する被覆情報）
# ===========================================================================

"""
    JapanFiscalCoverage

1 つの (family, model) について、artifact が保持しなければならない被覆情報一式。

#274 の registry・family 仕様・claim level 仕様・チャネル registry から**導出**する
（手書きの registry を別に持たない）。`japan_fiscal_coverage(family, model)` で構築する。

## フィールド
- `capability_contract_version::String` / `claim_contract_version::String` : 由来する契約の version
- `family::Symbol` / `model::Symbol` / `representability::Symbol` / `adoption::Symbol`
- `claim_level::Symbol` / `numeric_semantics::Symbol`
- `permitted_diagnostics::Vector{Symbol}` / `forbidden_diagnostics::Vector{Symbol}`
- `required_concepts` / `accepted_concepts` / `unsupported_concepts` : assumption 概念の被覆
- `required_outputs` / `produced_outputs` / `unsupported_outputs` : 出力概念の被覆
- `covered_channels` / `uncovered_channels` : 因果チャネルの被覆
- `family_complete::Bool` : family の全概念・全出力・全チャネルを覆うか
- `calibration_basis::Symbol` / `calibration_geography::Symbol`
- `cannot_state::Vector{String}` / `major_caveats::Vector{String}` / `gap_ids::Vector{String}`
"""
struct JapanFiscalCoverage
    capability_contract_version::String
    claim_contract_version::String
    family::Symbol
    model::Symbol
    representability::Symbol
    adoption::Symbol
    claim_level::Symbol
    numeric_semantics::Symbol
    permitted_diagnostics::Vector{Symbol}
    forbidden_diagnostics::Vector{Symbol}
    required_concepts::Vector{Symbol}
    accepted_concepts::Vector{Symbol}
    unsupported_concepts::Vector{Symbol}
    required_outputs::Vector{Symbol}
    produced_outputs::Vector{Symbol}
    unsupported_outputs::Vector{Symbol}
    covered_channels::Vector{Symbol}
    uncovered_channels::Vector{Symbol}
    family_complete::Bool
    calibration_basis::Symbol
    calibration_geography::Symbol
    cannot_state::Vector{String}
    major_caveats::Vector{String}
    gap_ids::Vector{String}
end

"""
    japan_fiscal_coverage(family::Symbol, model::Symbol) -> JapanFiscalCoverage

(family, model) の被覆情報を #274 registry から導出する。`#276` の result artifact は
このレコードの全フィールドを保持する（handoff requirement `H-06`）。
"""
function japan_fiscal_coverage(family::Symbol, model::Symbol)
    m = japan_fiscal_model_mapping(family, model)
    spec = japan_fiscal_family_spec(family)
    cl = japan_fiscal_claim_level_spec(m.claim_level)

    accepted = japan_fiscal_accepted_concepts(m)
    unsupported_concepts = japan_fiscal_unsupported_concepts(family, model)
    unsupported_outputs = japan_fiscal_unsupported_outputs(family, model)

    chans = japan_fiscal_channels(; family = family)
    covered = Symbol[c.channel_id for c in chans if model in c.covered_by]
    uncovered = Symbol[c.channel_id for c in chans if !(model in c.covered_by)]

    complete =
        m.representability === :representable &&
        isempty(unsupported_concepts) &&
        isempty(unsupported_outputs) &&
        isempty(uncovered)

    caveats = String[]
    append!(caveats, cl.required_caveats)
    append!(caveats, m.japan_caveats)

    gaps = sort!(unique(vcat(m.gap_ids, spec.gap_ids)))

    return JapanFiscalCoverage(
        JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        family,
        model,
        m.representability,
        m.adoption,
        m.claim_level,
        cl.numeric_semantics,
        copy(cl.permitted_diagnostics),
        japan_fiscal_forbidden_diagnostics(m.claim_level),
        copy(spec.required_concepts),
        accepted,
        unsupported_concepts,
        copy(spec.required_outputs),
        copy(m.endogenous_outputs),
        unsupported_outputs,
        covered,
        uncovered,
        complete,
        m.calibration_basis,
        japan_fiscal_calibration_geography(m),
        copy(m.cannot_state),
        caveats,
        gaps,
    )
end

"""
    japan_fiscal_coverages(; family=nothing, adoption=nothing) -> Vector{JapanFiscalCoverage}

被覆情報を一括で返す（既定は 55 セル全件）。
"""
function japan_fiscal_coverages(;
    family::Union{Symbol, Nothing} = nothing,
    adoption::Union{Symbol, Nothing} = nothing,
)
    ms = japan_fiscal_model_mappings(; family = family, adoption = adoption)
    return JapanFiscalCoverage[japan_fiscal_coverage(m.family, m.model) for m in ms]
end

# ===========================================================================
# 数値意味づけの順序と禁止主張
# ===========================================================================

const _JF_NUMERIC_SEMANTICS_ORDER = Dict{Symbol, Int}(
    :none => 0,
    :model_unit_relative => 1,
    :normalized_deviation => 2,
    :japan_magnitude => 3,
)

"""
    japan_fiscal_numeric_semantics_rank(s::Symbol) -> Int

数値意味づけの強さ（大きいほど強い主張）。`claim_level` が許す上限との比較に使う。
"""
function japan_fiscal_numeric_semantics_rank(s::Symbol)
    _jf_check(s, JAPAN_FISCAL_NUMERIC_SEMANTICS, "numeric_semantics")
    return _JF_NUMERIC_SEMANTICS_ORDER[s]
end

"""
    JAPAN_FISCAL_FORBIDDEN_CLAIM_REASONS

`JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS` の各主張を禁じる理由。artifact・API・UI のいずれも
これらを生成しない。
"""
const JAPAN_FISCAL_FORBIDDEN_CLAIM_REASONS = Dict{Symbol, String}(
    :forecast => "model-implied counterfactual は予測ではない。assumption を置いたときにモデルが何を返すかであって、将来何が起こるかの主張ではない。",
    :probability => "決定論的なシミュレーションであり確率分布を持たない。シナリオの確からしさを数値化しない。",
    :crisis_probability => "Keen の双安定系は決定論的軌道であり、崩壊経路へ入るかどうかは初期値とパラメータの関数であって危機確率ではない。",
    :default_probability => "デフォルトを内生化したモデルが無く（CCC は非内生化を決定済み）、債務不履行の確率を定義できない。",
    :japan_realized_magnitude => "日本較正済みモデルが存在しないため（G-02）、数値を日本の実現幅として提示できない。",
    :observed_outcome => "model-implied counterfactual を観測された結果として提示しない。observed / assumed / model_implied を分離する。",
    :investment_recommendation => "売買・信用判断へ変換しない。LLM 層の禁止表現と同じ契約。",
    :debt_sustainability_judgment => "利付き政府債務ストックを持つモデルが無く（G-01）、債務残高/GDP・利払費・`r − g` 動学のいずれも返らないため、持続可能性を判断する根拠が無い。",
)

let
    Set(keys(JAPAN_FISCAL_FORBIDDEN_CLAIM_REASONS)) ==
    Set(JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS) || error(
        "JAPAN_FISCAL_FORBIDDEN_CLAIM_REASONS が JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS と一致しません",
    )
end

"""
    japan_fiscal_forbidden_claims() -> Vector{Pair{Symbol,String}}

禁止する主張の種類と理由（宣言順）。
"""
japan_fiscal_forbidden_claims() = Pair{Symbol, String}[
    k => JAPAN_FISCAL_FORBIDDEN_CLAIM_REASONS[k] for k in JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS
]

# ===========================================================================
# claim 検証
# ===========================================================================

"""
    JapanFiscalClaimViolation

`japan_fiscal_validate_claims` が返す違反 1 件。

- `code::Symbol` : `JAPAN_FISCAL_CLAIM_VIOLATION_CODES`
- `detail::String` : 具体的な内容
"""
struct JapanFiscalClaimViolation
    code::Symbol
    detail::String

    function JapanFiscalClaimViolation(code::Symbol, detail::AbstractString)
        _jf_check(code, JAPAN_FISCAL_CLAIM_VIOLATION_CODES, "violation code")
        return new(code, String(detail))
    end
end

"""
    japan_fiscal_validate_claims(family, model; diagnostics, numeric_semantics,
                                 disclosed_unsupported_concepts,
                                 disclosed_unsupported_outputs,
                                 claim_kinds, presented_as_family_complete)
        -> Vector{JapanFiscalClaimViolation}

artifact や consumer が主張しようとしている内容が claim-level / coverage 契約に適合するかを
検証し、違反を列挙する（空ベクトルなら適合）。`#276` の artifact 生成前と `#277` の
negative fixture で用いる。

## キーワード
- `diagnostics::Vector{Symbol}` : 主張する診断（`JAPAN_FISCAL_DIAGNOSTICS`）
- `numeric_semantics::Union{Symbol,Nothing}` : 数値系列に付ける意味づけ
- `disclosed_unsupported_concepts::Union{Vector{Symbol},Nothing}` : artifact が開示した未対応概念
- `disclosed_unsupported_outputs::Union{Vector{Symbol},Nothing}` : artifact が開示した未対応出力
- `claim_kinds::Vector{Symbol}` : 主張の種類（`JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS` に当たると違反）
- `presented_as_family_complete::Bool` : family 完全な結果として提示するか

`disclosed_*` に `nothing` を渡すと「開示していない」とみなし、実際に未対応の概念・出力が
あれば違反になる（silent ignore の検出）。
"""
function japan_fiscal_validate_claims(
    family::Symbol,
    model::Symbol;
    diagnostics::Vector{Symbol} = Symbol[],
    numeric_semantics::Union{Symbol, Nothing} = nothing,
    disclosed_unsupported_concepts::Union{Vector{Symbol}, Nothing} = nothing,
    disclosed_unsupported_outputs::Union{Vector{Symbol}, Nothing} = nothing,
    claim_kinds::Vector{Symbol} = Symbol[],
    presented_as_family_complete::Bool = false,
)
    cov = japan_fiscal_coverage(family, model)
    violations = JapanFiscalClaimViolation[]

    permitted = Set(cov.permitted_diagnostics)
    for d in diagnostics
        _jf_check(d, JAPAN_FISCAL_DIAGNOSTICS, "diagnostic")
        d in permitted || push!(
            violations,
            JapanFiscalClaimViolation(
                :diagnostic_not_permitted,
                "claim_level=$(cov.claim_level) は $(repr(d)) を主張できません（family=$(family), model=$(model)。許容: $(cov.permitted_diagnostics)）",
            ),
        )
    end

    if numeric_semantics !== nothing
        if japan_fiscal_numeric_semantics_rank(numeric_semantics) >
           japan_fiscal_numeric_semantics_rank(cov.numeric_semantics)
            push!(
                violations,
                JapanFiscalClaimViolation(
                    :numeric_semantics_exceeds_claim,
                    "numeric_semantics=$(repr(numeric_semantics)) は claim_level=$(cov.claim_level) の上限 $(repr(cov.numeric_semantics)) を超えています（family=$(family), model=$(model)）",
                ),
            )
        end
        if numeric_semantics === :japan_magnitude && cov.calibration_geography !== :jp
            push!(
                violations,
                JapanFiscalClaimViolation(
                    :magnitude_without_japan_calibration,
                    "calibration_geography=$(repr(cov.calibration_geography)) のモデルの数値を日本の量として提示できません（family=$(family), model=$(model)。gap G-02）",
                ),
            )
        end
    end

    disclosed_c =
        disclosed_unsupported_concepts === nothing ? Symbol[] :
        disclosed_unsupported_concepts
    hidden_c = setdiff(Set(cov.unsupported_concepts), Set(disclosed_c))
    isempty(hidden_c) || push!(
        violations,
        JapanFiscalClaimViolation(
            :unsupported_concept_hidden,
            "未対応の assumption 概念が開示されていません: $(sort(collect(hidden_c)))（family=$(family), model=$(model)）",
        ),
    )

    disclosed_o =
        disclosed_unsupported_outputs === nothing ? Symbol[] : disclosed_unsupported_outputs
    hidden_o = setdiff(Set(cov.unsupported_outputs), Set(disclosed_o))
    isempty(hidden_o) || push!(
        violations,
        JapanFiscalClaimViolation(
            :unsupported_output_hidden,
            "未対応の出力概念が開示されていません: $(sort(collect(hidden_o)))（family=$(family), model=$(model)）",
        ),
    )

    for k in claim_kinds
        if k in JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS
            push!(
                violations,
                JapanFiscalClaimViolation(
                    :forbidden_claim_kind,
                    "$(repr(k)) は生成できません: $(JAPAN_FISCAL_FORBIDDEN_CLAIM_REASONS[k])",
                ),
            )
        end
    end

    if presented_as_family_complete && !cov.family_complete
        push!(
            violations,
            JapanFiscalClaimViolation(
                :family_presented_as_complete,
                "family=$(family) を完全に覆っていない結果を family 完全として提示できません（未対応概念: $(cov.unsupported_concepts)・未対応出力: $(cov.unsupported_outputs)・未被覆チャネル: $(cov.uncovered_channels)）",
            ),
        )
    end

    return violations
end

# ===========================================================================
# claim_level 昇格の version 規則
# ===========================================================================

"""
    JapanFiscalClaimUpgradeRule

`claim_level` の上限を上げる（例: 日本較正の達成により `:magnitude` を解禁する）ときの条件と
version 規則。consumer 側の暗黙昇格を禁じる。

## フィールド
- `rule_id::String`
- `conditions::Vector{String}` : 昇格に必要な条件（すべて満たす）
- `version_bumps::Vector{String}` : 同時に上げる契約 version
- `forbidden::Vector{String}` : 昇格に際して行ってはならないこと
- `doc_ref::String`
"""
struct JapanFiscalClaimUpgradeRule
    rule_id::String
    conditions::Vector{String}
    version_bumps::Vector{String}
    forbidden::Vector{String}
    doc_ref::String
end

"""
    JAPAN_FISCAL_CLAIM_UPGRADE_RULE

`claim_level` 昇格の唯一の規則。将来の日本較正でこの規則を緩める場合は、ADR 0021 の改訂として
のみ行う。
"""
const JAPAN_FISCAL_CLAIM_UPGRADE_RULE = JapanFiscalClaimUpgradeRule(
    "CLAIM-UPGRADE-1",
    [
        "対象 mapping の `calibration_basis` が `:japan_calibrated` へ変わっていること（日本データによる較正・推定が実装され、テストとデモで示されていること）。自己申告では足りない（ADR 0014 と同型）。",
        "較正の対象期間・データ vintage・推定手法・識別仮定が artifact から追跡できること。",
        "`JapanFiscalModelMapping` のコンストラクタ検査（`claim_level = :magnitude` は `calibration_basis = :japan_calibrated` のときのみ）を緩めないこと。",
        "昇格後も `japan_fiscal_validate_claims` が禁止主張（forecast・probability 等）を拒否し続けること。",
    ],
    [
        "`JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION`（#274 の registry を変更するため）",
        "`JAPAN_FISCAL_CLAIM_CONTRACT_VERSION`（consumer が見る claim 意味論が変わるため）",
    ],
    [
        "consumer（Market Analyzer 等）が artifact の `claim_level` を読み替えて昇格させること。`claim_level` は artifact から読む値であり、推論する値ではない。",
        "`calibration_geography` が `:us` / `:none` のまま数値を日本の量として提示すること。",
        "較正の一部（例: 1 つの部門のみ）を根拠に family 全体の `claim_level` を上げること。",
        "契約 version を据え置いたまま `claim_level` を上げること（既存 artifact と新 artifact が同じ version で別の意味を持つ状態を作らない）。",
    ],
    "docs/architecture/japan_fiscal_claim_level_contract.md",
)

# ===========================================================================
# downstream handoff requirements
# ===========================================================================

"""
    JapanFiscalHandoffRequirement

downstream（#275 / #276 / #277 / consumer）が守る要件 1 件。

## フィールド
- `requirement_id::String` : `"H-01"` 形式
- `audience::Symbol` : `JAPAN_FISCAL_HANDOFF_AUDIENCES`
- `requirement::String` : 守るべきこと
- `rationale::String` : 根拠（どの findings に由来するか）
- `verification::String` : どう検証するか
- `gap_ids::Vector{String}`
"""
struct JapanFiscalHandoffRequirement
    requirement_id::String
    audience::Symbol
    requirement::String
    rationale::String
    verification::String
    gap_ids::Vector{String}
end

function JapanFiscalHandoffRequirement(;
    requirement_id::String,
    audience::Symbol,
    requirement::String,
    rationale::String,
    verification::String,
    gap_ids::Vector{String} = String[],
)
    occursin(r"^H-\d{2}$", requirement_id) || throw(
        ArgumentError(
            "requirement_id は \"H-01\" 形式でなければなりません（実値: $(requirement_id)）",
        ),
    )
    _jf_check(audience, JAPAN_FISCAL_HANDOFF_AUDIENCES, "handoff audience")
    return JapanFiscalHandoffRequirement(
        requirement_id,
        audience,
        requirement,
        rationale,
        verification,
        gap_ids,
    )
end

"""
    JAPAN_FISCAL_HANDOFF_REQUIREMENTS

downstream handoff の要件 22 件（`H-01`–`H-22`）。
"""
const JAPAN_FISCAL_HANDOFF_REQUIREMENTS = JapanFiscalHandoffRequirement[

    # ---- #275 scenario schema ----
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-01",
        audience = :dme_scenario_schema,
        requirement = "scenario catalog は family ごとの `required_concepts` / `optional_concepts` / `guardrails` を #274 の registry から引き、独自に再定義しない。",
        rationale = "catalog と capability registry が別々に判定を持つと、片方だけが更新されて食い違う。",
        verification = "catalog の値が `japan_fiscal_family_spec(family)` と一致することをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-02",
        audience = :dme_scenario_schema,
        requirement = "scenario artifact の identity に `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION` と `JAPAN_FISCAL_CLAIM_CONTRACT_VERSION` の両方を含める。",
        rationale = "claim の意味論が変わったときに、既存 artifact と新 artifact を区別できるようにする。",
        verification = "artifact の canonical serialization に両 version が含まれることをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-03",
        audience = :dme_scenario_schema,
        requirement = "assumption の magnitude 未指定と 0 を別の状態として保持する（欠測を 0 へ丸めない）。",
        rationale = "0 は「変化なし」という主張であり、未指定は「assumption を置いていない」である。",
        verification = "未指定の assumption を含む fixture で、serialization 後も欠測が保たれることをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-04",
        audience = :dme_scenario_schema,
        requirement = "assumption に `magnitude_source` を必須とし、`japan_fiscal_magnitude_source_allowed` が `false` を返す値を拒否する。",
        rationale = "FRE のスコアが外部 belief 経由で magnitude へ入る経路を塞ぐ。",
        verification = "`magnitude_source = :external_belief` の assumption が validation error になることをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-05",
        audience = :dme_scenario_schema,
        requirement = "FRE context を Scenario Assumption と別構造で保持し、context のフィールドを magnitude 導出に用いない。",
        rationale = "FRE snapshot の役割は `observed_context_only` である。",
        verification = "FRE context だけを変えた 2 つの scenario が同一の applied model input を生むことをテストする。",
    ),

    # ---- #276 result artifact ----
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-06",
        audience = :dme_result_artifact,
        requirement = "result artifact は `japan_fiscal_coverage(family, model)` の全フィールドを保持する。",
        rationale = "representability と coverage（概念・出力・チャネル）を別々に追跡できるようにする。",
        verification = "artifact の dict が `to_dict(japan_fiscal_coverage(...))` の全キーを含むことをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-07",
        audience = :dme_result_artifact,
        requirement = "artifact 生成前に `japan_fiscal_validate_claims` を実行し、違反があれば artifact を生成しない。",
        rationale = "`claim_level` を超える診断が artifact に混入するのを実行時に止める。",
        verification = "`direction_only` の mapping で peak を要求した場合に違反が返ることをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-08",
        audience = :dme_result_artifact,
        requirement = "保持する数値系列に `numeric_semantics` を付け、`:japan_magnitude` は `calibration_geography = :jp` のときのみ用いる。",
        rationale = "未較正モデルの数値を日本の実現幅として読ませない。",
        verification = "全 55 セルの coverage が `numeric_semantics != :japan_magnitude` であることをテストする。",
        gap_ids = ["G-02"],
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-09",
        audience = :dme_result_artifact,
        requirement = "`unsupported_concepts` / `unsupported_outputs` / `uncovered_channels` を空配列へ落とさない（silent ignore の禁止）。",
        rationale = "受け取れなかった assumption を黙って無視すると、利用者は全概念が効いたと解釈する。",
        verification = "未対応概念を開示しない artifact が `:unsupported_concept_hidden` 違反になることをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-10",
        audience = :dme_result_artifact,
        requirement = "observed（FRE context）/ assumed（Scenario Assumption）/ model_implied（結果）の 3 分類をフィールドで区別する。",
        rationale = "model-implied counterfactual を観測結果として提示しない。",
        verification = "artifact schema で 3 分類が別キーにあることをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-11",
        audience = :dme_result_artifact,
        requirement = "F5 では sovereign leg と private pass-through leg を別フィールドで保持し、sovereign leg が `:unsupported` であることを明示する。",
        rationale = "`:LongRateFundingShock` → `spread_shock_ex` は企業の実効借入コストへの写像であり政府の調達コストではない。",
        verification = "F5 の artifact に sovereign leg の status が含まれ `:unsupported` であることをテストする。",
        gap_ids = ["G-01", "G-14"],
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-12",
        audience = :dme_result_artifact,
        requirement = "`family_complete` を artifact に持たせ、`false` のときは family 名だけの要約を生成しない。",
        rationale = "family 名（例「JGB funding-cost ショック」）だけを見ると全チャネルをモデル化したように読める。",
        verification = "全 55 セルで `family_complete == false` であることをテストし、artifact がこの値を保持することを検証する。",
    ),

    # ---- #277 E2E / fixture ----
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-13",
        audience = :dme_e2e_fixture,
        requirement = "現在の 55 セルに `claim_level = :magnitude` が 0 件であることを E2E でも検査する。",
        rationale = "日本較正が無い状態で magnitude claim が混入していないことを、単体テストとは別の経路でも確認する。",
        verification = "E2E fixture の実行結果に `:magnitude` の coverage が現れないことをテストする。",
        gap_ids = ["G-02"],
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-14",
        audience = :dme_e2e_fixture,
        requirement = "serialization round-trip で `claim_level` と unsupported フィールドが消えないことを検査する。",
        rationale = "JSON 化の過程で空配列や既定値へ潰れると、limitation が consumer へ届かない。",
        verification = "artifact を JSON 化して読み戻し、`claim_level` / `unsupported_concepts` / `unsupported_outputs` / `uncovered_channels` が保持されることをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-15",
        audience = :dme_e2e_fixture,
        requirement = "`direction_only` の mapping に peak / onset / duration を要求する negative fixture を置き、違反が返ることを検査する。",
        rationale = "契約が文書だけでなく実行時に効いていることを示す。",
        verification = "`japan_fiscal_validate_claims` が `:diagnostic_not_permitted` を返すことをテストする。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-16",
        audience = :dme_e2e_fixture,
        requirement = "consumer fixture に `japan_fiscal_downstream_contract()` を含め、Julia 内部型なしで decode できる形で公開する。",
        rationale = "Market Analyzer は Julia 型を import せず versioned artifact のみを consume する。",
        verification = "JSON round-trip で全キーが読めることをテストする。",
    ),

    # ---- consumer（Market Analyzer） ----
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-17",
        audience = :consumer,
        requirement = "`claim_level` を artifact から読み、UI 側で昇格させない。`direction_only` の結果に時間軸チャート・peak / onset / duration を表示しない。",
        rationale = "静学モデルには時間経路が存在せず、Keen の軌道は時間形状がパラメータに過敏である。",
        verification = "consumer fixture の `direction_only` ケースで時間軸の表示要素が無いことを検証する。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-18",
        audience = :consumer,
        requirement = "`unsupported_concepts` / `uncovered_channels` を折りたたんで隠さず、family 名と同じ画面に表示する。",
        rationale = "limitation が別タブ・別ページにあると、family 名だけが独り歩きする。",
        verification = "consumer の情報設計レビューで、limitation が要約と同じ視野に入ることを確認する。",
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-19",
        audience = :consumer,
        requirement = "数値を日本の量として表示しない。`numeric_semantics` に従ったラベル（モデル単位の相対値・正規化偏差）を数値の近くに出す。",
        rationale = "日本較正済みモデルが存在しない（G-02）。",
        verification = "consumer fixture の数値表示に `numeric_semantics` 由来のラベルが付くことを検証する。",
        gap_ids = ["G-02"],
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-20",
        audience = :consumer,
        requirement = "`family_complete = false` の結果を family 完全な結果として見せない。どのチャネルが覆われていないかを明示する。",
        rationale = "F1 は成長チャネル、F3 は JGB 吸収、F5 は sovereign leg が覆われていない。",
        verification = "consumer fixture の各 family で未被覆チャネル名が表示されることを検証する。",
        gap_ids = ["G-01", "G-03", "G-04", "G-14"],
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-21",
        audience = :consumer,
        requirement = "sovereign / private leg と、observed / assumed / model_implied を区別して表示する。",
        rationale = "民間へのパススルーを政府の調達コストとして読ませない。観測と仮定と結果を混ぜない。",
        verification = "consumer fixture で 2 種類の区別が別要素として現れることを検証する。",
        gap_ids = ["G-14"],
    ),
    JapanFiscalHandoffRequirement(;
        requirement_id = "H-22",
        audience = :consumer,
        requirement = "`JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS` のいずれとしても表示しない（forecast・probability・危機確率・投資推奨・債務持続可能性の判断）。",
        rationale = "決定論的な model-implied counterfactual であり、確率でも予測でも助言でもない。",
        verification = "consumer の表示文言レビューと、`japan_fiscal_forbidden_claims()` の一覧との突き合わせを行う。",
        gap_ids = ["G-01"],
    ),
]

let
    ids = [r.requirement_id for r in JAPAN_FISCAL_HANDOFF_REQUIREMENTS]
    length(unique(ids)) == length(ids) || error(
        "JAPAN_FISCAL_HANDOFF_REQUIREMENTS に重複した requirement_id があります: $(ids)",
    )
    known = Set(g.gap_id for g in JAPAN_FISCAL_GAP_REGISTER)
    for r in JAPAN_FISCAL_HANDOFF_REQUIREMENTS
        bad = setdiff(Set(r.gap_ids), known)
        isempty(bad) || error(
            "requirement $(r.requirement_id) が未登録の gap_id を参照しています: $(sort(collect(bad)))",
        )
    end
    for a in JAPAN_FISCAL_HANDOFF_AUDIENCES
        any(r -> r.audience === a, JAPAN_FISCAL_HANDOFF_REQUIREMENTS) ||
            error("audience=$(a) に要件が 1 件もありません")
    end
end

"""
    japan_fiscal_handoff_requirements(; audience=nothing) -> Vector{JapanFiscalHandoffRequirement}

downstream handoff の要件を返す。`audience` で絞り込める。
"""
function japan_fiscal_handoff_requirements(; audience::Union{Symbol, Nothing} = nothing)
    audience === nothing ||
        _jf_check(audience, JAPAN_FISCAL_HANDOFF_AUDIENCES, "handoff audience")
    audience === nothing && return copy(JAPAN_FISCAL_HANDOFF_REQUIREMENTS)
    return JapanFiscalHandoffRequirement[
        r for r in JAPAN_FISCAL_HANDOFF_REQUIREMENTS if r.audience === audience
    ]
end

# ===========================================================================
# 契約全体の invariant（load 時に落とす）
# ===========================================================================

let
    # 現在の capability では `:magnitude` を名乗る mapping が 0 件であり、したがって
    # `:japan_magnitude` の数値意味づけを持つ coverage も 0 件である（G-02）。
    mags = [
        (m.family, m.model) for
        m in JAPAN_FISCAL_MODEL_MAPPINGS if m.claim_level === :magnitude
    ]
    isempty(mags) || error(
        "claim_level=:magnitude の mapping が存在します: $(mags)。日本較正済みモデルは無い（G-02）。" *
        "解禁には JAPAN_FISCAL_CLAIM_UPGRADE_RULE の条件を満たす必要があります。",
    )
    # family ごとに未被覆チャネルが残る（family_complete が真になるセルは無い）。
    for f in JAPAN_FISCAL_SCENARIO_FAMILIES, mo in JAPAN_FISCAL_CANDIDATE_MODELS
        cov = japan_fiscal_coverage(f, mo)
        cov.family_complete && error(
            "family_complete=true の coverage が存在します: (family=$(f), model=$(mo))。" *
            "全 family に :unsupported のチャネルが残るため、現在の契約では成立しません。",
        )
        cov.numeric_semantics === :japan_magnitude && error(
            "numeric_semantics=:japan_magnitude の coverage が存在します: (family=$(f), model=$(mo))",
        )
    end
end

# ===========================================================================
# 機械可読 export（to_dict / to_json）
# ===========================================================================

to_dict(s::JapanFiscalClaimLevelSpec) = Dict{String, Any}(
    "claim_level" => _jf_sym(s.claim_level),
    "display_name" => s.display_name,
    "definition" => s.definition,
    "permitted_diagnostics" => _jf_syms(s.permitted_diagnostics),
    "forbidden_diagnostics" =>
        _jf_syms(japan_fiscal_forbidden_diagnostics(s.claim_level)),
    "numeric_semantics" => _jf_sym(s.numeric_semantics),
    "required_caveats" => copy(s.required_caveats),
    "consumer_rules" => copy(s.consumer_rules),
    "doc_ref" => s.doc_ref,
)

to_dict(c::JapanFiscalChannel) = Dict{String, Any}(
    "channel_id" => _jf_sym(c.channel_id),
    "family" => _jf_sym(c.family),
    "display_name" => c.display_name,
    "description" => c.description,
    "status" => _jf_sym(c.status),
    "covered_by" => _jf_syms(c.covered_by),
    "limitation" => c.limitation,
    "gap_ids" => copy(c.gap_ids),
    "doc_ref" => c.doc_ref,
)

to_dict(c::JapanFiscalCoverage) = Dict{String, Any}(
    "capability_contract_version" => c.capability_contract_version,
    "claim_contract_version" => c.claim_contract_version,
    "family" => _jf_sym(c.family),
    "model" => _jf_sym(c.model),
    "representability" => _jf_sym(c.representability),
    "adoption" => _jf_sym(c.adoption),
    "claim_level" => _jf_sym(c.claim_level),
    "numeric_semantics" => _jf_sym(c.numeric_semantics),
    "permitted_diagnostics" => _jf_syms(c.permitted_diagnostics),
    "forbidden_diagnostics" => _jf_syms(c.forbidden_diagnostics),
    "required_concepts" => _jf_syms(c.required_concepts),
    "accepted_concepts" => _jf_syms(c.accepted_concepts),
    "unsupported_concepts" => _jf_syms(c.unsupported_concepts),
    "required_outputs" => _jf_syms(c.required_outputs),
    "produced_outputs" => _jf_syms(c.produced_outputs),
    "unsupported_outputs" => _jf_syms(c.unsupported_outputs),
    "covered_channels" => _jf_syms(c.covered_channels),
    "uncovered_channels" => _jf_syms(c.uncovered_channels),
    "family_complete" => c.family_complete,
    "calibration_basis" => _jf_sym(c.calibration_basis),
    "calibration_geography" => _jf_sym(c.calibration_geography),
    "cannot_state" => copy(c.cannot_state),
    "major_caveats" => copy(c.major_caveats),
    "gap_ids" => copy(c.gap_ids),
)

to_dict(v::JapanFiscalClaimViolation) =
    Dict{String, Any}("code" => _jf_sym(v.code), "detail" => v.detail)

to_dict(r::JapanFiscalHandoffRequirement) = Dict{String, Any}(
    "requirement_id" => r.requirement_id,
    "audience" => _jf_sym(r.audience),
    "requirement" => r.requirement,
    "rationale" => r.rationale,
    "verification" => r.verification,
    "gap_ids" => copy(r.gap_ids),
)

to_dict(u::JapanFiscalClaimUpgradeRule) = Dict{String, Any}(
    "rule_id" => u.rule_id,
    "conditions" => copy(u.conditions),
    "version_bumps" => copy(u.version_bumps),
    "forbidden" => copy(u.forbidden),
    "doc_ref" => u.doc_ref,
)

to_json(s::JapanFiscalClaimLevelSpec) = JSON3.write(to_dict(s))
to_json(c::JapanFiscalChannel) = JSON3.write(to_dict(c))
to_json(c::JapanFiscalCoverage) = JSON3.write(to_dict(c))
to_json(v::JapanFiscalClaimViolation) = JSON3.write(to_dict(v))
to_json(r::JapanFiscalHandoffRequirement) = JSON3.write(to_dict(r))
to_json(u::JapanFiscalClaimUpgradeRule) = JSON3.write(to_dict(u))

"""
    japan_fiscal_downstream_contract() -> Dict{String,Any}

claim-level / coverage 契約の全体を 1 つの機械可読 Dict として返す。Market Analyzer は
Julia 内部型を import せず、この Dict（および `#276` の result artifact）のみを consume する。

キー:
`claim_contract_version` / `capability_contract_version` / `claim_levels` / `diagnostics` /
`numeric_semantics` / `coverages`（55 件） / `channels`（25 件） / `forbidden_claims` /
`handoff_requirements`（22 件） / `claim_upgrade_rule` / `invariants`。
"""
function japan_fiscal_downstream_contract()
    return Dict{String, Any}(
        "claim_contract_version" => JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        "capability_contract_version" => JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        "claim_levels" => [
            to_dict(JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY[l]) for l in JAPAN_FISCAL_CLAIM_LEVELS
        ],
        "diagnostics" => _jf_syms(JAPAN_FISCAL_DIAGNOSTICS),
        "numeric_semantics" => _jf_syms(JAPAN_FISCAL_NUMERIC_SEMANTICS),
        "calibration_geographies" => _jf_syms(JAPAN_FISCAL_CALIBRATION_GEOGRAPHIES),
        "channel_statuses" => _jf_syms(JAPAN_FISCAL_CHANNEL_STATUSES),
        "violation_codes" => _jf_syms(JAPAN_FISCAL_CLAIM_VIOLATION_CODES),
        "coverages" => [to_dict(c) for c in japan_fiscal_coverages()],
        "channels" => [to_dict(c) for c in JAPAN_FISCAL_CHANNEL_REGISTRY],
        "forbidden_claims" => [
            Dict{String, Any}("kind" => _jf_sym(k), "reason" => r) for
            (k, r) in japan_fiscal_forbidden_claims()
        ],
        "handoff_requirements" => [to_dict(r) for r in JAPAN_FISCAL_HANDOFF_REQUIREMENTS],
        "claim_upgrade_rule" => to_dict(JAPAN_FISCAL_CLAIM_UPGRADE_RULE),
        "invariants" => Dict{String, Any}(
            "magnitude_claim_count" =>
                count(c -> c.claim_level === :magnitude, japan_fiscal_coverages()),
            "japan_calibrated_model_count" =>
                count(c -> c.calibration_geography === :jp, japan_fiscal_coverages()),
            "family_complete_count" =>
                count(c -> c.family_complete, japan_fiscal_coverages()),
            "unsupported_channel_count" =>
                length(japan_fiscal_channels(; status = :unsupported)),
        ),
    )
end
