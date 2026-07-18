# Minsky 連続診断指標・サマリー（Phase 2）— 指標定義と契約設計

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **対象モデル** | Keen モデル（`KeenModel`、[keen.md](keen.md)） |
| **ステータス** | 実装済み（`src/analysis/minsky_diagnostics.jl`、#113） |
| **関連 Issue** | #99（ロードマップ）・#113（本Issue）。依存: #112（区分診断、`minsky_regime_diagnostics.md`） |
| **前提ドキュメント** | [Minsky 資金調達区分診断](minsky_regime_diagnostics.md)（区分・境界・仮定の操作的定義） |
| **methodology version** | `minsky-diagnostics/1.0.0`（区分診断の methodology version
  `minsky-regime/1.0.0` とは独立に管理） |

> **LLM向け要約**: 本書は Keen モデルの出力から、Hedge/Speculative/Ponzi の**区分だけでは
> 失われる連続量**（カバレッジ比率・境界からのマージン・債務変化等）と、それらを集約した
> 構造化サマリー（regime 滞在比率・最初の悪化時点・peak/minimum・発散時点）を定義する。
> 区分診断（[minsky_regime_diagnostics.md](minsky_regime_diagnostics.md)）と同一の判定式・
> 仮定を再利用する読み取り専用の後処理層であり、`KeenModel` の ODE 動学・パラメータには
> 一切影響しない。重み付き単一複合スコアは提供しない（§6）。倒産予測・危機予測ではない。

---

## 1. 背景と設計の狙い

Hedge/Speculative/Ponzi の区分（#112）は、金融不安定性の状態を離散カテゴリとして提示する。
しかし区分境界の直前と直後では経済状態の差が小さい場合でも別カテゴリに分類されるため、
「どの方向へ、どの程度」不安定性が進んでいるかは区分だけでは把握しにくい。

本書は、区分の判定に使われる中間量（営業余剰・利払い負担・元本返済負担の代理等、
[minsky_regime_diagnostics.md](minsky_regime_diagnostics.md) §2）を再利用し、

1. 連続量としてのカバレッジ比率・マージンを時系列で提供し、
2. regime 滞在比率・最初の悪化時点・peak/minimum・発散時点を構造化サマリーとして提供し、
3. 複数シナリオ（金利・初期債務・amortization_rate 等）の診断結果を比較できる入口を提供する。

恣意的な単一スコアへの早期集約は解釈可能性を失うため、Phase 2 では複数指標の併記を基本とし、
単一複合スコアは提供しない（§6）。

---

## 2. 時点別診断指標（`MinskyDiagnosticObservation`）

すべて産出比・年率（[minsky_regime_diagnostics.md](minsky_regime_diagnostics.md) §2 と同じ単位系）。
`ω`・`d`・`g` は Keen モデルの出力（`d` は状態変数、`g` は派生変数）、`r` は貸出金利パラメータ、
`amortization_rate` は `FinancingRegimeConfig` の診断仮定。

| 指標 | 定義式 | 単位・符号・望ましい方向 | 未定義値の扱い |
|---|---|---|---|
| `debt_ratio` | `d` | 産出比。低いほど負担が小さい | `invalid` 時は入力値そのまま（`NaN` になりうる） |
| `operating_surplus_share` | `1 - ω` | 産出比。高いほど支払余力が大きい | `ω`・`d`・`r` のいずれかが非有限なら `NaN` |
| `net_profit_share` | `π = 1 - ω - r*d` | 産出比。既存 Keen 派生変数と同一式 | 同上 |
| `interest_burden` | `r * max(d, 0)` | 年率産出比。低いほど良い | 同上 |
| `principal_commitment_proxy` | `amortization_rate * max(d, 0)` | 年率産出比。診断仮定に基づく代理 | 同上 |
| `interest_coverage_ratio` | `operating_surplus_share / interest_burden` | 無次元。**高いほど良い**（`1` 未満は利払いを賄えない） | `interest_burden == 0.0`（`d ≤ 0`）で `Inf`。非有限入力で `NaN`（§2.1） |
| `debt_service_coverage_ratio` | `operating_surplus_share / (interest_burden + principal_commitment_proxy)` | 同上 | 分母が厳密に `0.0`（`d ≤ 0`）で `Inf`。非有限入力で `NaN` |
| `ponzi_margin` | `operating_surplus_share - interest_burden` | 産出比。**正なら非Ponzi側**（Ponzi境界からの距離） | 非有限入力で `NaN` |
| `hedge_margin` | `operating_surplus_share - (interest_burden + principal_commitment_proxy)` | 産出比。**正ならHedge側**（Hedge境界からの距離） | 同上 |
| `debt_change` | `debt_ratio[t] - debt_ratio[t-1]` | 産出比/年（前期差分）。**低い（負）ほど債務圧縮** | `t == 1` または前期が非有限（発散後）で `NaN`（§3） |
| `growth_rate` | 既存出力 `g`（再計算しない） | 年率。文脈依存（高すぎる成長は過熱、低すぎる/負は縮小） | 元系列が `NaN` の期間はそのまま `NaN` |
| `divergence_status` | — | `no_divergence`/`divergence_onset`/`divergence_continued`（§4） | — |

