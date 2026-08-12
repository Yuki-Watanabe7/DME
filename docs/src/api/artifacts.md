# Artifact・品質Export層

正準 JSON・real-rate model artifact・Julia品質Export Contract（`src/artifacts/` / `src/quality/`）。

!!! note "対象ファイル一覧について"
    このページに載る docstring の対象ファイルは `docs/make.jl` が `src/` を走査して
    決めている（`DME_API_PAGES["artifacts"]`）。ソースファイルを追加してもこのページの
    記述を書き換える必要はない。

```@autodocs
Modules = [DME]
Pages = DME_API_PAGES["artifacts"]
```
