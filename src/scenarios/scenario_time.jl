# scenario_time.jl: シナリオ・イベント実行層の時間軸に関する型（Issue #197 / `E-1`）。
#
# 本ファイルは `CalendarQuarter`・`TimingRuleSet` の**型のみ**を定義する。四半期の暦日変換
# （`quarter_of`・`quarter_index`・`quarter_label`）・適用四半期の割当規則（`:same_quarter` /
# `:next_quarter` / `:cutoff` / `:explicit_period`）・時間形状6種の離散式（`shock_shape_path`）
# などの「規則の実装」は Issue #198（`E-2`）が対象とする（統合設計 §11 `E-1` 行）。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.4（本ファイルの型定義の正本）・
#     §4.1（配置・依存）
#   docs/architecture/scenario_time_semantics.md §2.2（暦四半期の表現）・§4.3（`:cutoff` の
#     既定境界）・§11.3（ホライズン境界を設定値から求める、`Y-09`）
#
# 依存: stdlib のみ（`Dates` は `DME.jl` で `using` 済み）。`src/scenarios/` の他ファイルは
# 本ファイルより後に include される（統合設計 §4.2）。

# ------------------------------------------------------------
# CalendarQuarter（統合設計 §5.4）
# ------------------------------------------------------------

"""
    CalendarQuarter

暦四半期 `(year, quarter)`。表示形式は `"YYYYQn"`（例 `"2026Q1"`、
シナリオ時間軸の意味論 §2.2）。

## フィールド
- `year::Int`
- `quarter::Int`: `1:4` のいずれか。

`quarter ∉ 1:4` は構築時に `ArgumentError`（§6.1 の層 (1)）。暦日 ⇄ `CalendarQuarter` の変換
（`quarter_of`・`quarter_index`・`quarter_label`）は Issue #198 が実装する。
"""
struct CalendarQuarter
    year::Int
    quarter::Int

    function CalendarQuarter(year::Int, quarter::Int)
        quarter in 1:4 || throw(
            ArgumentError(
                "CalendarQuarter.quarter=$quarter は 1:4 のいずれかでなければなりません" *
                "（シナリオ時間軸の意味論 §2.2）",
            ),
        )
        return new(year, quarter)
    end
end

# ------------------------------------------------------------
# TimingRuleSet（統合設計 §5.4。適用四半期の割当規則の設定値）
# ------------------------------------------------------------

"""
    TimingRuleSet

適用四半期の割当規則の**設定値**（シナリオ時間軸の意味論 §4.3・統合設計 §7.3）。
コード変更を伴わずに結果を変えうる値（`cutoff_month_offset` 等）は必ず `id`/`version` を
持つ（ADR 0010 §7）。

## フィールド
- `id::String`: 規則セットの識別子（既定 `"default"`）。
- `version::String`: 規則セットの version（既定 `"timing-rule-set/1.0.0"`）。
  `cutoff_month_offset` 等の設定値を変えたら上げる。
- `cutoff_month_offset::Int`: `:cutoff` 規則の境界（当該四半期の第何月の末日か。既定 `2`
  = 第2月末日、シナリオ時間軸 §4.3）。
- `rules::Dict{Symbol,Symbol}`: `event_type => 割当規則`（シナリオ時間軸 §4.4）。
  既定は空 `Dict`（イベント型ごとの既定規則の登録は Issue #198/#199/#200 の対象）。

適用四半期の決定アルゴリズム（`offset(:cutoff, ...)` 等、シナリオ時間軸 §4.3・統合設計 §7.3）
の実装は Issue #198 が対象とする。本ファイルは設定値を保持する型のみを定義する。
"""
Base.@kwdef struct TimingRuleSet
    id::String = "default"
    version::String = "timing-rule-set/1.0.0"
    cutoff_month_offset::Int = 2
    rules::Dict{Symbol, Symbol} = Dict{Symbol, Symbol}()
end