### 2.1 非有限入力の扱い

`ω`・`d`・`r` のいずれかが非有限（`NaN`/`Inf`）のとき、`debt_ratio`・`growth_rate` を除く
すべての派生量を明示的に `NaN` にする（[minsky_regime_diagnostics.md](minsky_regime_diagnostics.md)
の `FinancingRegimeObservation` と同じ方針）。`interest_burden` 等は `d`・`r` のみに依存するため、
IEEE 754 の `NaN` 伝播だけに頼ると「`ω` のみ非有限」なケースで一部の派生量が有限値のまま
残ってしまう。これを避けるため `ω`・`d`・`r` の非有限性を明示的にチェックする。

### 2.2 カバレッジ比率の `0` 除算規則

`interest_coverage_ratio`・`debt_service_coverage_ratio` は、分母（`interest_burden` /
`interest_burden + principal_commitment_proxy`）が**厳密に** `0.0` のとき `Inf` を返す。
これは `d ≤ 0`（無借金・純貸し手、`max(d, 0) = 0`）のときに限られる。

`FinancingRegimeConfig.debt_tolerance`（既定 `1e-8`）以下の微小な**正の** `d`（区分としては
`unlevered`）では `interest_burden` は厳密には非ゼロの微小値になるため、`Inf` ではなく
有限の非常に大きな値になる。区分の `unlevered` 判定（許容差付き）と、カバレッジ比率の
`Inf` 判定（厳密な `0`）は独立した規則である点に注意する。

---

## 3. `debt_change` の算出方式

Issue #113 は「離散系列の前年差」と「Keen ODE の `ḋ`」のいずれかに固定することを求める。
本実装は**離散系列の前期差分**（`debt_ratio[t] - debt_ratio[t-1]`）を採用する。

| 項目 | 内容 |
|---|---|
| 採用方式 | `discrete_diff`（前期差分） |
| 理由 | `NamedTuple` 経路・`SimulationResult` 経路の双方で、ODE パラメータ（`κ0`・`κ1`・`κ2`・`ν`・`δ`）の再取得なしに同一ロジックで計算できる。Keen の `simulate` は年次サンプリングのため、前期差分は年率の変化量として直接解釈できる |
| 識別方法 | `MinskyDiagnosticsResult.metadata["debt_change_method"]`（値は常に `"discrete_diff"`） |
| `t == 1` の扱い | 前期が存在しないため `NaN`（`0` で代用しない） |
| 発散前後の扱い | 前期または当期が非有限（発散後の `NaN` 区間）の場合は `NaN` |

将来 ODE の `ḋ`（`keen_rhs` の第3成分）に切り替える場合は、`MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION`
を更新し、`debt_change_method` の値も変更すること。

---

## 4. `DivergenceStatus`

Keen モデルの発散ガード（[keen.md](keen.md) §8）に対する各時点の状態を区別する。

| 値 | 意味 |
|---|---|
| `no_divergence` | 発散ガード未作動（有効値） |
| `divergence_onset` | 発散ガードが作動した最初の時点（この時点から値は `NaN`） |
| `divergence_continued` | 発散後の `NaN` 埋め区間（`divergence_onset` より後） |

`regime == invalid`（`FinancingRegime`）と対応するが、`divergence_onset` と
`divergence_continued` を区別することで発散イベントの発生時点（`MinskyDiagnosticsResult.divergence_time`）
を一意に特定できる。発散しなかった場合、`divergence_time` は `nothing`（`0` や最終時点で代用しない）。

---

## 5. 構造化診断結果とサマリー

### 5.1 `MinskyDiagnosticsResult`

`MinskyDiagnosticObservation` の時系列に加え、区分診断（`FinancingRegimeDiagnostics`）・
設定（`FinancingRegimeConfig`）・本レイヤーの methodology version・有効/invalid 観測期間・
発散時点・元のモデルパラメータ等の metadata を保持する。元の `SimulationResult`/`NamedTuple`
は複製・変更しない（派生結果として保持）。

```julia
minsky_diagnostics(m::KeenModel, result::NamedTuple;
                   config::FinancingRegimeConfig = FinancingRegimeConfig(),
                   scenario_name::String = "simulate") -> MinskyDiagnosticsResult

minsky_diagnostics(sr::SimulationResult;
                   config::FinancingRegimeConfig = FinancingRegimeConfig()) -> MinskyDiagnosticsResult
```

`NamedTuple` は `:ω`・`:d`・`:g` を、`SimulationResult` は `"ω"`・`"d"`・`"g"` 変数と
`metadata["parameters"].r` を要求する（欠ける場合は `ArgumentError`、区分診断と同じ方針）。

### 5.2 `MinskyDiagnosticsSummary`

`minsky_diagnostics_summary(diag::MinskyDiagnosticsResult) -> MinskyDiagnosticsSummary` で
以下を取得できる。存在しないイベントは `nothing` で表し、`0` や最終時点で代用しない。

