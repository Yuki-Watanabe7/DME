# シナリオ・イベント実行層

マクロイベントの4層概念階層・シナリオ・時間軸型（`src/scenarios/`）。

!!! note "対象ファイル一覧について"
    このページに載る docstring の対象ファイルは `docs/make.jl` が `src/` を走査して
    決めている（`DME_API_PAGES["scenarios"]`）。ソースファイルを追加してもこのページの
    記述を書き換える必要はない。

```@autodocs
Modules = [DME]
Pages = DME_API_PAGES["scenarios"]
```
