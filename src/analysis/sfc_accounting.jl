# sfc_accounting.jl: SFC（Stock-Flow Consistent）会計恒等式の検証エンジン。
#
# `src/sfc/types.jl` の会計プリミティブ（BalanceSheetMatrix / TransactionFlowMatrix /
# SFCPeriodSnapshot / SFCResult）を入力に、貸借対照表・取引フロー・ストック更新式の
# 会計恒等式を各期で検証し、不整合を構造化して返す **読み取り専用** の後処理層。
#
# 設計契約: docs/adr/0007-sfc-integration-contract.md §4-5
#           docs/models/sfc_integration_design.md §4
#
# 主な規約（ADR 0007 §5）:
#   - 合否は絶対＋相対の複合基準 `abs(residual) <= atol + rtol * scale` で判定する。
#     `scale` は当該恒等式に関与する項の有限絶対値の最大（代表値）。
#   - NaN / Inf は例外にせず、その検証を `acc_invalid` として別扱いにする（Ponzi や会計違反へ
#     読み替えない）。0 除算・空行列は安全に扱う。
#   - 自動補正・丸め・辻褄合わせをしない。残差と元データ（evidence）を追跡可能にする。
#   - プリミティブ（`src/sfc/`）・モデル方程式・可視化・LLM 層はこのファイルで一切変更しない。

"""
    SFC_ACCOUNTING_METHODOLOGY_VERSION

会計検証エンジンの methodology version。検証名語彙・残差の定義・符号規約の意味論を
変更する場合に更新する（会計プリミティブ契約 [`SFC_CONTRACT_VERSION`](@ref) とは独立）。
"""
const SFC_ACCOUNTING_METHODOLOGY_VERSION = "sfc-accounting/1.0.0"

"""
    AccountingCheckStatus

会計検証 1 件の判定状態。

- `acc_pass`    … 許容誤差内で恒等式が成立。
- `acc_warning` … 恒等式は破っていないが検証不能・注意（例: 対応フロー未定義でストック更新を検証できない）。
- `acc_fail`    … 許容誤差を超える残差（会計違反）。
- `acc_invalid` … 残差が非有限（NaN / Inf）で判定不能。会計違反とは別扱い（ADR 0007 §5.2）。

集約時の深刻度は `acc_pass < acc_warning < acc_fail < acc_invalid`。
"""
@enum AccountingCheckStatus acc_pass acc_warning acc_fail acc_invalid

"""表示・JSON 用に [`AccountingCheckStatus`](@ref) を短い文字列へ変換する。"""
accounting_status_label(s::AccountingCheckStatus) =
    s === acc_pass ? "pass" :
    s === acc_warning ? "warning" : s === acc_fail ? "fail" : "invalid"

# 集約用の深刻度。大きいほど深刻。
_acc_severity(s::AccountingCheckStatus) =
    s === acc_pass ? 0 : s === acc_warning ? 1 : s === acc_fail ? 2 : 3

"""
    AccountingViolation

会計検証 1 件の結果レコード。恒等式・対象（period / sector / instrument / transaction）・
残差・許容誤差・状態・メッセージ・evidence を保持する。`status === acc_pass` 以外が
[`AccountingCheckReport`](@ref) の `violations` に集約される。

## フィールド
- `check::Symbol` — 検証名（`:balance_row_sum` / `:balance_column_sum` / `:flow_row_sum` /
  `:flow_column_sum` / `:stock_flow` / 構造検証 `:duplicate_period` / `:period_order` /
  `:dimension_change`）。
- `period::String` — 期ラベル（stock_flow は当期側の period）。
- `status::AccountingCheckStatus`
- `sector` / `instrument` / `transaction` — 対象の stable id（無ければ `nothing`）。
- `residual::Float64` — 恒等式残差（構造検証では意味を持たず 0）。
- `scale::Float64` — 許容誤差算出に用いた代表スケール。
- `tolerance::Float64` — 実効許容誤差 `atol + rtol * scale`。
- `message::String`
- `evidence::Dict{String, Any}` — 残差を追跡するための元データ（軸・寄与値等）。
"""
struct AccountingViolation
    check::Symbol
    period::String
    status::AccountingCheckStatus
    sector::Union{Symbol, Nothing}
    instrument::Union{Symbol, Nothing}
    transaction::Union{Symbol, Nothing}
    residual::Float64
    scale::Float64
    tolerance::Float64
    message::String
    evidence::Dict{String, Any}
