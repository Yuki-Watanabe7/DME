# パッケージ構成とアーキテクチャ概要

> 関連Issue: #53

---

## 1. ソースツリー

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

---

## 2. include 順序

`DME.jl` は以下の順でインクルードする。後続ファイルが前のファイルの定義に依存するため順序は固定。

1. `numerics/grids.jl`
2. `numerics/interpolation.jl`（`Interpo_Type` 列挙型を定義）
3. `core/model_interface.jl`
4. `core/solver_options.jl`（`Interpo_Type` を使用）
5. `models/ramsey.jl`
6. `models/rbc.jl`
7. `core/simulation_result.jl`（`RamseyModel`・`RBCModel` を使用）

新しいファイルを追加する際は、依存関係を確認してこの順序に挿入すること。

---

## 3. Node 型階層（`numerics/grids.jl`）

状態空間グリッドを抽象化する型ツリー。

```
AbstractNode1D
  ├── Node              # 任意ベクトル
  └── AbstractNode1DWithParam
        ├── ChebNode    # チェビシェフ節点
        └── RangeNode   # 等間隔格子

AbstractNode2D
  ├── Node2D
  └── RangeNode2D
```

---

## 4. 補間（`numerics/interpolation.jl`）

補間関数は `interpo(s, param)` で統一されており、`param` の型でディスパッチする。

| 型 | 補間方式 |
|---|---|
| `Cheb` | チェビシェフ多項式補間 |
| `LinInterpo` | 線形補間 |
| `CubicInterpo` | 三次スプライン補間 |

**2D 補間のメモリレイアウト**: 値ベクトル `V` は `permutedims(reshape(V, n2, n1))` で行列化する。
インデックス規則は `V[(i-1)*n2 + j]`（`i`: node1 インデックス、`j`: node2 インデックス）。

---

## 5. 各モデルの内部関数概要

### Ramsey モデル（`src/models/ramsey.jl`）

| 関数 | 役割 |
|---|---|
| `calc_ep` | 定常状態 (K*, C*) を解析的に計算 |
| `find_path` | `NLsolve` で有限期間 (T=30) の完全予見経路を求解 |
| `solve_by_nlvar` | 価値反復法（`optimize_c` で JuMP+Ipopt を使った 1D 最適化 → `update_policy` → `update_value` を繰り返し） |
| `simulate_by_nlvar` | `solve_by_nlvar` で得たポリシー関数を使って動学シミュレーション |

詳細は [Ramsey モデル解説](../models/ramsey.md) を参照。

### RBC モデル（`src/models/rbc.jl`）

| 関数 | 役割 |
|---|---|
| `calc_ep` | 定常状態 (A*, r*, w*, L*, K*, Y*, C*) を解析的に計算 |
| `find_path` | `NLsolve` で有限期間 (T=150) の完全予見経路を求解 |
| `solve_rbc` | 線形化（ブランチャード=カーン法）で遷移行列 A_A と状態-操作変数行列 P を返す |
| `shock` | `solve_rbc` の結果を使いインパルス応答を計算 |

詳細は [RBC モデル解説](../models/rbc.md) を参照。

---

## 6. 関連ドキュメント

- [モデル共通インターフェース設計方針](model_interface.md) — 抽象型階層・共通関数命名・新規モデル追加ルール
- [AIエコノミスト化アーキテクチャ](ai_economist.md) — 分析カーネル・データ層・LLM 層の層構成・データフロー
- [API リファレンス](../api.md) — Public/Internal API の一覧
