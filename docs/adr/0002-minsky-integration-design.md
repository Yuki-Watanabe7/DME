# ADR 0002: Keen モデルは既存インターフェース準拠・自前 RK4・LLM 層無拡張で統合する

- **ステータス**: 採用
- **日付**: 2026-07-16
- **関連Issue**: #99（ロードマップ）・#101（統合設計）
- **前提ADR**: [ADR 0001](0001-minsky-model-selection.md)（Keen モデル採用）
- **関連ドキュメント**: [Minsky系（Keen）モデル DME統合設計](../models/minsky_integration_design.md)

## コンテキスト

ADR 0001 で採用した Keen モデル（連続時間 3 変数 ODE 系）を DME に統合するにあたり、
(1) モデルインターフェースへの適合方法、(2) ODE ソルバーの調達方法、
(3) ショックの表現方法、(4) LLM 層の対応方法を決める必要がある。
DME の既存モデルはすべて離散時間（前向き反復・NLsolve・線形化）であり、
連続時間 ODE モデルは初めての追加となる。

## 決定

1. **`KeenModel <: AbstractMacroModel` として既存インターフェースにそのまま適合させる。**
   実装するのは `steady_state`（良い均衡の閉形式）・`simulate`（初期値からの時間発展）・
   `impulse_response`（均衡攪乱型）と meta 4 関数。`transition_path` は前向き期待を
   持たないモデルのため実装しない。`control_variables` は空（`VARModel` と同じ扱い）。

2. **ODE 数値積分は固定刻み RK4 を自前実装し、外部 ODE パッケージへの依存を追加しない。**
   数値オプションは `ODESolverOptions`（`substeps`・`guard_max`）として
   `src/core/solver_options.jl` に新設する。崩壊経路の発散は
   ガード条件（非有限値・`guard_max` 超過・`λ ≥ 1`）で打ち切り、残期間を `NaN` で埋める。

3. **ショックは「良い均衡の初期値攪乱」として設計し、水準系列を返す。**
   線形化した対数偏差 IRF は提供しない（双安定性というモデルの本質が失われるため）。
   パラメータ変更シナリオの比較は後続の分析機能Issueで扱う。

4. **LLM 層は既存構造の流用のみとし、新規の型・プロンプト分岐を追加しない。**
   必要な変更は `_MODEL_DOC_MAP` への 1 エントリ追加と、
   抽出規約（「LLM向け要約:」行・「目的」「限界」セクション）に準拠した
   `docs/models/keen.md` の作成のみ。

## 理由

- 3 変数・固定パラメータの非 stiff な ODE に対し、DifferentialEquations.jl 等の導入は
  依存管理コスト（[依存パッケージ管理](../development/dependency_management.md)）に見合わない。
  RK4 は刻み収束テストで精度を保証できる。
- 均衡値が閉形式で求まるため `steady_state` に数値求解が不要で、
  文献（Grasselli & Costa Lima 2012）の数値例をそのままテストアンカーにできる。
- `NamedTuple` 出力の規約を守ることで `to_simulation_result` / `plot_result` /
  `AnalysisContext` が無変更で動作し、可視化・LLM 層の変更を最小化できる。

## 見送りとした選択肢

- **DifferentialEquations.jl / OrdinaryDiffEq.jl の導入**: 適応刻み・stiff ソルバーは
  現時点で不要。将来 Ryoo 型拡張（fast-slow 構造）で必要になった場合に再検討する。
- **線形化 IRF（RBC の `shock` と同型）**: 良い均衡近傍の線形化は可能だが、
  双安定性・崩壊経路という Minsky モデルの主目的と相反するため採用しない。
- **崩壊時の例外送出**: 崩壊はエラーではなくモデルの主要な分析対象であるため、
  `NaN` 埋めによる系列としての表現を選ぶ。

## 影響

- `ODESolverOptions` は将来の連続時間モデル共通のオプション型となる。
- `SimulationResult` の変数系列に `NaN` が混入しうる（実データ系列の欠損と同じ扱い）。
  `summarize_result` の統計量は崩壊経路では `NaN` を含みうるため、
  分析機能側で崩壊判定を導入するまでは docstring で注意喚起する。
- 実装Issueの分割・変更ファイル一覧は統合設計 §7・§9 を参照。