end

"""
    AccountingCheckReport

[`validate_sfc_accounting`](@ref) の出力。会計検証全体の集約結果。

## フィールド
- `status::AccountingCheckStatus` — 全検証の最悪深刻度（`violations` が空なら `acc_pass`）。
- `violations::Vector{AccountingViolation}` — 非 pass の検証（決定的順序）。
- `checks_performed::Int` / `checks_passed::Int` — 実施件数と pass 件数。
- `max_abs_residual::Float64` — 有限残差の絶対値の最大（無ければ 0）。
- `valid_periods` / `invalid_periods::Vector{String}` — 非有限検証を含む期を invalid に分類。
- `divergence_time::Union{String, Nothing}` — ストックが非有限になった最初の期。
- `methodology::SFCMethodologyMetadata`
- `tolerance_abs` / `tolerance_rel::Float64` — 実際に用いた許容誤差。
"""
struct AccountingCheckReport
    status::AccountingCheckStatus
    violations::Vector{AccountingViolation}
    checks_performed::Int
    checks_passed::Int
    max_abs_residual::Float64
    valid_periods::Vector{String}
    invalid_periods::Vector{String}
    divergence_time::Union{String, Nothing}
    methodology::SFCMethodologyMetadata
    tolerance_abs::Float64
    tolerance_rel::Float64
end

"""検証が全件 pass だったかを返す。"""
accounting_passed(r::AccountingCheckReport) = r.status === acc_pass

# ---------------------------------------------------------------------------
# JSON 化（to_dict / to_json）。非有限値は src/sfc/serialization.jl の
# `_sfc_encode_float` / `_sfc_jsonify` と同じ文字列タグ規約で符号化する。
# ---------------------------------------------------------------------------

"""
    to_dict(v::AccountingViolation) -> Dict{String, Any}

会計検証 1 件を JSON 安全な `Dict` へ変換する。
"""
to_dict(v::AccountingViolation) = Dict{String, Any}(
    "check" => String(v.check),
    "period" => v.period,
    "status" => accounting_status_label(v.status),
    "sector" => v.sector === nothing ? nothing : String(v.sector),
    "instrument" => v.instrument === nothing ? nothing : String(v.instrument),
    "transaction" => v.transaction === nothing ? nothing : String(v.transaction),
    "residual" => _sfc_encode_float(v.residual),
    "scale" => _sfc_encode_float(v.scale),
    "tolerance" => _sfc_encode_float(v.tolerance),
    "message" => v.message,
    "evidence" => _sfc_jsonify(v.evidence),
)

"""
    to_dict(r::AccountingCheckReport) -> Dict{String, Any}

[`validate_sfc_accounting`](@ref) の結果を JSON 安全な `Dict` へ変換する。全 check・
最大残差・invalid 期・divergence 時点を含む。
"""
to_dict(r::AccountingCheckReport) = Dict{String, Any}(
    "status" => accounting_status_label(r.status),
    "violations" => Any[to_dict(v) for v in r.violations],
    "checks_performed" => r.checks_performed,
    "checks_passed" => r.checks_passed,
    "max_abs_residual" => _sfc_encode_float(r.max_abs_residual),
    "valid_periods" => copy(r.valid_periods),
    "invalid_periods" => copy(r.invalid_periods),
    "divergence_time" => r.divergence_time,
    "methodology" => to_dict(r.methodology),
    "tolerance_abs" => _sfc_encode_float(r.tolerance_abs),
    "tolerance_rel" => _sfc_encode_float(r.tolerance_rel),
)

to_json(v::AccountingViolation) = JSON3.write(to_dict(v))
to_json(r::AccountingCheckReport) = JSON3.write(to_dict(r))

# NaN 安全な等価比較（round-trip 後の report 一致テスト等で使う）。
function Base.isequal(a::AccountingViolation, b::AccountingViolation)
    return a.check == b.check &&
           a.period == b.period &&
           a.status === b.status &&
           a.sector === b.sector &&
           a.instrument === b.instrument &&
           a.transaction === b.transaction &&
           isequal(a.residual, b.residual) &&
           isequal(a.scale, b.scale) &&
           isequal(a.tolerance, b.tolerance) &&
           a.message == b.message &&
           isequal(a.evidence, b.evidence)
