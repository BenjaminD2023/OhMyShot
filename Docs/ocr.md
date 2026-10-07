# OCR

OhMyShot's OCR is layered (see the roadmap): L1 is Apple Vision with OhMyShot's own post-processing,
and later layers (model packs, a bring-your-own-key cloud model) fill what Vision cannot do. Every change
to OCR is measured with the benchmark first.

## The benchmark

```sh
swift run -c release --package-path Tools/ocr-bench ocr-bench
```

`Tools/ocr-bench` renders a synthetic corpus with Core Text at 2× (like Retina screenshots), so every
image has exact ground truth, then scores each engine on it. Every sentence in the corpus was written for
it; real screenshots stay outside the repository. Categories: Simplified Chinese mixed with English,
Traditional Chinese, Japanese, Korean, one image mixing all of them, English UI text (also with one
Chinese file name), Chinese written without spaces around Latin and digits, highlighted code
on a dark background (with and without a Chinese comment, 2- and 4-space indentation), tables, vertical
Chinese, chat bubbles with emoji, a dark settings list, and the same two lines from 9 to 30 px tall.

Metrics, per case and engine:

- **Content CER**: character error rate with whitespace removed, punctuation width folded, and emoji
  dropped. It counts misread characters only.
- **Raw CER**: the same with only NFC, line endings, and trailing spaces normalized: what a paste would
  contain. The gap to content CER is formatting (spacing, punctuation width, line breaks) that
  post-processing can fix.
- **Line order**: lines found and kept in reading order.
- **Code indentation**, **table shape**, and **table cells**, where they apply.
- **Time** per image, with the first call (model loading) reported apart.

Options: `--engine`, `--case`, `--real DIR` (real screenshots: `NAME.png` with its truth in `NAME.txt`,
kept outside the repository), `--save DIR` (images, outputs, and per-line boxes, directions, and
confidences), `--json PATH`, `--write-baseline`, `--list`. Baselines live in `Tools/ocr-bench/baselines`,
one per engine and major macOS version; a run reports cases that got worse than the baseline.

## What Vision does (macOS 27.2, M3 Max, 2026-10-08)

1. **One request runs one recognition model, chosen by its first language.** Simplified Chinese,
   Traditional Chinese, and Japanese share a model that also reads English; Korean has its own. Languages
   later in the list that need another model are ignored without an error: `[zh-Hans, zh-Hant, en, ja,
   ko]` scores exactly like `[zh-Hans, en]` on every case, `[ko, zh-Hans, en]` reads Korean but loses
   all Chinese and Japanese, and `[ja, zh-Hans, en]` matches `[zh-Hans, en]`.
2. **The Chinese model drops Korean silently.** On the Korean case it returns three characters; in the
   mixed image the Korean line simply disappears.
3. **Automatic language detection picks one language per image.** It reads a Korean-only image, but drops
   the Korean line of a mixed image and loses most of a code listing that has a Chinese comment.
4. **Code with a Chinese comment breaks text detection** under the English model and the document
   request: most long lines are never detected (84–88% content CER). The Chinese-and-English model
   detects them all (3.8%).
5. **Code under the Chinese-and-English model** comes back with full-width punctuation, `l`/`I` and
   `1`/`l` confusions, no indentation, and one-character lines (closing braces) dropped. Without CJK in
   the image the English model reads the same code almost perfectly (1.5%).
6. **`RecognizeDocumentsRequest` is the only source of table structure** (both tables' shapes, 93% of
   cells), but it reads a two-sided chat column by column and drops characters there (50%).
7. **Vertical Chinese is read**, but Vision reports no direction for it; columns come back as tall boxes,
   so the reading order has to be inferred (columns right to left).
8. **Small text holds up**: 2.4% content CER at 9 px, none from 11 px up.
9. **Speed**: about 170 ms per image at p50 and 260 ms at p95. A cold first call took about 10 s; with
   the models already cached by the system it took 0.2–0.3 s.

## L1 (`VisionPipeline` in OMSOCR)

What the pipeline does, in order, and why:

1. **Primary pass** with `[zh-Hans, en-US]`, language correction off, while `DetectTextRectanglesRequest`
   runs alongside it.
2. **Latin model for Latin text**: when the result has at most two CJK characters (and under 5%), the
   image is read again with `[en-US]` and that result kept if it has at least 80% of the characters. A
   single misread glyph (a closing brace read as 子) must not keep code on the CJK model.
3. **Gap filling**: text regions the lines leave empty, or cover with less than half the characters
   their width holds, are merged, padded, and read again, region by region, with each fallback model
   (Korean, then English, in the benchmark). A region's new lines replace the old ones only if they
   hold more characters.
4. **Code with CJK comments**: each run of code lines between CJK lines is read again on its own with
   the Latin model, the region kept clear of the CJK lines so its detector does not fail.
5. **Lone brackets**: neither Vision's recognizer nor its text detector reports a line holding a single
   glyph, so closing braces vanish. Scanning the listing's pixels finds unread rows one or two
   characters wide; each becomes the closer of the bracket left open on the line above that starts in
   the same column. Nothing is guessed when no open bracket lines up.
