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
10. **Two models run side by side.** The Chinese-and-English and the English model on the same image at
    once take p50 189 ms / p95 278 ms, against 172 / 261 ms for the first alone (the `text-zh-en+en`
    probe; the English model alone takes 95 / 138 ms).
11. **In prose, both models find the same lines.** On a Chinese page with English lines the English
    model returns the English lines with the very boxes the Chinese model gave them, and reads them
    correctly where the Chinese model, without language correction, confuses letter case ("QuICK
    Access Keeps … Cick away"). Only code with a Chinese comment trips its detector (point 4).

## L1 (`VisionPipeline` in OMSOCR)

What the pipeline does, in order, and why:

1. **Primary pass** with `[zh-Hans, en-US]`, language correction off, while the Latin model `[en-US]`
   reads the whole page and `DetectTextRectanglesRequest` finds text regions, all three side by side.
   Every accurate request holds one of two process-wide slots (`RecognitionSlots`), since a third
   running at once can stall Vision. Each line Vision returns loses the icons at its ends (`Icons`): an
   app's symbol before a label, a status icon, emoji, or unread dot after it, all of which Vision reads
   as characters. One goes when it is about as wide as the line is tall (a dot: small and read as one),
   sits at an end, and is set apart by a gap at least 0.4 of the line's height and twice any other gap in
   the line, the blank half of full-width punctuation not counted as a gap. Only what Vision put on it
   goes, one character or two or three symbols beyond ASCII, never a word, never before a colon, and
   only with two characters or more left: a dash, "//", "答：", "#tag", and a letter-spaced "确 定" stay.
2. **Latin model for Latin text**: when the primary result has at most two CJK characters (and under
   5%), the Latin page reading replaces it if it has at least 80% of the characters. A single misread
   glyph (a closing brace read as 子) must not keep code on the CJK model.
3. **Gap filling**: text regions the lines leave empty, or cover with less than half the characters
   their width holds, are merged, padded, and read again, region by region, with each fallback model
   (Korean, then English, in the benchmark). A region's new lines replace the old ones only if they
   hold more characters.
4. **Line numbers**: a column of at least three lines of digits alone, aligned, left of every other line
   and counting up (a misread number allowed, and short readings inside the column, which are misread
   numbers too), is an editor's gutter and goes, but only when what remains is code: a numbered list or
   `cat -n` output keeps its numbers.
5. **Code with CJK comments**: each run of code lines between CJK lines is read again on its own with
   the Latin model, the region kept clear of the CJK lines so its detector does not fail.
6. **English lines on a CJK page** (not code): every line in Latin script alone takes the Latin page
   reading of its box, if that reading is between 80% and 125% as long. A line the page reading missed
   is cut out with the others like it and stacked in a strip that holds nothing else (`LineStrip`),
   read in one request; with no CJK in view the Latin detector finds every line.
7. **Lone brackets**: neither Vision's recognizer nor its text detector reports a line holding a single
   glyph, so closing braces vanish. Scanning the listing's pixels finds unread rows one or two
   characters wide; each becomes the closer of the bracket left open on the line above that starts in
   the same column. Nothing is guessed when no open bracket lines up.
8. **Spaces from pixels**: where Chinese meets Latin letters or digits, the empty pixel columns at that
   spot decide. macOS layout itself leaves 0.07–0.25 em there when nobody typed a space (0.25–0.29 em in
   Japanese), and a typed space leaves 0.32–0.50 em, so a space is added above 0.3 em and one of
   Vision's is removed below 0.2 em. Japanese lines get no spaces back. (Vision's per-character boxes
   cannot be used for this: they tile the line, with any space folded into a neighbor.)
9. **Text assembly** (`TextAssembler`): reading order with vertical columns right to left; a listing
   where at least 40% of lines look like code (a `key: value` line counts when the key looks like code,
   lowercase or with `_`, `.`, `-`, or stands alone; a capitalized label such as `Phone: …` counts half,
   so a contact card is prose) keeps ASCII punctuation (except beside CJK, as in Chinese
   comments), joins the pieces Vision returns side by side on one row back into one line, and gets its
   indentation back from x positions, snapped to steps of 4 or 2; elsewhere,
   lines without CJK use half-width punctuation, CJK lines turn half-width marks between CJK into
   full-width and keep their full-width ones, and stray spaces between Han or kana go (Korean keeps its
   word spaces); optionally, wrapped lines are joined.