end

function Base.isequal(a::AccountingCheckReport, b::AccountingCheckReport)
    a.status === b.status || return false
    length(a.violations) == length(b.violations) || return false
    all(isequal(x, y) for (x, y) in zip(a.violations, b.violations)) || return false
    return a.checks_performed == b.checks_performed &&
           a.checks_passed == b.checks_passed &&
           isequal(a.max_abs_residual, b.max_abs_residual) &&
           a.valid_periods == b.valid_periods &&
           a.invalid_periods == b.invalid_periods &&
           a.divergence_time == b.divergence_time &&
           isequal(a.tolerance_abs, b.tolerance_abs) &&
           isequal(a.tolerance_rel, b.tolerance_rel)
end

# ---------------------------------------------------------------------------
# 内部ヘルパー
# ---------------------------------------------------------------------------

# 有限値の絶対値の最大（代表スケール）。有限値が無ければ 0。空でも安全。
function _acc_scale(vals)
    m = 0.0
    for v in vals
        if isfinite(v)
            a = abs(Float64(v))
            a > m && (m = a)
        end
    end
    return m
end

# 残差・スケールから合否状態を決める。非有限残差は acc_invalid。
function _acc_status(residual::Float64, scale::Float64, atol::Float64, rtol::Float64)
    isfinite(residual) || return acc_invalid
    return abs(residual) <= atol + rtol * scale ? acc_pass : acc_fail
end

# 検証 1 件を組み立てる（scale と atol/rtol から status・tolerance を決定）。
function _acc_check(
    check::Symbol,
    period::AbstractString,
    residual::Float64,
    scale::Float64,
    atol::Float64,
    rtol::Float64,
    message::AbstractString;
    evidence::Dict{String, Any} = Dict{String, Any}(),
    sector = nothing,
    instrument = nothing,
    transaction = nothing,
)
    status = _acc_status(residual, scale, atol, rtol)
    return AccountingViolation(
        check,
        String(period),
        status,
        sector,
        instrument,
        transaction,
        residual,
        scale,
        atol + rtol * scale,
        String(message),
        evidence,
    )
end

# 行/列ベクトルの「合計＝0」恒等式を 1 件の検証にする。
function _acc_sum_check(
    check::Symbol,
    period::AbstractString,
    axis_ids::Vector{Symbol},
    values::AbstractVector,
    atol::Float64,
    rtol::Float64,
    message::AbstractString;
    kwargs...,
)
    residual = sum(Float64, values; init = 0.0)
    scale = _acc_scale(values)
    evidence = Dict{String, Any}(
        "axis" => String[string(x) for x in axis_ids],
        "values" => Float64[Float64(v) for v in values],
        "residual" => residual,
    )
    return _acc_check(
        check,
        period,
        residual,
        scale,
        atol,
        rtol,
        message;
        evidence = evidence,
        kwargs...,
    )
end

# instrument の役割（financial / balancing）。balancing 行は stock_flow 検証から除外する
# （純資産＝バランス項であり、対応する取引フローを持たない）。
_acc_is_balancing(inst::SFCInstrument) =
    get(inst.metadata, "role", "financial") in ("balancing", "net_worth")

# instrument に対応する「ストック変化を記録する取引 id」を解決する。
# 明示 map（instrument id => transaction id）優先、無ければ規約 `<instrument>_change`。
function _acc_resolve_tx(inst_id::Symbol, stock_flow_map)
    if stock_flow_map !== nothing && haskey(stock_flow_map, inst_id)
        return Symbol(stock_flow_map[inst_id])
    end
    if stock_flow_map !== nothing && haskey(stock_flow_map, string(inst_id))
        return Symbol(stock_flow_map[string(inst_id)])
    end
    return Symbol(string(inst_id) * "_change")
end

_acc_axis_pos(axis::Vector{Symbol}, id::Symbol) = findfirst(==(id), axis)

# ---------------------------------------------------------------------------
# 期内検証（1 スナップショット）
# ---------------------------------------------------------------------------

