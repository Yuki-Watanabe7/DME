# ADR 0017: Documenter.jl の採用範囲とドキュメント品質Export

- **ステータス**: 採用
- **日付**: 2026-08-12
- **関連Issue**: [Yuki-Watanabe7/DME#213](https://github.com/Yuki-Watanabe7/DME/issues/213)
  （Parent Roadmap: [Yuki-Watanabe7/software-quality-dashboard#6](https://github.com/Yuki-Watanabe7/software-quality-dashboard/issues/6)）
- **関連ドキュメント**: [Julia品質Export Contract §4.5 / §8 方法F / §8.4](../contract/julia-quality-export-v1.md)・
  [ADR 0016: Julia品質Export Contract v1](0016-julia-quality-export-contract.md)（envelope の所有元）

## コンテキスト

DME には README・`docs/api.md`（約1,800行の人手整備 API リファレンス）・
`docs/architecture/**`・`docs/adr/**`・`docs/models/**` など78件の Markdown 文書と、
`src/**/*.jl` の約480件の docstring が存在するが、Documenter.jl による package
documentation build は導入されていなかった。

Issue #213 は「単に Documenter.jl を追加する」のではなく、**導入可否と対象範囲を先に決める**
ことを求めている。判断材料として次を実測した。

| 観測 | 値 |
|---|---|
| `docs/**` の Markdown 文書 | 78件（リポジトリ全体で85件） |
| Markdown 間の相対リンク | 約1,570件 |
| `src/**/*.jl` の docstring | 約480件（export された名前は399件） |
| `jldoctest` ブロック | 0件 |
| 全 docstring を1ページに載せた試行ビルドの警告 | 21件（うち17件が docstring からリポジトリ内文書への相対リンク、1件が未解決 `@ref`） |
| 試行ビルドの所要時間（依存解決・precompile 済み、ローカル） | 約15秒 |

さらに Consumer 側（`software-quality-dashboard` の
`backend/src/engineering_health/providers/julia/mapper.py`）は既に、ツール名
`Documenter.jl` の `result.build_status`（`success`/`warnings`/`failed` の3値）を
`julia.documentation_build_status` メトリクスへ写す実装を持っている。`Documenter.jl` を
導入しない場合、このメトリクスは恒久的に `UNAVAILABLE` のままになる。

## 決定

### 決定1: Documenter.jl を採用する。ただし「公開サイトの生成器」ではなく「docstring のビルド検査器」として

`docs/Project.toml`（Documenter + `Pkg.develop` した DME）・`docs/make.jl`・`docs/src/**` を
追加し、`makedocs` を CI で実行する。一方 `deploydocs` は呼ばず、GitHub Pages への公開は
行わない。生成物 `docs/build/` は検査の副産物として `.gitignore` する。

理由:

- ビルドの価値は **HTML の公開ではなく機械的検証**にある。docstring が Markdown として
  壊れていないか、`@ref` が解決するか、`@docs`/`@autodocs` が実在の binding を指しているか、
  export された名前の docstring がサイトから漏れていないか（`checkdocs = :exports`）は、
  Documenter でしか自動判定できない。実際に導入直後の初回ビルドで **未 docstring の
  export 定数を参照した未解決 `@ref` 1件と、docstring 内の到達不能な相対リンク17件**を
  検出し、いずれも修正した。
- 公開しないため、GitHub Pages の deploy 権限（`contents: write` / `DOCUMENTER_KEY`）を
  品質検査 job へ与える必要がない（Issue #213 設計上の注意「GitHub Pages deploy 権限を
  品質検査jobへ不要に付与しない」）。
- 公開しないため、人が読むドキュメントの正典は従来どおりリポジトリ内 Markdown
  （`docs/api.md` ほか）のままで、二重の「公開 API リファレンス」を維持する必要がない。

### 決定2: サイトの対象は `src/**/*.jl` の docstring のみとし、既存 Markdown は移行しない

`docs/src/` に置くのは landing page 1枚と、`src/` のディレクトリ構成に対応した API
リファレンス6ページ（`core`/`models`/`data`/`analysis`/`llm`/`artifacts`）のみとする。
`docs/**.md`（設計文書・ADR・分析文書）は Documenter へ移行しない。

理由:

- Issue #213 の対象外に「既存全Markdownの全面移行」が明記されており、設計上の注意にも
  「大量の既存文書を一括移行してPhase 1を肥大化させない」とある。
- 既存文書は `src/**.jl`・`.github/workflows/**` など **Markdown ではないリポジトリ内資産へも
  リンクしている**。Documenter はサイト内のページ間リンクしか解決できないため、一括移行すると
  それらが恒常的な警告になり、警告の総数が意味を失う。
- 設計文書は「読み物」であって package documentation ではない。生成 API リファレンスと同じ
  ナビゲーションへ混ぜる利得が小さい。

### 決定3: API ページの対象ファイル一覧を `docs/make.jl` が `src/` の走査で生成する

`@autodocs` の `Pages` は `docs/make.jl` の `DME_API_PAGES`（`src/` のサブディレクトリを
`readdir` して構築する辞書）を参照する。加えて、`src/` の全 `.jl` がいずれかのページ
グループへ割り当てられていることを `docs/make.jl` 自身が検査し、漏れがあればビルドを
失敗させる。

理由: ページ側にファイル一覧をハードコードすると、ソースファイルを追加したときに
docstring が**黙って**サイトから欠落する。`checkdocs = :exports` は export された名前しか
見ないため、内部関数の docstring の欠落は検出できない。走査＋割り当て漏れ検査で、
「新しいサブディレクトリを作ったらビルドが落ちて気づく」状態にする。

### 決定4: 初期導入では doctest を実行しない

`doctest = false` とする。`src/` に `jldoctest` ブロックが1件も無く（実測0件）、有効にしても
常に0件成功になるため、「実行して0件」と「そもそも対象が無い」を混同させないほうがよい。
docstring の例を `jldoctest` へ移行するかは本 ADR の範囲外とし、必要になった時点で別 Issue
で判断する（設定は `docs/make.jl` の `DME_DOCS_DOCTEST` 1箇所で切り替わる）。

### 決定5: 外部リンクの到達性検査（`linkcheck`）を行わない

`linkcheck = false` とする。ネットワーク到達性・レート制限・外部サイトの一時障害が
ビルドの成否へ混入すると、CI の結果が「DME のドキュメントの状態」を表さなくなる。
`warnonly` にも `:linkcheck`/`:linkcheck_remotes` を明示的に列挙し、将来有効化した場合でも
ネットワーク要因がビルド失敗の理由にならないことを設定として固定する。

### 決定6: warning を無条件に失敗へ昇格させず、Documenter エラークラスごとに方針を決める

`warnonly = [:cross_references, :linkcheck, :linkcheck_remotes]` とし、それ以外のクラス
（`:autodocs_block`・`:docs_block`・`:doctest`・`:eval_block`・`:example_block`・
`:footnote`・`:meta_block`・`:missing_docs`・`:parse_error`・`:setup_block`）はビルド失敗と
して扱う。

- 失敗側に置いたクラスは「サイトを正しく生成できない」ことを意味し、リポジトリ内で完結し
  決定的かつ修正方法が一意である。
- `:cross_references` を警告へ降格するのは、docstring がサイト外のリポジトリ内文書を参照
  することが正当な運用としてあり、Documenter からは常に「サイト外リンク」に見えるため。
  件数とカテゴリは export に残るので不可視化はしない（#209/#211/#212 と同じ advisory 方針）。

### 決定7: ドキュメントビルドの失敗は「ツール実行の失敗」ではない

`build_status = "failed"` でも `QualityToolExecution.status` は `:success` とする
（＝ビルドを実行して失敗を観測できた）。`:failure`/`:timeout`/`:not_installed` は
worker がビルド結果自体を出せなかった場合に限る。

理由: Issue #213 は「build failure時にもvalid partial exportを残す」と「tool crash/未導入を
成功扱いしない」を同時に要求している。両者は「測定できたか」と「測定対象が健全か」という
別の軸であり、`status` と `result.build_status` の2層へ分けることで構造的に区別できる。

### 決定8: カテゴリ別件数を取得できない場合は `null` にする（全カテゴリ0件と区別する）

カテゴリ別件数は `makedocs(debug = true)` が返す `Documenter.Document` の
`internal.errors` から取り出す。ビルドが例外で終わると `Document` が得られないため、
その場合 `categories` は `null` とし、`{"cross_references": 0, ...}` のような
「全カテゴリ0件」とは構造的に区別する（`baseline_missing` を `stable` と区別する
[BenchmarkTools.jl の契約](../contract/julia-quality-export-v1.md#44-benchmarktoolsjl-の-result)と同じ考え方）。

### 決定9: docs lane は slow lane ではなく、docs/src 変更で起動する独立 workflow とする

`.github/workflows/docs.yml`（`pull_request`/`push` の `paths` トリガー ＋
`workflow_dispatch`）を新設し、`ci.yml`（fast lane）とも `quality-slow.yml`（slow lane）とも
独立した job・export ファイル（`quality-export-docs.json`）・Artifact
（`dme-julia-quality-v1-docs-<sha>`）として運用する。

理由:

- `ci.yml` は `paths-ignore: docs/**, **/*.md` を持つため、docs のみの変更は現状まったく
  CI 検査を受けない。workflow 単位のトリガー条件は job を足しても変えられないので、別
  workflow が必要（Issue #213 設計上の注意への直接の回答）。
- slow lane（schedule/workflow_dispatch のみ）へ置くと、docs を変更した PR をその場で
  検査できない。ビルド自体は約15秒と軽く、slow lane に置く理由が無い。
- 独立 workflow にすることで、通常の Julia テストとは別の failure reason を保持できる
  （Issue #213 実施内容）。

### 決定10: ビルド失敗は CI の失敗として扱う。warning は扱わない

docs workflow は `build_status = "failed"`、および測定自体ができなかった場合
（`status` が `failure`/`timeout`/`not_installed`）に job を失敗させる。
`build_status = "warnings"` では失敗させず、GitHub Actions の `::warning::` として出す。

理由: ビルド失敗は「閾値を満たさない」ではなく「ドキュメントがビルドできない」という
コンパイルエラー相当の二値の欠陥であり、roadmap の「初期運用では品質閾値でmergeを阻止せず、
実データ蓄積と安定性確認を優先する」が対象とする閾値判定には当たらない。どのカテゴリを
ビルド失敗とするかの判断は決定6が既に行っており、workflow 側でそれを二重に上書きしない。

なお `scripts/quality_export_docs.jl`（driver）自体の終了コードは他の lane と同様に常に0で、
成否の判定は workflow のステップが担う（export を必ず書き出すため）。

### 決定11: 生成 HTML のサイズ閾値を明示的に引き上げる

`size_threshold_warn = 512KiB`・`size_threshold = 1MiB` を明示する（Documenter の既定は
100KiB 警告 / 200KiB エラー）。

理由: 既定値は公開サイトの読み手の体験を守るための値であり、公開しない DME（決定1）には
当てはまらない。既定のままだと最大ページ（`api/analysis.md`、約236KiB）が恒常的に警告・
エラーを出し続け、**本当の警告を覆い隠す**。一方で閾値を撤廃はせず、現状の2〜3倍を上限と
して「テンプレート展開の暴走のような病的な肥大化だけを捕まえる」役割に限定する。

## 見送りとした選択肢

### Documenter.jl を導入せず、代替の機械的検査に置き換える

Issue #213 は非採用の場合の代替として「Markdown local link validation」「documentation
index consistency」「public API/docstring coverage の代替計測」を挙げている。これらは
実際に有用（試作した Markdown 相対リンク検査は `docs/api.md` の壊れたリンク3件を検出し、
本 PR で修正した）だが、**Documenter の代替にはならない**:

- Consumer 側が `Documenter.jl` の `build_status` を前提に実装済みであり、別名のツールを
  出しても `julia.documentation_build_status` は `UNAVAILABLE` のままになる。
- docstring の Markdown 構文エラー・未解決 `@ref`・存在しない binding への `@docs` 参照は、
  リンク検査では検出できない。

したがって Documenter を採用した。リポジトリ全体の Markdown 相対リンク検査を独立した
ツールとして品質Export へ追加するかは、本 Issue の範囲外として別途判断する
（本 PR では `docs/api.md` の実在の破損3件のみ手当てした）。

### 既存 Markdown を `docs/src/` へ一括移行し、Documenter にリンク検査させる

決定2の理由のとおり、リポジトリ内の非 Markdown 資産へのリンクが恒常的な警告になるため
見送った。

### `docs/make.jl` ではなく `scripts/` にビルド入口を置く

CLAUDE.md のリポジトリ構成上 `scripts/` は CI/tooling 用スクリプトの置き場だが、
`docs/make.jl` + `docs/Project.toml` + `docs/src/` は Julia エコシステムの強い慣習であり、
外部ツール（`julia-actions/*` など）もこの配置を前提にする。慣習に合わせ、`docs/` 直下に
Documenter 用の3点を置き、その旨を CLAUDE.md のリポジトリ構成表へ明記した。

### docs lane の export を fast lane / slow lane の export へマージする

JET.jl（#211）・BenchmarkTools.jl（#212）と同じく、別ファイル・別 Artifact のままとした。
実行タイミングもトリガー条件も異なるため、1ファイルへまとめると
「1ファイル=1コミットに対する1回の実行」（契約 §1）が崩れる。

## 影響

- `docs/Project.toml`/`docs/Manifest.toml` という4つ目の Julia 環境が増える
  （root / test / docs、加えて `scripts/format.sh` の一時環境）。docs 環境の依存を
  変更した場合は `julia --project=docs -e 'using Pkg; Pkg.instantiate()'` を実行し
  `docs/Manifest.toml` もコミットする（CLAUDE.md 作業ルールへ追記）。
- `src/**` の変更でも docs workflow が動く（docstring は `src/` にあるため）。`ci` job とは
  別 job のため、通常CIの所要時間そのものは延びない。
- docstring からリポジトリ内文書への相対リンク24件を絶対 GitHub URL へ置き換えた。
  REPL の `?` ヘルプでも Documenter サイトでも解決するようになる代わりに、**リンク先の
  文書をリネームしても機械的には検出されない**（`main` ブランチ固定の URL であるため）。

## 限界

- Documenter のビルド成功は「全ドキュメントが正しい」ことを意味しない。検証されるのは
  サイトに載る docstring の構文・参照解決・サイト内リンクだけであり、`docs/**.md` の
  78文書の内容・相互リンク・鮮度は一切検査されない。
- 自然言語としての正確性・説明の妥当性は評価対象外（Issue #213 の対象外）。
- `categories` はビルドが例外で終わると取得できない（決定8）。その場合でも件数
  （`warnings`/`errors`）と `messages` は残る。
- `messages` は上限50件・1件1,000文字の抜粋であり、全 warning の完全なログではない
  （件数の正本は `warnings`/`errors`）。
- docs workflow は `paths` トリガーであるため、`paths` に列挙されていないファイルの変更で
  docstring 参照が壊れた場合（例: 依存パッケージの更新のみを含む変更）は、その PR では
  検査されない。
- GitHub Pages への公開・バージョン付きドキュメントの配信・`deploydocs` の設定は本 ADR の
  範囲外（決定1）。公開する判断をする場合は deploy 権限の扱いを含めて別 ADR で決める。
