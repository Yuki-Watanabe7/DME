# docs/make.jl
#
# Documenter.jl のビルド入口（Issue #213）。DME は Documenter を **公開サイトの生成器**
# としてではなく **docstring のビルド検査器** として採用している（ADR 0017）。
# GitHub Pages への deploy は行わない（`deploydocs` を呼ばない）。生成物 `docs/build/` は
# 検査の副産物であり、公開されるドキュメントは従来どおりリポジトリ内の Markdown
# （`docs/**.md`、正典は `docs/api.md`）である。
#
# ## このファイルの2つの使われ方
#
#   1. スタンドアロン実行（人手・ローカル検証）:
#        julia --project=docs -e 'using Pkg; Pkg.instantiate()'
#        julia --project=docs docs/make.jl
#      ビルドが失敗すれば非ゼロ終了する。
#
#   2. 品質Export の worker からの `include`（`scripts/docs_build_worker.jl`）:
#      `dme_build_docs(; debug = true)` を呼び、返ってきた `Documenter.Document` の
#      `internal.errors`（`@docerror` のタグ列）と、worker 側が仕掛けたロガーの
#      warning/error 件数から `julia-quality-export/v1` の `Documenter.jl` セクションを
#      組み立てる（docs/contract/julia-quality-export-v1.md §4.5）。
#      そのため **ビルド設定はこのファイル1箇所にのみ置き**、worker 側で別の設定を
#      組み立てない（人手のローカル実行と CI の測定が同じ設定であることを構造的に保証する）。
#
# ## サイトに載せる対象
#
# `src/**/*.jl` の docstring のみ。`docs/**.md`（設計文書・ADR・分析文書）は Documenter へ
# 移行しない（Issue #213 の対象外「既存全Markdownの全面移行」。理由は ADR 0017 §決定2）。
# API ページの `Pages` 一覧はこのファイルが `src/` を実際に走査して生成するため、
# ソースファイルを追加してもページ側の記述を書き換える必要はない（下記
# `DME_API_PAGES` と、全 `.jl` を必ずいずれかのグループへ割り当てる健全性検査）。

using Documenter
using DME

const DME_DOCS_ROOT = @__DIR__
const DME_REPO_ROOT = normpath(joinpath(DME_DOCS_ROOT, ".."))
const DME_SRC_ROOT = joinpath(DME_REPO_ROOT, "src")

#: `makedocs(warnonly = ...)` へ渡す「警告へ降格する」Documenter エラークラス。
#: ここに無いクラスはビルド失敗（`build_status = "failed"`）になる。
#: カテゴリごとの方針の根拠は docs/contract/julia-quality-export-v1.md §4.5
#: 「warning category ごとの方針」。
#:
#:   - `:cross_references`: docstring はサイト外のリポジトリ内文書（`docs/**.md`）を参照する
#:     ことがあり、Documenter からは常に「サイト外への link」に見える。初期段階で
#:     merge を止める理由にはせず、件数と内容を export へ残す（#209/#211/#212 と同じ
#:     advisory 方針）。
#:   - `:linkcheck` / `:linkcheck_remotes`: `linkcheck = false` のため発火しないが、
#:     「ネットワーク到達性をビルド失敗の理由にしない」という方針を明示するために列挙する。
const DME_DOCS_WARNONLY = [:cross_references, :linkcheck, :linkcheck_remotes]

#: doctest の実行有無。初期導入では `false`（`src/` に `jldoctest` ブロックが1件も無く、
#: 実行しても常に0件成功になるため）。導入判断は ADR 0017 §決定4。
const DME_DOCS_DOCTEST = false

#: 外部リンクの到達性検査。CI の決定性（ネットワーク・レート制限に依存しない）を優先して
#: 無効にする。ADR 0017 §決定5。
const DME_DOCS_LINKCHECK = false

#: 生成 HTML 1ページのサイズ上限（警告 / エラー）。Documenter の既定（100KiB 警告 /
#: 200KiB エラー）は「公開サイトの読み手の体験」を守るための値であり、DME は
#: このサイトを公開しない（ADR 0017）ため、そのまま適用すると分割の必然性が無いまま
#: 恒常的な warning が出続けて **本当の warning を覆い隠す**。現状の最大ページ
#: （`api/analysis.md`、約236KiB）の2〜3倍を上限として明示し、「病的な肥大化
#: （テンプレート展開の暴走など）だけを捕まえる」役割に限定する。
const DME_DOCS_SIZE_THRESHOLD_WARN = 512 * 1024
const DME_DOCS_SIZE_THRESHOLD = 1024 * 1024

#: `checkdocs`。`:exports` は「`DME` が export している名前の docstring が
#: サイトのどのページにも載っていない」場合にエラーにする。API ページの `Pages` 一覧は
#: `src/` の走査で自動生成されるため通常は発火しないが、`src/` 直下に新しいサブ
#: ディレクトリを作って `DME_API_GROUPS` へ割り当て忘れた場合の二重の防御になる。
const DME_DOCS_CHECKDOCS = :exports

