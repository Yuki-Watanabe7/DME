# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands

```bash
# パッケージのインストール・依存解決
julia --project=. -e "using Pkg; Pkg.instantiate()"

# テスト全体を実行
julia --project=. -e "using Pkg; Pkg.test()"

# 特定のテストセットのみ実行（例: util のみ）
julia --project=. -e '
  using DME, Test
  @testset "util" begin
    # test/runtests.jl の対象ブロックをペースト
  end
'

# REPL で動作確認
julia --project=.
# julia> using DME
# julia> m = RamseyModel(0.3, 0.99, 0.25)
# julia> calc_ep(m)
```

## パッケージ構成

Julia パッケージ。`src/DME.jl` がモジュールのエントリポイント。`src/` 配下は責務別に以下のサブディレクトリへ分離されている。

```text
src/
  DME.jl
  numerics/
    grids.jl          # Node/Grid 型階層とグリッドユーティリティ
    interpolation.jl  # 補間型（Cheb/線形/三次スプライン）と interpo 関数群
  core/
    model_interface.jl   # AbstractMacroModel インターフェース定義
    solver_options.jl    # SolverOptions / ValueIterationOptions
    simulation_result.jl # SimulationResult（モデル横断的な結果型）
  models/
    ramsey.jl  # Ramsey モデル実装
    rbc.jl     # RBC モデル実装
```

### include 順序

`DME.jl` は以下の順でインクルードする。後続ファイルが前のファイルの定義に依存するため順序は固定。

1. `numerics/grids.jl`
2. `numerics/interpolation.jl`（`Interpo_Type` 列挙型を定義）
3. `core/model_interface.jl`
4. `core/solver_options.jl`（`Interpo_Type` を使用）
5. `models/ramsey.jl`
6. `models/rbc.jl`
7. `core/simulation_result.jl`（`RamseyModel`・`RBCModel` を使用）

## アーキテクチャ概要

### Node 型階層（`numerics/grids.jl`）

状態空間グリッドを抽象化する型ツリー。

- `AbstractNode1D` → `Node`（任意ベクトル）, `AbstractNode1DWithParam` → `ChebNode`, `RangeNode`
- `AbstractNode2D` → `Node2D`, `RangeNode2D`

### 補間（`numerics/interpolation.jl`）

補間関数は `interpo(s, param)` で統一されており、`param` の型（`Cheb`, `LinInterpo`, `CubicInterpo` など）でディスパッチする。

- 2D 補間では V（値ベクトル）を `permutedims(reshape(V, n2, n1))` で行列化する。レイアウトは `V[(i-1)*n2 + j]`（i: node1 インデックス、j: node2 インデックス）。

### Ramsey モデル（`models/ramsey.jl`）

- `calc_ep` → 定常状態 (K*, C*) を解析的に計算
- `find_path` → `NLsolve` で有限期間 (T=30) の完全予見経路を求解
- `solve_by_nlvar` → 価値反復法（`optimize_c` で JuMP+Ipopt を使った 1D 最適化 → `update_policy` → `update_value` を繰り返し）
- `simulate_by_nlvar` → `solve_by_nlvar` で得たポリシー関数を使って動学シミュレーション

### RBC モデル（`models/rbc.jl`）

- `calc_ep` → 定常状態 (A*, r*, w*, L*, K*, Y*, C*) を解析的に計算
- `find_path` → `NLsolve` で有限期間 (T=150) の完全予見経路を求解
- `solve_rbc` → 線形化（ブランチャード=カーン法）で遷移行列 A_A と状態-操作変数行列 P を返す
- `shock` → `solve_rbc` の結果を使いインパルス応答を計算

## 品質チェック

テストスイート（`Pkg.test()`）に以下の品質チェックが組み込まれており、CIで自動実行される。

### 導入済みチェック

| ツール | 目的 | 実行方法 |
|--------|------|----------|
| **Aqua.jl** | パッケージ品質（exports・依存互換性・stale deps・型海賊行為等）| `Pkg.test()` に含まれる |
| **JuliaFormatter** | コードフォーマット統一（`.JuliaFormatter.toml` の設定を使用）| 下記参照 |

### 見送ったチェック

| ツール | 理由 |
|--------|------|
| **JET.jl** | 数値計算コードでの誤検知が多く CI が不安定化するリスクあり。Phase 2 以降で再検討 |

### JuliaFormatter の手動実行

```bash
# フォーマット確認（変更なし）
julia --project=. -e "using JuliaFormatter; format(\"src/\"; overwrite=false) ? println(\"OK\") : println(\"要フォーマット\")"

# フォーマット適用
julia --project=. -e "using JuliaFormatter; format(\"src/\")"
```

## 依存パッケージの注意点

- **JuMP 1.x**: `optimize_c` では `@operator` + `@objective` を使用。`with_optimizer` / `@NLobjective` は使わない（削除済み）。
- **Interpolations 0.13+**: `cubic_spline_interpolation`（小文字）を使用。`CubicSplineInterpolation` は非推奨。
- **NLsolve**: `nlsolve(f, x0).zero` で解ベクトルを取得するパターン。
