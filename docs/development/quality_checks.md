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

---

## 3. 導入を見送ったチェック

| ツール | 理由 |
|--------|------|
| **JET.jl** | 数値計算コードでの誤検知が多く CI が不安定化するリスクあり。必要になった時点で再検討 |

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
