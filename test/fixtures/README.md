# test/fixtures の出典区分

`test/fixtures/` 以下のファイルは、すべて public リポジトリの一部として公開されます。
[ADR 0028](../../docs/adr/0028-public-repository-scope.md) に従い、各ファイルは次のいずれか1つの出典区分を持ちます。

| 区分 | 意味 |
|---|---|
| `synthetic` | 架空の値、またはコードで決定的に生成した値。synthetic な入力から再生成した golden 出力と契約サンプルを含みます。 |
| `public-statistics-derived` | 公的機関が公表した統計を基にした値です。近似値や改訂前の値を含みます。 |
| `withheld` | 再配布条件を確認していない実データです。データ本体は commit せず、識別用のメタデータだけを commit します。 |

`test/test_public_repository_hygiene.jl` は、`test/fixtures/` 直下の各ディレクトリが下の表に載っていることを検査します。

## ディレクトリ別の区分

| ディレクトリ | 区分 | どこに明示しているか |
|---|---|---|
| `calibration/` | synthetic | 合成した observation dataset を逆較正した結果の golden です（`test/test_capex_credit_cycle_calibration.jl` 冒頭の fixture）。 |
| `capex_credit_cycle/` | synthetic | 各ファイルの `source.description` に「実データではなく」と書いています。 |
| `data/` | synthetic | `capex_credit_cycle/` は `catalog.json` の `source` が "Test Statistical Agency" です。`financial_stress/series/` の8系列は `name` に "(fictional test fixture)" と書いています。 |
| `estat/` | **public-statistics-derived** | 下の「e-Stat 形式の4表」を参照してください。 |
| `events/` | synthetic | 各ファイルの `source.description` に「synthetic fixture」「fictional」と書いています。 |
| `fred/` | **public-statistics-derived**（5系列）と synthetic（2系列） | 下の「FRED 形式の5系列」を参照してください。DRTSCILM・NFCI の2系列は title に "fixture illustrative values, not real observations" と書いています。 |
| `japan_fiscal/` | synthetic | [`japan_fiscal/README.md`](japan_fiscal/README.md) を参照してください（FRE context は架空の snapshot です）。 |
| `keen/` | synthetic | 4系列とも、Keen 実証の fixture 経路のために決定的に生成した値です（#120）。title に "synthetic fixture values, not real observations" と書いています。 |
| `llm/` | synthetic | 固定の LLM 応答です。[`llm/keen_empirical/README.md`](llm/keen_empirical/README.md) と [`llm/keen_sfc/README.md`](llm/keen_sfc/README.md) を参照してください。 |
| `pne/` | synthetic と **withheld** | `producer/` と `sector_output_path/` は架空の経済です（各 README）。`official_jp/` は withheld で、公式 Japan IO 表の identity metadata だけを commit しています（[`pne/official_jp/README.md`](pne/official_jp/README.md)）。`golden/` と `mappings/` は、これらから再生成した出力です。 |
| `quality_export/` | synthetic | DME が所有する `julia-quality-export/v1` 契約のサンプルです。 |
| `scenarios/` | synthetic | 各ファイルの `notes` と `provenance` に「fictional」と書いています。 |

## FRED 形式の5系列（`fred/`）

CPIAUCSL・FEDFUNDS・GDPC1・GS10・UNRATE の5系列です。FRED API の応答と同じ形式で、2020年前後の米連邦統計に近い値を持っています。2026-06-07 に #61 で追加しました。

- **FRED から取得した値ではありません。** 2026-11-06 に現行の FRED と照合した結果は下の表のとおりです。title には "fixture values approximating published data, not authoritative observations" と書いています。
- **利用条件**：FRED の系列ページでは、5系列とも "Public Domain: Citation Requested" と表示されています（2026-11-06 に確認）。

| 系列 | 原作成機関（出典） | 現行 FRED との一致 |
|---|---|---|
| CPIAUCSL | U.S. Bureau of Labor Statistics, Consumer Price Index for All Urban Consumers: All Items in U.S. City Average | 0 / 12（季節調整の改訂前に近い値） |
| FEDFUNDS | Board of Governors of the Federal Reserve System (US), Federal Funds Effective Rate | 12 / 12 |
| GDPC1 | U.S. Bureau of Economic Analysis, Real Gross Domestic Product | 0 / 12（`units` の表記は 2017 年連鎖価格だが、値の水準はそれと一致しない） |
| GS10 | Board of Governors of the Federal Reserve System (US), Market Yield on U.S. Treasury Securities at 10-Year Constant Maturity | 5 / 12 |
| UNRATE | U.S. Bureau of Labor Statistics, Unemployment Rate | 7 / 12（改訂前の公表値に近い） |

テストはこれらの値そのものを参照しています（例: `test/test_fred.jl` の CPIAUCSL 2020-01 = 258.678）。そのため、値は変えずに上記の注記を加えました。

## e-Stat 形式の4表（`estat/`）

e-Stat API の応答と同じ形式で、2020年前後の値を持つ4表です。2026-06-07 に #62 で追加しました。

| ファイル | 統計 |
|---|---|
| `0003307059.json` | 労働力調査（完全失業率 全国） |
| `0003343671.json` | 家計調査（消費支出 二人以上の世帯 全国） |
| `0003427113.json` | 消費者物価指数 2020年基準（総合指数 全国） |
| `0003445078.json` | 人口推計（総人口 全国） |

出典：政府統計の総合窓口(e-Stat)（https://www.e-stat.go.jp/）

「労働力調査」「家計調査」「消費者物価指数」「人口推計」（総務省統計局）を基に、DME が fixture として加工して作成しました。

- 公表値との一致は照合していません。
- ファイル名の statsDataId と内容が e-Stat 上の当該表と一致することも確認していません。
- 国や府省が作成したデータとして扱わないでください。
- **利用条件**：e-Stat 利用規約は、数値データを著作権の対象外としています。同規約は出典の記載と、編集・加工した場合はその旨の記載を求めています（2026-11-06 に確認）。

## fixture を追加するとき

1. 区分を1つ決め、上の表に該当するディレクトリがなければ行を追加します。
2. `synthetic` の場合は、ファイル内（`title`・`notes`・`source.description` など）か README で、synthetic・fictional・illustrative のいずれかと明示します。
3. `public-statistics-derived` の場合は、次の3点をこの README に書きます。
   - 原作成機関の出典表記
   - 公表値との一致を保証しないこと
   - 利用条件を確認した結果
4. 次の値は commit しないでください。代わりに、`withheld` として識別用のメタデータだけを commit します。
   - 第三者が著作権を持つ系列の実測値。例えば、FRED の系列ページで "Copyrighted" と表示される系列。
   - FRED から取得した値をそのまま使うもの。
   - 再配布条件を確認していない実データ。
