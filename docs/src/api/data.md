# 実データ層

`DataSeries` / `MacroDataset`・前処理・FRED / e-Stat クライアント（`src/data/`）。

!!! note "対象ファイル一覧について"
    このページに載る docstring の対象ファイルは `docs/make.jl` が `src/` を走査して
    決めている（`DME_API_PAGES["data"]`）。ソースファイルを追加してもこのページの
    記述を書き換える必要はない。

```@autodocs
Modules = [DME]
Pages = DME_API_PAGES["data"]
```