"""
    _dme_src_jl_files(subdir) -> Vector{String}

`src/<subdir>` 直下の `.jl` ファイルを `"<subdir>/<file>.jl"` 形式で返す（`subdir == ""`
のときは `src/` 直下）。`@autodocs` の `Pages` は docstring のソースファイルパスに対する
`endswith` 判定なので、この相対パス形式でそのまま渡せる。
"""
function _dme_src_jl_files(subdir::AbstractString)
    dir = isempty(subdir) ? DME_SRC_ROOT : joinpath(DME_SRC_ROOT, subdir)
    files = sort!(filter(f -> endswith(f, ".jl"), readdir(dir)))
    return [isempty(subdir) ? f : joinpath(subdir, f) for f in files]
end

"""`src/` 配下のサブディレクトリ（`.jl` を含むもの）と `src/` 直下を全て列挙する。"""
function _dme_src_subdirs()
    dirs = String[""]
    for entry in sort!(readdir(DME_SRC_ROOT))
        path = joinpath(DME_SRC_ROOT, entry)
        isdir(path) || continue
        any(endswith(f, ".jl") for f in readdir(path)) && push!(dirs, entry)
    end
    return dirs
end

#: API ページのグループ定義（ページ名 => (表示名, 対象 `src/` サブディレクトリ)）。
#: `src/` のディレクトリ構成（docs/architecture/package_structure.md）に対応させる。
#: 全 docstring を1ページへ載せると生成 HTML が約500KiB になり読みにくいため、
#: ソースの構成と同じ単位で分割している（サイズ上限そのものは
#: `DME_DOCS_SIZE_THRESHOLD*` で別途明示している）。
const DME_API_GROUPS = [
    ("core", "コアインターフェース", ["", "core", "numerics"]),
    ("models", "モデル", ["models"]),
    ("scenarios", "シナリオ・イベント実行層", ["scenarios"]),
    ("data", "実データ層", ["data"]),
    ("analysis", "分析・診断層", ["analysis", "sfc"]),
    ("llm", "LLM層", ["llm"]),
    ("artifacts", "Artifact・品質Export層", ["artifacts", "quality"]),
]

#: `@autodocs` ブロックの `Pages` として参照される（`Pages` は `Main` 上で評価される）。
const DME_API_PAGES = Dict{String, Vector{String}}(
    name => reduce(vcat, _dme_src_jl_files.(dirs)) for (name, _, dirs) in DME_API_GROUPS
)

# 健全性検査: `src/` の全 `.jl` がいずれかのグループへ割り当てられていること。
# 新しいサブディレクトリを追加して `DME_API_GROUPS` の更新を忘れると、その docstring が
# 黙ってサイトから欠落する（`checkdocs` は export された名前しか見ない）。ここで
# 明示的に落とす。
let assigned = Set(Iterators.flatten(values(DME_API_PAGES))),
    all_files = Set(Iterators.flatten(_dme_src_jl_files.(_dme_src_subdirs())))

    missing_files = sort!(collect(setdiff(all_files, assigned)))
    isempty(missing_files) || error(
        "docs/make.jl: 次の src/ ファイルが DME_API_GROUPS のどのグループにも " *
        "割り当てられていません（API ページから欠落します）: " *
        join(missing_files, ", "),
    )
end

"""
    dme_build_docs(; debug = false)

DME の Documenter ビルドを実行する。`debug = true` のとき `Documenter.Document` を返す
（`scripts/docs_build_worker.jl` が `document.internal.errors` からカテゴリ別件数を取り出す）。

ビルド設定（対象・warning方針・doctest/linkcheck の有無）はすべてこの関数に集約する。
"""
function dme_build_docs(; debug::Bool = false)
    return makedocs(;
        # `root` の既定値は `Base.source_dir()`（＝いま include 中のファイルの場所）という
        # 動的スコープの値で、`scripts/docs_build_worker.jl` から本ファイルを include して
        # 後から `dme_build_docs()` を呼ぶと `scripts/` を指してしまう。明示して固定する。
        root = DME_DOCS_ROOT,
        sitename = "DME",
        modules = [DME],
        authors = "Yuki Watanabe",
        # git remote の自動検出に依存させない（CI の shallow clone・fork でも同じ結果に
        # なるようにする）。
        repo = Documenter.Remotes.GitHub("Yuki-Watanabe7", "DME"),
        format = Documenter.HTML(;
            # deploy しないため、ローカルで `docs/build/*.html` をそのまま開ける形にする。
            prettyurls = false,
            edit_link = "main",
            size_threshold_warn = DME_DOCS_SIZE_THRESHOLD_WARN,
            size_threshold = DME_DOCS_SIZE_THRESHOLD,
        ),
        pages = [
            "ホーム" => "index.md",
            "API リファレンス" => ["api/$(name).md" for (name, _, _) in DME_API_GROUPS],
        ],
        checkdocs = DME_DOCS_CHECKDOCS,
        doctest = DME_DOCS_DOCTEST,
        linkcheck = DME_DOCS_LINKCHECK,
        warnonly = DME_DOCS_WARNONLY,
        debug = debug,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    dme_build_docs()
    println("Documenter build complete -> ", joinpath(DME_DOCS_ROOT, "build"))
end