function _acc_intra_period!(
    checks::Vector{AccountingViolation},
    snap::SFCPeriodSnapshot,
    atol::Float64,
    rtol::Float64,
)
    bs = snap.balance_sheet
    tf = snap.transaction_flow
    p = snap.period

    # 1. 取引フロー各行の行和 = 0（すべてのフローに相手方がいる）
    for (r, txid) in enumerate(tf.transactions)
        push!(
            checks,
            _acc_sum_check(
                :flow_row_sum,
                p,
                tf.sectors,
                @view(tf.flows[r, :]),
                atol,
                rtol,
                "取引 $(repr(txid)) の全部門フロー合計が 0 でない（相手方の欠落・符号誤り）";
                transaction = txid,
            ),
        )
    end

    # 2. 取引フロー各 sector 列の列和 = 0（部門予算制約: 源泉＝使途）
    for (c, secid) in enumerate(tf.sectors)
        push!(
            checks,
            _acc_sum_check(
                :flow_column_sum,
                p,
                tf.transactions,
                @view(tf.flows[:, c]),
                atol,
                rtol,
                "部門 $(repr(secid)) の予算制約（列和）が 0 でない";
                sector = secid,
            ),
        )
    end

    # 3. 貸借対照表各 instrument 行の行和 = 0（資産＝負債対応）
    for (r, instid) in enumerate(bs.instruments)
        push!(
            checks,
            _acc_sum_check(
                :balance_row_sum,
                p,
                bs.sectors,
                @view(bs.holdings[r, :]),
                atol,
                rtol,
                "金融商品 $(repr(instid)) の資産・負債対応（行和）が 0 でない";
                instrument = instid,
            ),
        )
    end

    # 4. 貸借対照表各 sector 列の列和 = 0（純資産バランス行込み）
    for (c, secid) in enumerate(bs.sectors)
        push!(
            checks,
            _acc_sum_check(
                :balance_column_sum,
                p,
                bs.instruments,
                @view(bs.holdings[:, c]),
                atol,
                rtol,
                "部門 $(repr(secid)) の貸借対照表（列和・純資産込み）が 0 でない";
                sector = secid,
            ),
        )
    end

    return checks
end

# ---------------------------------------------------------------------------
# ストック・フロー整合（連続する 2 期）
# ---------------------------------------------------------------------------