Results on the corpus (macOS 27.2, release build):

| | best plain Vision setup | L1 |
| --- | --- | --- |
| Content CER, mean (27 cases) | 6.3% | 0.8% |
| Raw CER, mean | 9.3% (automatic language) | 1.3% |
| Line order, mean | 0.93 (automatic language) | 0.98 |
| Code indentation | 0.20 | 0.93 |
| Korean, alone / in a mixed image | 0% / Korean line lost | 0% / 0.9% |
| Code with a Chinese comment (raw) | 20.1% | 0.6% |
| English lines on a Chinese page (`zh-en-lines`) | 1.9% | 0% |
| Code beside a line-number gutter (`code-gutter`) | 9.9% | 1.5% |
| A sidebar of icons and labels (`ui-icons`) | 25.9% | 5.6% |
| Time per image, p50 / p95 | 164 / 218 ms | 183–189 / 379–399 ms |

These numbers are a fit: every rule was tuned on the corpus it is scored on, and every image was drawn
by Core Text at 2× in Apple's system fonts. Real screenshots tell more (below).

## Real screenshots (2026-10-08)

Five captures made with OhMyShot at 2× (a chat app, a social site, a forum, a code editor, a terminal),
cut into twelve regions someone would select with Capture Text, each with its text written out by hand
and checked against the image: chat list, article cards, post text, sidebars, forum thread, a category
list, the code with and without its line numbers, `ls` and `ll` output, a system summary. They are
personal and stay out of the repository (`Tools/ocr-bench/real/`, git-ignored; its README says how the
truth is written: icons, avatars, and emoji are not text). Content CER, L1:

| Region kind | Before | After icons and gutters |
| --- | --- | --- |
| Category list with an icon before each item and unread dots | 35.1% | 13.2% |
| Forum thread (avatars, action icons, an emoji) | 7.7% | 6.1% |
| Terminal `ls` (file-type icons in a grid) | 17.3% | 13.2% |
| Code beside its line numbers | 10.7% | 4.3% |
| The same code without them | 4.1% | 4.1% |
| Chat list (a muted bell on most rows) | 4.6% | 3.8% |
| Terminal `ll`, a system summary, posts, cards, sidebars without icons | 1.1–7.4% | unchanged |
| **Mean of the twelve** | **8.1%** | **5.2%** |

The same regions cut from copies a chat app shrank to 2000 px and recompressed: 8.9% before, 6.4% after.
Plain Vision on the originals: 8.5% (`[zh-Hans, en]`), 14.9% (automatic language), 26.0% (documents).

What the real captures showed that the synthetic corpus did not:

- **Icons read as characters** were most of the error in app interfaces: a calendar as 首, a link as @,
  a muted bell as 4 or D, an unread dot as ● or 。, file-type icons in a terminal as "us" or "Ts". Icons
  at the ends of a line now go (L1 step 1); icons in the middle of a line, avatars, and emoji right
  after text still come through.
- **Line numbers** came back as lines of their own, and with them a listing no longer read as code, so
  it lost its indentation; Vision also read some numbers together ("757677") or misread them ("S5").
- **Fonts decide a lot in code**: in this editor's font the Latin model reads `l` as `L` and `||` as `I1`
  (the Chinese model reads the same `l` correctly), and cursive italics in comments trip both.
- **Resolution matters for small monospaced text**: the `ll` listing is 7.4% from the 2× capture and
  17.1% from the shrunk copy; prose barely changes.

Still open:

- **Icons inside a line, avatars, emoji after text**; recognition errors no rule can fix (鼠 read as 蟲,
  `ω` as `w`, an underscore lost).
- **Speed**: p95 is above the 300 ms target, from the extra passes on images that need them (Korean
  fallback, code with Chinese comments). Reading the Latin page alongside the first pass made English
  pages 85–126 ms faster (no second pass after the first) and costs Chinese and mixed pages 0–32 ms.
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

