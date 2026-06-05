# 依存パッケージ管理と注意点

> 関連Issue: #53

---

## 1. 主要依存パッケージの注意点

### JuMP 1.x

`optimize_c` では `@operator` + `@objective` を使用する。

```julia
# 正しい（JuMP 1.x）
@operator(model, op_u, 1, u)
@objective(model, Max, op_u(c))

# 使わない（削除済み）
with_optimizer(...)     # 旧API
@NLobjective(...)       # 旧API
```

### Interpolations 0.13+

`cubic_spline_interpolation`（小文字）を使用する。

```julia
# 正しい
cubic_spline_interpolation(xs, ys)

# 使わない（非推奨）
CubicSplineInterpolation(xs, ys)
```

### NLsolve

`nlsolve(f, x0).zero` で解ベクトルを取得する。

```julia
result = nlsolve(f, x0)
solution = result.zero  # 解ベクトル
```

---

## 2. Project.toml / Manifest.toml の管理

### Project.toml を変更した場合

```bash
# 依存関係の整合性を確認・更新
julia --project=. -e 'using Pkg; Pkg.resolve()'
```

`Pkg.resolve()` 実行後、`Manifest.toml` が更新された場合は両方をコミットすること。

### Manifest.toml の扱い方針

- `Manifest.toml` はリポジトリに含める（再現性確保のため）
- `Project.toml` を変更したら必ず `Pkg.resolve()` を実行し、`Manifest.toml` との整合性を確認する

### 依存パッケージを追加する場合

```bash
# REPL で追加
julia --project=.
# julia> using Pkg; Pkg.add("NewPackage")

# Project.toml と Manifest.toml をコミット
git add Project.toml Manifest.toml
git commit -m "Add NewPackage dependency"
```

---

## 3. 関連ドキュメント

- [品質チェックとローカル検証手順](quality_checks.md) — テスト実行・フォーマット確認
- [API リファレンス](../api.md) — Public API 一覧