# stock_t − stock_{t-1} = transaction_flow_t + valuation_change_t（ADR 0007 §4）。
# 取引フローは符号規約 :source_use（既定）で「ストック変化と逆符号」に記録されるため、
# 残差 = Δstock + sign * flow − valuation。sign = +1（:source_use）/ −1（:receipt_payment）。
function _acc_stock_flow!(
    checks::Vector{AccountingViolation},
    prev::SFCPeriodSnapshot,
    curr::SFCPeriodSnapshot,
    instruments::Vector{SFCInstrument},
    sign_convention::Symbol,
    stock_flow_map,
    atol::Float64,
    rtol::Float64,
)
    pbs = prev.balance_sheet
    cbs = curr.balance_sheet
    p = curr.period

    # 次元一致（同じ instrument × sector 軸）でなければ stock_flow は検証できない。
    if pbs.instruments != cbs.instruments || pbs.sectors != cbs.sectors
        push!(
            checks,
            AccountingViolation(
                :dimension_change,
                p,
                acc_warning,
                nothing,
                nothing,
                nothing,
                0.0,
                0.0,
                0.0,
                "前期 $(repr(prev.period)) と当期 $(repr(p)) で貸借対照表の軸が変化したため " *
                "stock_flow を検証できません",
                Dict{String, Any}(
                    "prev_instruments" => String[string(x) for x in pbs.instruments],
                    "curr_instruments" => String[string(x) for x in cbs.instruments],
                    "prev_sectors" => String[string(x) for x in pbs.sectors],
                    "curr_sectors" => String[string(x) for x in cbs.sectors],
                ),
            ),
        )
        return checks
    end

    sgn = sign_convention === :receipt_payment ? -1.0 : 1.0
    vadj = curr.valuation_adjustment
    ctf = curr.transaction_flow
    role_by_id = Dict(i.id => i for i in instruments)

    for (r, instid) in enumerate(cbs.instruments)
        inst = get(role_by_id, instid, nothing)
        # 純資産バランス行は対応フローを持たないため除外する。
        inst !== nothing && _acc_is_balancing(inst) && continue

        txid = _acc_resolve_tx(instid, stock_flow_map)
        tx_pos = _acc_axis_pos(ctf.transactions, txid)

        for (c, secid) in enumerate(cbs.sectors)
            dstock = Float64(cbs.holdings[r, c]) - Float64(pbs.holdings[r, c])
            val = Float64(vadj.holdings[r, c])

            if tx_pos === nothing
                # 対応フロー未定義。ストックが動いていれば検証不能として warning。
                scale = _acc_scale((cbs.holdings[r, c], pbs.holdings[r, c], val))
                if isfinite(dstock) && abs(dstock) <= atol + rtol * scale
                    continue  # ストック不変・対応フロー無し → 検証項目なし
                end
                push!(
                    checks,
                    AccountingViolation(
                        :stock_flow,
                        p,
                        acc_warning,
                        secid,
                        instid,
                        nothing,
                        dstock,
                        scale,
                        atol + rtol * scale,
                        "金融商品 $(repr(instid)) の対応取引 $(repr(txid)) が取引フロー行列に" *
                        "無く、部門 $(repr(secid)) のストック変化を検証できません",
                        Dict{String, Any}(
                            "delta_stock" => dstock,
                            "stock_t" => Float64(cbs.holdings[r, c]),
                            "stock_prev" => Float64(pbs.holdings[r, c]),
                        ),
                    ),
                )
                continue
            end

            flow = Float64(ctf.flows[tx_pos, _acc_axis_pos(ctf.sectors, secid)])
            residual = dstock + sgn * flow - val
            scale = _acc_scale((cbs.holdings[r, c], pbs.holdings[r, c], flow, val))
            push!(
                checks,
                _acc_check(
                    :stock_flow,
                    p,
                    residual,
                    scale,
                    atol,
                    rtol,
                    "部門 $(repr(secid)) の $(repr(instid)) について " *
                    "stock_t − stock_{t-1} = flow + valuation が成立しない";
                    evidence = Dict{String, Any}(
                        "delta_stock" => dstock,
                        "flow" => flow,
                        "valuation" => val,
                        "sign" => sgn,
                        "residual" => residual,
                    ),
                    sector = secid,
                    instrument = instid,
                    transaction = txid,
                ),
            )
        end
    end
    return checks
end

# ---------------------------------------------------------------------------
# 構造検証（period 順序・重複・次元）
# ---------------------------------------------------------------------------

function _acc_structure!(
    checks::Vector{AccountingViolation},
    snapshots::Vector{SFCPeriodSnapshot},
)
    periods = String[s.period for s in snapshots]

    # 重複 period
    seen = Dict{String, Int}()
    for p in periods
        seen[p] = get(seen, p, 0) + 1
    end
    for p in sort(collect(keys(seen)))
        if seen[p] > 1
            push!(
                checks,
                AccountingViolation(
                    :duplicate_period,
                    p,
                    acc_fail,
                    nothing,
                    nothing,
                    nothing,
                    0.0,
                    0.0,
                    0.0,
                    "period $(repr(p)) が $(seen[p]) 回重複しています",
                    Dict{String, Any}("count" => seen[p]),
                ),
            )
        end
    end

    # period 順序（数値化できれば数値昇順、できなければ辞書昇順）で非単調を warning
    parsed = tryparse.(Float64, periods)
    key = all(!isnothing, parsed) ? Float64[x for x in parsed] : periods
    if length(key) >= 2 && !issorted(key)
        push!(
            checks,
            AccountingViolation(
                :period_order,
                length(periods) == 0 ? "" : periods[1],
                acc_warning,
                nothing,
                nothing,
                nothing,
                0.0,
                0.0,
                0.0,
                "snapshot の period が昇順に並んでいません: $(periods)",
                Dict{String, Any}("periods" => periods),
            ),
        )
    end
    return checks
end

# ---------------------------------------------------------------------------
# report 組み立て
# ---------------------------------------------------------------------------