| フィールド | 内容 |
|---|---|
| `regime_counts`・`regime_share_of_valid` | 各 regime の期間数・有効期間 `n_valid` に占める比率（`invalid` のみ全期間 `n_periods` に占める比率） |
| `first_speculative_time`・`first_ponzi_time` | 最初にその区分へ移行した時点。未到達なら `nothing` |
| `recovery_to_hedge_time` | `speculative`/`ponzi` へ最初に移行した後、最初に `hedge` へ回復した時点。degradation が一度もない、または回復しなかった場合は `nothing` |
| `peak_debt_ratio`・`peak_debt_ratio_time` | 有効期間内の債務比率の最大値とその時点 |
| `min_interest_coverage_ratio`・`min_debt_service_coverage_ratio`（および各 `_time`） | 有効期間内の最小値とその時点 |
| `min_ponzi_margin`・`min_hedge_margin`（および各 `_time`） | 有効期間内の最小値とその時点 |
| `max_debt_change`・`max_debt_change_time` | 有効な `debt_change`（`t == 1` を除く）の最大値とその時点 |
| `diverged`・`divergence_time` | 発散ガードが作動したか・その時点 |

`peak_*`・`min_*`・`max_*` 系フィールドは、対応する有効観測が1件も存在しない場合に限り
値・時点ともに `nothing` になる。同値が複数存在する場合は最初に出現した時点を採用する。

### 5.3 シナリオ比較（`MinskyDiagnosticsComparison`）

```julia
minsky_diagnostics_comparison(
    named_diagnostics::AbstractVector{<:Pair{String, MinskyDiagnosticsResult}},
) -> MinskyDiagnosticsComparison
```

名前付き `MinskyDiagnosticsResult` のベクトルから、各シナリオのサマリーを並べた
`MinskyDiagnosticsComparison` を構築する。各シナリオは独立した `KeenModel`・初期値・
`FinancingRegimeConfig` から生成されていてよく、次のいずれの比較にも使える入口である。

- baseline と高金利シナリオ（`r` を変えた `KeenModel`）
- baseline と高初期債務シナリオ（同一モデル・異なる初期値）
- 同一シミュレーション結果への `amortization_rate` 感応度比較（`config` のみ変更）

各サマリーは自身の `config`（`methodology_version` を含む）を保持するため、異なる診断設定を
暗黙に同列比較することはない（設定差は `cmp.summaries[i].config` から確認できる）。

---

## 6. 単一複合スコアの扱い（対象外）

Phase 2 では重み付き単一複合スコアを実装しない。理由:

- raw 指標（カバレッジ比率・マージン等）を常に個別に参照可能な形で提供する方が、
  恣意的な重み付けによる情報損失を避けられる。
- 正規化範囲・重み・欠損処理の妥当な設定は実データによる校正（Phase 3）を経ていない。
- 「危機確率」や予測値として表現することは
  [LLM 出力の安全性ルール](../llm_safety.md) の禁止表現に抵触しうる。

将来 Phase 3 以降で複合スコアを追加する場合は、raw 指標の常時併記・正規化設定と
methodology version の明記・既定無効化（実験的 API 化）を満たすこと。

---

## 7. 理論上・実証上の限界

[Minsky 資金調達区分診断](minsky_regime_diagnostics.md) §7 の限界をすべて継承する。加えて:

| 限界 | 内容 |
|---|---|
| `debt_change` は離散近似 | 前期差分であり、ODE の瞬時変化率 `ḋ` そのものではない（§3） |
| カバレッジ比率の `Inf` は仮定依存 | `interest_coverage_ratio`/`debt_service_coverage_ratio` の `Inf` 判定は厳密な `d ≤ 0` に限定される仮定であり、実務上の「無借金」の定義（`debt_tolerance` 以下）とは独立である（§2.2） |
| サマリーは断面統計 | `peak`/`min`/`first_*` は単一シミュレーション経路上の統計であり、複数の確率的経路にわたる分布ではない |
| 単一複合スコアなし | Phase 2 は複合スコアを提供しない（§6）。将来追加する場合も予測値として扱わない |

---

## 8. 対象外（本 Issue のスコープ外）

- 実データによる閾値・パラメータ推定
- 危機発生確率の推定・機械学習による早期警戒モデル
- 可視化
- LLM 自然言語解説
- 重み付き単一複合スコアの既定実装（§6）

---

## 9. 参考

- [Minsky 資金調達区分診断](minsky_regime_diagnostics.md) — Hedge/Speculative/Ponzi の操作的定義・仮定
- [Keen モデル解説](keen.md) — 状態変数・出力スキーマ・`NaN` 埋め・限界
- [ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md) — 責務境界・tolerance/hysteresis 採否の決定記録
- [LLM 出力の安全性・免責・禁止表現ルール](../llm_safety.md) — 予測断定の禁止・必須免責
- Minsky (1986), *Stabilizing an Unstable Economy* — Hedge/Speculative/Ponzi の原典的定義
