# ADR 0003: Minsky 資金調達区分は Keen 本体と分離した読み取り専用診断層とし、hysteresis は初版で不採用とする

- **ステータス**: 採用
- **日付**: 2026-07-18
- **関連Issue**: #99（ロードマップ）・#111（操作的定義と診断契約の設計）
- **前提ADR**: [ADR 0001](0001-minsky-model-selection.md)（Keen モデル採用）・[ADR 0002](0002-minsky-integration-design.md)（Keen 統合方式）
- **関連ドキュメント**: [Minsky 資金調達区分診断 — 操作的定義と契約設計](../models/minsky_regime_diagnostics.md)

## コンテキスト

ADR 0001・0002 で採用・統合した Keen モデル（連続時間 3 変数 ODE 系、状態変数 `ω`・`λ`・`d`）に対し、
Minsky の資金調達区分（Hedge / Speculative / Ponzi）判定を予定する。
しかし区分は Keen の状態変数から一意には決まらない。Minsky の区分は
**期待キャッシュフローが利払いと元本返済をどこまで賄えるか**に基づくが、
Keen は集計モデルであり、契約上の元本返済スケジュールや債務満期構成を状態変数として持たない。

この制約下で区分を導入するにあたり、次を決める必要がある。

1. 元本返済負担の代理（`amortization_rate`）を Keen モデル本体に持たせるか、診断層に閉じるか。
2. 区分診断を Keen の動学・出力とどう責務分離するか。
3. 境界近傍での区分の頻繁な反転に対し、`tolerance` と hysteresis のどちらを採るか。

## 決定

1. **資金調達区分は Keen 本体から分離した「読み取り専用の後処理診断層」として設計する。**
   診断は `simulate`/`impulse_response` の `NamedTuple` 出力および `SimulationResult` を入力に取り、
   区分・フロー量・境界距離を返すのみで、Keen の ODE 動学・パラメータ・`steady_state` を一切変更しない。

2. **`amortization_rate` は診断層の `FinancingRegimeConfig` にのみ持たせ、`KeenModel` には追加しない。**
   `KeenModel` の `struct`・`parameters(m)`・`keen_rhs` は無変更。元本返済代理は
   構造パラメータではなく明示的な診断仮定であり、その変更が ODE 解に波及してはならない。

3. **区分は時点ごとの純粋関数（メモリレス）として定義し、`classification_tolerance`（数値許容差バンド）を採用、hysteresis は初版で採用しない。**
   境界比較には対称な許容差 `τ` を適用して浮動小数点ジッタによる反転のみを抑える。
   区分ごとに進入・退出閾値を変える hysteresis は導入しない。

4. **`invalid` と `unlevered` を明示的な区分として先に判定する。**
   非有限値（発散後 `NaN`）を最優先で `invalid` に、正の債務負担がない状態（`d ≤ debt_tolerance`）を
   `unlevered` に分類し、Hedge/Speculative/Ponzi の基本分類より上位の precedence を与える。

## 理由

- **責務境界の明確化（決定 1・2）**: 診断仮定（`amortization_rate`）が ODE 解に影響しないことを
  型レベルで保証できる。診断設定を振っても Keen の動学・良い均衡は不変であり、
  「理論概念」と「DME 上の代理指標」の混同を構造的に防ぐ。感応度分析
  （[診断設計](../models/minsky_regime_diagnostics.md) §3.3）も動学の再計算なしに実行できる。
- **メモリレス設計の単純さ（決定 3）**: 純粋関数なら `NamedTuple` 出力・`SimulationResult` の
  双方から状態を持ち回さずに診断でき、契約が単純で再現性が高い。methodology version の
  意味論も「同じ入力＋同じ config → 同じ区分」で閉じる。
- **hysteresis 不採用の理由（決定 3）**: hysteresis は経路依存性と追加の内部状態を導入し、
  再現性・provenance を複雑化する。`classification_tolerance` で数値ジッタは抑制済みであり、
  境界近傍での真の頻繁な反転は「借り手がマージン上に張り付いている」という
  経済的に意味のある情報であって、平滑化で隠すべきではない。
- **`invalid`/`unlevered` の分離（決定 4）**: `d` が `NaN` のとき `d ≤ debt_tolerance` の評価は
  `false` になり silently に別区分へ落ちる危険がある。非有限を最優先で弾き、
  正の債務がない領域を明示区分にすることで、受け入れ条件「`NaN` や無借金を Hedge/Ponzi に
  誤分類しない」を構造的に満たす。

## 見送りとした選択肢

- **`amortization_rate` を `KeenModel` パラメータに追加**: 診断仮定が ODE 動学へ波及し、
  責務境界が崩れる。均衡・シミュレーション結果が診断設定に依存してしまうため不採用。
- **hysteresis の初版導入**: 上記のとおり経路依存・再現性コストに見合わない。
  実データ系列でノイズが過大と判明した場合の**将来オプション**として残す。
  採用時は methodology version を上げ、`FinancingRegimeConfig` に閾値フィールドを追加する。
- **区分を LLM に自然言語で判定させる**: 数値契約を欠くと再現性・検証可能性が失われる。
  診断は数値契約のみを提供し、説明生成は既存 LLM 層の責務に留める（[ADR 0002](0002-minsky-integration-design.md) 決定 4 と整合）。
- **崩壊時に例外送出**: 崩壊は Minsky モデルの主要な分析対象であり（[ADR 0002](0002-minsky-integration-design.md)）、
  `invalid` 区分としての系列表現を選ぶ。`NaN` 埋め経路と整合させる。

## 影響

- 後続実装 Issue は [診断設計](../models/minsky_regime_diagnostics.md) §6 の型・関数契約を
  追加の理論判断なしに実装できる。実装先は `src/models/keen.jl`（診断関数）で、
  `KeenModel` 本体・`Project.toml` への変更は発生しない見込み。
- 診断層は読み取り専用のため、既存の可視化・比較・LLM 層は無変更で動作する。
- methodology version `minsky-regime/1.0.0` を基準とし、境界定義・仮定・config スキーマを
  変更する際はバージョンを上げて provenance を保つ。
- 実データによる `amortization_rate` 推定・閾値校正・hysteresis の要否判断は実データ校正時に持ち越す。