Found through the panel. Fixed since: whole English lines on a Chinese page misread by the Chinese
model (L1 step 5; the panel's demo page now reads without an error, "1 TB" included), and `Label: value`
lines taken for code (step 8). Still open:

- **English words inside a Chinese line** are still read by the Chinese model ("macOS" as "macos" in
  `zh-en-chat`): step 5 replaces whole lines only.
- **Reading order across columns**: lines are ordered top to bottom, so a caption beside a column is
  read in the middle of it.

## Translation (`Translator`, `TranslationUnits`, `TranslationOverlay`, 2026-10-08)

Translation runs on the system's on-device models (the Translation framework): `TranslationSession(installedSource:target:)` needs no interface for a pair already downloaded; a pair the system can download is offered through SwiftUI's `.translationTask` and `prepareTranslation()`, which shows the system's own sheet. Simplified and Traditional Chinese, which the framework does not translate between, are converted character by character (ICU's `Hans-Hant`). On this Mac, English↔Chinese, French, German, Dutch, and Arabic are downloaded; 21 languages in all can be.

**Units.** Lines that wrap into each other (as when assembling with joined lines) are translated as one, so a paragraph reads as a paragraph; every other line stands alone. Left as they are: code (a listing, or a code-like line), vertical text, figures and figures with an abbreviation ("5 GB", "iOS 26", which a model spells out: "5千兆字节"), a link or address alone, names of files, commands, and handles ("package.json", "--force", "@name", "camelCase", or more of those than words in a line), and, on a technical page (a third of its words or more identifiers and figures: the command line, a code editor), any word on its own and any line that is not mostly words. A sentence there, such as an error message, is still translated.

**Languages.** A short text says little about its language ("dfanxu" reads as Polish, "Codex" as Spanish, an icon misread as kana as Japanese), so only a confident reading (probability 0.75 or more, eight letters or more counting a Han or kana character as two, 70% of its characters in the language's own script) counts on its own; the page's languages are those of the confident readings with 15% of their text or more, and every other unit takes the page's language that writes most of its letters. Only confident readings of a line's worth of text in a language not downloaded ask for a download. With no target chosen, the target is the first preferred language that half the text or more is not already in: with English and Chinese preferred, an English page is translated into Chinese and a Chinese one into English. A bilingual label, one part Latin and one part another script side by side with one part plausibly in the target ("发布说明 Release Notes", "价格 Price"), counts as already in the target; a word of one script inside a sentence of the other ("按住 Option 再松开鼠标") makes three parts and is translated.

**Batches.** Alone, short labels come back with the wrong sense: "Open" as 户外 (outdoors), "Free" as 未受困的 (not trapped), "Pro" as 职业选手, "Save" as 挽救. Joined with newlines they are still translated one by one, but joined with " | " in one request they come back right ("Open | Share | Done" → 打开 | 共享 | 完成; "Free | Pro | Team" → 免费 | 专业 | 团队), with every separator kept in all twelve lists tried. So units of five words or fewer go together, twenty to a request, and a batch whose pieces do not come back one for one is translated unit by unit. Translations into Chinese and Japanese lose the space the model leaves between sentences ("即可。 捕获").

**Drawing.** Every translated line is painted over with its background (the median of the pixels just outside its box) and the translation is set in its ink (the median of the inkiest half of the pixels that stand out), in the target language's system font. The size comes from the line's width: Vision's box is as wide as the text set in the system font to within 2% (measured on eight lines, Latin, Chinese, capitals, bold), while its height runs from 0.87 to 1.24 times the size and is sometimes half again as tall as the text; the width is measured again at the size the text had on screen, since the system font is about a tenth wider at text sizes than at display sizes. Sizes of neighbors in a column or row within 15% are made one, a unit a third larger than the body is set semibold (weight cannot be read from the pixels: bold Latin is wider, so it reads as larger instead; ink coverage told bold from regular by 1.04–1.26 against 0.92–0.99, too close), and lines are placed with their ink on their column's (the median of where the ink of its lines starts, translated or not, measured in the pixels: Vision's boxes start a little before the ink) and centered where their ink was. A translation that does not fit shrinks to 70% (a line on its own may first run on to the right, up to the first pixel that is not its background), then ends in an ellipsis; units cut short are counted.

On the ten real screenshots (2000–4112 px wide; Chinese pages translated into English, English pages into Chinese, as Automatic chose): 3–53 units translated per page, no spurious download prompt, a terminal and a code editor left alone apart from their prose (3–6 units), 0–15 units shortened per page; translating took 0.1–0.7 s and drawing 0.02–0.6 s. Still open: short labels translated alone keep the wrong sense when a page has no other short text to batch them with; Chinese into English roughly doubles the length, so dense interfaces shrink and shorten; a flat background patch shows on photos and gradients; vertical text is left as it is.
