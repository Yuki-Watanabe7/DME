# 品質チェックとローカル検証手順

> 関連Issue: #53

---

## 1. 自動品質チェック（CI）

テストスイート（`Pkg.test()`）に以下の品質チェックが組み込まれており、CI で自動実行される。

| ツール | 目的 | 実行方法 |
|--------|------|----------|
| **Aqua.jl** | パッケージ品質（exports・依存互換性・stale deps・型海賊行為等）| `Pkg.test()` に含まれる |
| **JuliaFormatter** | コードフォーマット統一（`.JuliaFormatter.toml` の設定を使用）| 下記参照 |

---

## 2. JuliaFormatter の手動実行

```bash
# フォーマット確認（変更なし）
julia --project=. -e "using JuliaFormatter; format(\"src/\"; overwrite=false) ? println(\"OK\") : println(\"要フォーマット\")"

# フォーマット適用
julia --project=. -e "using JuliaFormatter; format(\"src/\")"
```

コードを変更した場合は PR 前にフォーマットを確認すること。
フォーマット設定は `.JuliaFormatter.toml` に記載されている。

上記コマンドは `--project=.`（メインの依存関係環境）で実行しているように見えるが、
`Aqua` / `JuliaFormatter` / `Test` は `test/Project.toml` のテスト専用環境に属する。
実際に使われるバージョンは `test/Manifest.toml` で固定されている（[2.1 節](#21-テスト依存のバージョン固定)参照）。

---

### 2.1 テスト依存のバージョン固定

`Aqua` / `JuliaFormatter` / `Test` は `test/Project.toml` で宣言し、`test/Manifest.toml` で
解決済みバージョンを固定している。これにより `Pkg.test()` は常に同じバージョンの
`JuliaFormatter` を使用し、上流のマイナー/パッチリリースでフォーマットルールが変わっても
CI が予告なく壊れることを防ぐ。

`test/Project.toml` の `[deps]` のうち、ルート `Project.toml` の `[deps]` に含まれない
パッケージ（= テスト専用依存）は、ルートの `[extras]` / `[targets]` と一致していなければ
ならない（`Aqua.test_all` の `project_extras` チェックが検証する）。テスト専用依存を
追加・変更する場合は両方を更新すること。

なお `Plots` のようにルート `Project.toml` の `[deps]` に既に含まれるパッケージは、
テストコードから直接 `using Plots` する場合のみ `test/Project.toml` にも追加する
（`test/Project.toml` が存在すると、テスト環境はルート環境をスタックしないため）。

```bash
# テスト依存を更新した場合、test/Manifest.toml を再生成する
julia --project=test -e 'using Pkg; Pkg.instantiate()'
# または特定パッケージだけバージョンを上げる場合
julia --project=test -e 'using Pkg; Pkg.update("JuliaFormatter")'

git add test/Project.toml test/Manifest.toml
```

`JuliaFormatter` を更新した際は、新バージョンのルールで `src/` 全体が
フォーマット済みかを必ず確認すること（2 節のコマンド）。

---

## 3. 導入を見送ったチェック / 無効化したチェック

| ツール | 理由 |
|--------|------|
| **JET.jl** | 数値計算コードでの誤検知が多く CI が不安定化するリスクあり。必要になった時点で再検討 |
| **Aqua.jl の `persistent_tasks`** | DME は JuMP・Ipopt・Plots など重量級のバイナリ依存を持つ。このチェックは独立した一時プロジェクトで DME を再解決・再プリコンパイルするサブプロセスを spawn するため、メインテストプロセスと同時実行時に CI ランナーのメモリ/CPU 制約でサブプロセスが完了前にクラッシュし、CI が不安定化する（ローカルでは安定して成功する）。`test/test_quality.jl` で `persistent_tasks = false` により無効化 |

---

## 4. テスト実行

```bash
# 全テスト実行
julia --project=. -e "using Pkg; Pkg.test()"

# 特定のテストセットのみ実行（例）
julia --project=. -e '
  using DME, Test
  @testset "util" begin
    # test/runtests.jl の対象ブロックをペースト
  end
'
```

### テスト実行が必要な変更種別

以下を変更した場合はフルセットの検証は行わないが、少なくとも変更対象のコードや関数に対する簡単なsmoke testを行う。可能であれば、対象テストセット相当の最小確認も行う。(フルセットの検証はPR時のCIで行う。)

- Julia コード（`src/` 配下）
- `Project.toml` / `Manifest.toml`
- テストコード（`test/` 配下）
- CI 設定（`.github/workflows/` 配下）

### テスト実行が不要な変更種別

- `docs/` 配下のみの変更（docs-only）

docs-only の変更をする場合は、PR 本文または最終コメントに「docs-only のため Julia test は未実行」と明記すること。

---

## 5. `software-quality-dashboard` 向け構造化Export（任意）

`Pkg.test()`（Aqua.jl・JuliaFormatter を含む）1回の実行結果を、`software-quality-dashboard` が
読み取る `julia-quality-export/v1` として機械可読な JSON へ書き出せる（既定では無効。CI の
通常の合否判定には影響しない）。

```bash
DME_QUALITY_EXPORT_ENABLED=1 julia --project=. -e "using Pkg; Pkg.test()"
# 既定出力先: artifacts/quality/quality-export.json（DME_QUALITY_EXPORT_OUTPUT で変更可能）
```

詳細（result 構造・Test.jl 依存の設計判断・限界）は
[Julia品質Export Contract](../contract/julia-quality-export-v1.md) を参照。