6. **Spaces from pixels**: where Chinese meets Latin letters or digits, the empty pixel columns at that
   spot decide. macOS layout itself leaves 0.07–0.25 em there when nobody typed a space (0.25–0.29 em in
   Japanese), and a typed space leaves 0.32–0.50 em, so a space is added above 0.3 em and one of
   Vision's is removed below 0.2 em. Japanese lines get no spaces back. (Vision's per-character boxes
   cannot be used for this: they tile the line, with any space folded into a neighbor.)
7. **Text assembly** (`TextAssembler`): reading order with vertical columns right to left; a listing
   where at least 40% of lines look like code keeps ASCII punctuation (except beside CJK, as in Chinese
   comments) and gets its indentation back from x positions, snapped to steps of 4 or 2; elsewhere,
   lines without CJK use half-width punctuation, CJK lines turn half-width marks between CJK into
   full-width and keep their full-width ones, and stray spaces between Han or kana go (Korean keeps its
   word spaces); optionally, wrapped lines are joined.

Results on the corpus (macOS 27.2, release build):

| | best plain Vision setup | L1 |
| --- | --- | --- |
| Content CER, mean | 5.6% (automatic language) | 0.6% |
| Raw CER, mean | 8.9% | 1.1% |
| Line order, mean | 0.94 | 0.99 |
| Code indentation | 0.20 | 0.93 |
| Korean, alone / in a mixed image | 0% / Korean line lost | 0% / 0.9% |
| Code with a Chinese comment (raw) | 20.1% | 0.6% |
| Time per image, p50 / p95 | 170 / 250 ms | 174 / 389 ms |

These numbers are a fit, not yet a measurement: every rule was tuned on the corpus it is scored on, and
every image was drawn by Core Text at 2× in Apple's system fonts. The spacing thresholds in particular
come from macOS's own CJK–Latin spacing; a web page, a terminal, a chat app, or a 1× display may not
match them. Real screenshots with hand-written truth (`--real`) come next.

Still open:

- **Real screenshots**: at least one each from a browser, a terminal, a chat app, and an editor.
- **Line-number gutters**: no case has one, though most editor screenshots do. The gutter digits would
  read as lines of their own and shift every indent by the gutter's width.
- **Speed**: p95 is above the 300 ms target, from the extra passes on images that need them.
- **Tables**: L1 reads table text but not structure; the OCR panel takes structure from the document
  request (93% of cells on the synthetic tables) and fills each cell from the L1 lines inside it, since
  the document request's own reading is weaker (it read "价格" as "fitz" on the panel's demo page).
- **Recognition errors no rule can fix**: `->` read as `>`, a dropped `的`, shortcut glyphs such as
  `⌘⇧4`, emoji. These are for the model packs (L2/L3).
- **Cold start, measured in the app**: the first recognition after a relaunch took 315 ms against
  290 ms warm, so a process pays only about 25 ms. The very first recognition ever made by the app took
  more than 10 s (two attempts timed out at 10 s); the system prepares the model once for a new client.
  Capture Text therefore warms the model while the person is selecting and allows 30 s per request,
  keeping the selection highlighted meanwhile.

## The OCR panel (`VisionPipeline.analyze`, 2026-10-08)

The panel shows everything about one image: the L1 lines, tables, QR codes and barcodes, and the links,
mail addresses, phone numbers, dates, and addresses in the text (`NSDataDetector`). `analyze` runs the
barcode request beside L1 and the document request after it, so no more than two accurate requests
overlap. The document request runs on every image: a table whose columns sit close comes back from L1
as one line per row, so the lines cannot rule a table out, and skipping it on table-free pages saved
only about 80 ms and 15 MB. Each table cell takes the text of the L1 lines that lie at least 75% inside
it; a line that straddles cells is left out, and when both readings have the same characters but only
the document request kept a space ("1 TB" against L1's "1TB"), the space stays (not in Japanese, where
Vision invents spaces).

On the panel's demo page (1520×1120 px, Chinese and English paragraphs, contacts, a 4×3 table, a QR
code) `analyze` takes 620 ms warm; a 800×600 px screen region takes 500 ms.

Found through the panel, still open:

- **Whole English lines on a Chinese page** are read by the Chinese model, which has no language
  correction: "Quick Access keeps every capture one click away" came back as "QuICK Access Keeps every
  capture one Click away", "copied, edited" as "copiea, editea". The `zh-en-lines` benchmark case
  records it (L1 content CER 1.9%, the same as plain Vision). Code runs between Chinese lines are
  already read again with the Latin model; prose runs need the same, within the latency budget.
- **`Label: value` lines read as code**: the YAML rule in `TextAssembler.isCodeLike` scores
  "Docs: https://…" and "Phone: +1 …" as code, so a contact card or release note with four such lines in
  ten is treated as a code listing (monospaced in the panel, lines never joined).
- **Digit–unit spaces in Latin lines**: spacing restoration measures against CJK glyph widths, so a
  Latin-only line gets none, and "1 TB" stays "1TB" when Vision drops the space.
- **Reading order across columns**: lines are ordered top to bottom, so a caption beside a column is
  read in the middle of it.
