# ADR 0027: JSON3.jl から JSON.jl 1.x への移行

- **ステータス**: 採用
- **日付**: 2026-10-06
- **関連Issue**: [#300](https://github.com/Yuki-Watanabe7/DME/issues/300)（本決定）・[#295](https://github.com/Yuki-Watanabe7/DME/issues/295)（Julia 1.13.1 更新時に発見）
- **前提ADR**: [ADR 0008](0008-real-rate-model-artifact-export.md)（正準 JSON は自前実装・hash は正準 bytes から計算）

---

## コンテキスト

General registry が JSON3.jl を deprecated に指定した（理由 "This package is unmaintained."、代替 `JSON`）。DME は
JSON3 に直接依存し、使用箇所は 160 ファイル（`JSON3.read` 260・`JSON3.write` 146・`JSON3.pretty` 21）あった。
正準 JSON（RFC 8785）は `src/artifacts/json_canonical.jl` の自前実装で JSON3 に依存せず、artifact の content hash
はその bytes から計算する。

## 決定

**JSON.jl 1.x へ移行し、JSON3 への直接依存を除く。** 保守されない依存を残すと将来の Julia で壊れたときに直せず、
移行先（JSON.jl 1.10）はすでに間接依存として Manifest にあり追加の依存が増えないため。

1. 読み書きを `src/artifacts/json_io.jl` の `json_read` / `json_write` / `json_pretty` / `json_read_first` に集約し、
   呼び出し側は `JSON.parse` / `JSON.json` を直接呼ばない。以後 JSON ライブラリの差し替えはこの 1 ファイルで済む。
2. artifact の schema・contract version は変えない（non-goal）。

## 互換性の確認

移行前後の出力を、`Pkg.test()` の全呼び出し（`write` 数千件・`pretty` 80 件・`read` 数百件）で新旧突き合わせて確認した。

| 項目 | 結果 |
|---|---|
| 正準 JSON bytes・content hash | 変化なし。`canonical_json_bytes` は JSON ライブラリを使わず、artifact の hash は読み込み結果の Julia 値から計算する。commit 済み fixture の hash 検証・round-trip・replay テストが全て pass |
| `write` の内容 | 構造・値は全件一致。キー順と空白は異なりうる（hash に影響しない） |
| fail closed decode | 未知キー・hash 改変の検出は読み込み後の Dict に対する検査で、変更なし |

差分と対処:

| 差分 | JSON3 | JSON.jl | 対処 |
|---|---|---|---|
| 末尾の余分な文字 | 先頭の値だけ読んで受理 | `ArgumentError` | 厳格側へ変更（artifact・fixture は影響なし）。LLM 応答 parser だけ、応答の後ろに説明文が付くため `json_read_first` で従来の挙動を保つ |
| `1.0` の読み込み | `Int` に丸める | `Float64` | JSON.jl が正しい。型を前提にした検査が無いことをテストで確認 |
| 読み込み結果の型 | `JSON3.Object`（Symbol キー） | `JSON.Object{String,Any}`（`obj.key`・`obj[:key]`・`haskey(obj, :key)` も可） | `*_to_plain` の dispatch を `AbstractDict` / `AbstractVector` へ変更 |
| 空の `Vector{Union{}}` | `[]` | `{}` | `capex_calibration_to_dict` の `structural_override_keys` を `String[...]` で型を明示。他に該当なし（全テストで比較） |
| `pretty` の空コンテナ | `[\n    ]` | `[]` | 表記のみ。hash に影響しない |
| 行列（`Matrix`）の書き出し | 列優先の平坦配列 | 入れ子配列 | 全テストの突き合わせで該当なし（書く場合は入れ子配列を明示する） |
| `DateTime` | `"…T03:04:05.0"` | `"…T03:04:05"` | 全テストの突き合わせで該当なし |

## 結果

- `Project.toml` の deps・compat から JSON3 を除き `JSON = "1.10.0"` を追加。root・test・docs の Manifest を更新
  （JSON3・StructTypes が消え、3 つの Manifest の共有 entry は一致）。
- test / examples は `DME.json_read` などの alias を使う（`test/Project.toml` に JSON は無い）。