function _acc_build_report(
    checks::Vector{AccountingViolation},
    snapshots::Vector{SFCPeriodSnapshot},
    methodology::SFCMethodologyMetadata,
    atol::Float64,
    rtol::Float64,
)
    performed = length(checks)
    passed = count(c -> c.status === acc_pass, checks)

    # 集約深刻度
    agg = acc_pass
    for c in checks
        _acc_severity(c.status) > _acc_severity(agg) && (agg = c.status)
    end

    # 最大有限残差
    maxres = 0.0
    for c in checks
        isfinite(c.residual) && abs(c.residual) > maxres && (maxres = abs(c.residual))
    end

    # invalid 期（非有限残差を含む period）
    invalid_set = Set{String}()
    for c in checks
        c.status === acc_invalid && push!(invalid_set, c.period)
    end
    all_periods = String[s.period for s in snapshots]
    invalid_periods = String[p for p in all_periods if p in invalid_set]
    valid_periods = String[p for p in all_periods if !(p in invalid_set)]

    # 発散時点: ストックが非有限になる最初の period
    divergence_time = nothing
    for s in snapshots
        if any(!isfinite, s.balance_sheet.holdings)
            divergence_time = s.period
            break
        end
    end

    violations = AccountingViolation[c for c in checks if c.status !== acc_pass]

    return AccountingCheckReport(
        agg,
        violations,
        performed,
        passed,
        maxres,
        valid_periods,
        invalid_periods,
        divergence_time,
        methodology,
        atol,
        rtol,
    )
end

# ---------------------------------------------------------------------------
# 公開 API
# ---------------------------------------------------------------------------

"""
    validate_sfc_accounting(r::SFCResult; atol, rtol, stock_flow_map=nothing) -> AccountingCheckReport
    validate_sfc_accounting(snap::SFCPeriodSnapshot; atol=1e-8, rtol=1e-6) -> AccountingCheckReport

SFC 会計恒等式を検証し、[`AccountingCheckReport`](@ref) を返す（読み取り専用・自動補正なし）。

`SFCResult` 版は次を検証する:

1. 取引フロー各行の行和 = 0（`:flow_row_sum`）
2. 取引フロー各 sector 列の列和 = 0（部門予算制約 `:flow_column_sum`）
3. 貸借対照表各 instrument 行の行和 = 0（資産＝負債対応 `:balance_row_sum`）
4. 貸借対照表各 sector 列の列和 = 0（純資産バランス行込み `:balance_column_sum`）
5. `stock_t − stock_{t-1} = flow + valuation`（連続 2 期 `:stock_flow`）
6. period 重複・順序・次元変化の構造検証

`atol` / `rtol` は既定で `r.methodology.tolerance_abs` / `tolerance_rel`。`stock_flow_map` は
instrument id → 対応取引 id の明示対応（省略時は規約 `<instrument>_change`）。純資産バランス行
（instrument metadata の `"role" ∈ ("balancing", "net_worth")`）は stock_flow から除外する。

`SFCPeriodSnapshot` 版は単一期のため期内検証（1〜4）のみを行う。
"""
function validate_sfc_accounting(
    r::SFCResult;
    atol::Real = r.methodology.tolerance_abs,
    rtol::Real = r.methodology.tolerance_rel,
    stock_flow_map = nothing,
)
    atolf = Float64(atol)
    rtolf = Float64(rtol)
    checks = AccountingViolation[]

    _acc_structure!(checks, r.snapshots)

    for snap in r.snapshots
        _acc_intra_period!(checks, snap, atolf, rtolf)
    end

    for k in 2:length(r.snapshots)
        _acc_stock_flow!(
            checks,
            r.snapshots[k - 1],
            r.snapshots[k],
            r.instruments,
            r.methodology.sign_convention,
            stock_flow_map,
            atolf,
            rtolf,
        )
    end

    return _acc_build_report(checks, r.snapshots, r.methodology, atolf, rtolf)
end

function validate_sfc_accounting(
    snap::SFCPeriodSnapshot;
    atol::Real = 1e-8,
    rtol::Real = 1e-6,
)
    atolf = Float64(atol)
    rtolf = Float64(rtol)
    checks = AccountingViolation[]
    _acc_intra_period!(checks, snap, atolf, rtolf)
    meth = SFCMethodologyMetadata(tolerance_abs = atolf, tolerance_rel = rtolf)
    return _acc_build_report(checks, [snap], meth, atolf, rtolf)
end
