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
Chinese, chat bubbles with emoji, a dark settings list, the same two lines from 9 to 30 px tall, and a tall page of 150 lines (read in bands).

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

What the pipeline does, in order, and why (an image more than 2560 pixels tall, or very wide, is cut into
overlapping pieces first and each piece goes through all of this: see Large selections in bands):

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
   their width holds, are merged, padded, and read again with each fallback model (Korean, then
   English, in the benchmark), the regions of one model side by side. The English fallback takes the
   Latin page reading of each region instead of a new request: that model has read the whole page
   already, and of the three regions it read again across the benchmark and the real screenshots (all
   three icons on the forum thread), none was kept. What this gives up: text that neither model read on
   the whole page but the English model would read cropped, and any English gap fill at all when the
   Latin page pass itself fails. A region's new lines replace the old ones only if they hold more
   characters.
4. **Line numbers**: a column of at least three lines of digits alone, aligned, left of every other line
   and counting up (a misread number allowed, and short readings inside the column, which are misread
   numbers too), is an editor's gutter and goes, but only when what remains is code: a numbered list or
   `cat -n` output keeps its numbers.
5. **Code with CJK comments**: each run of code lines between CJK lines is read again on its own with
   the Latin model, the runs side by side, the region kept clear of the CJK lines so its detector does
   not fail. (Taking a run from the page reading when it read every line was tried: it never applied on
   the benchmark or the real screenshots, so it was not kept.)
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
| Content CER, mean (28 cases) | 6.3% | 0.8% |
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

## Speed (2026-10-08)

`--trace` prints how long each step and each Vision request took. Where the time goes:

- **The primary pass is about three quarters of every recognition**: 170–280 ms on the synthetic cases,
  400–700 ms on the real regions. The Latin page pass beside it finishes first and costs the primary
  about 17 ms. The primary's time grows with the amount of text, not the pixels: a 1066×1024 terminal
  region with 35 dense lines takes 690 ms, against 300 ms for the Latin model.
- **Every further request costs 60–170 ms whatever its size** (a 67×45 region took 118 ms). The p95
  came from those run one after another: two Korean gaps (+238 ms), two runs of code (+343 ms on a real
  editor region, where one misread glyph splits the code in two), three icons taken for gaps (+402 ms).

Now the regions of one step are read side by side and the English gap fallback reuses the page
reading. Two runs each, before and after, back to back; accuracy unchanged on every case:

| | p50 | p95 |
| --- | --- | --- |
| Synthetic (27 cases) | 198–203 → 187–188 ms | 415–428 → 366–373 ms |
| Real regions (12) | 269–289 → 268–281 ms | 854–865 → 697–716 ms |

The cases that changed: the forum thread 765–815 → 530–555 ms, the two editor regions 854–957 →
663–846 ms, `multilingual` 437–448 → 334–342 ms. The dense terminal (about 700 ms, all primary pass),
`code-swift` (one run of code, read after the primary pass) and `ko` (one Korean region) are as before.

**Ruled out: deciding early that a page has no CJK.** A request stops within 2 ms of being cancelled
and text rectangles with character boxes take 12 ms, so the primary pass could be dropped on English
and code pages if their Latin reading showed they hold no CJK, which would take a dense terminal from
690 to about 300 ms. But nothing in that reading shows it. Of 281 lines with CJK across the benchmark
and the real screenshots, the Latin model dropped 143, read 75 with non-ASCII junk ("¼‡ Option ¾Лñ"),
and read 63 (22%) as plain ASCII ("显示更多" as "RTES"), 20 of those with confidence 1.0. Square
character boxes miss a short CJK word on an English page (`en-zh-word`) and find squares in a
terminal's monospaced text. A Chinese comment in code or one Chinese label on an English page would
be lost, so the primary pass always runs.

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

**Languages.** Text mostly in Chinese, Japanese, or Korean characters is told by them: kana is Japanese, Hangul Korean, Han alone Chinese (Traditional when it has characters only Traditional writes, Simplified when only Simplified does, else the preferred Chinese). Other text goes to Natural Language with the preferred languages likelier from the start, and only its words are read: file names and handles say nothing about a language ("tsconfig.json" reads as Indonesian). A short text still says little: in a small selection "moraxcheng" and "Oct" read as Polish and "Grok" as Vietnamese, and a language not downloaded then left the whole selection untranslated (45 of 93 selections of a few lines cut from the real screenshots; 20 after, every one of them code, which is left alone on purpose). So only a confident reading (probability 0.75 or more, eight letters of words or more counting a Han or kana character as two, 70% of its characters in the language's own script) counts on its own; the page's languages are those of the confident readings with 15% of their text or more, and every other unit takes the page's language that writes its letters, or else the first preferred language that does. Only confident readings of a line's worth of text in a language not downloaded ask for a download, unless nothing else could be translated. With no target chosen, the target is the first preferred language that half the text or more is not already in: with English and Chinese preferred, an English page is translated into Chinese and a Chinese one into English. A bilingual label, one part Latin and one part another script side by side with one part plausibly in the target ("发布说明 Release Notes", "价格 Price"), counts as already in the target; a word of one script inside a sentence of the other ("按住 Option 再松开鼠标") makes three parts and is translated. When Translate Area can translate nothing, the area opens in the OCR panel, which says why.

**Batches.** Alone, short labels come back with the wrong sense: "Open" as 户外 (outdoors), "Free" as 未受困的 (not trapped), "Pro" as 职业选手, "Save" as 挽救. Joined with newlines they are still translated one by one, but joined with " | " in one request they come back right ("Open | Share | Done" → 打开 | 共享 | 完成; "Free | Pro | Team" → 免费 | 专业 | 团队), with every separator kept in all twelve lists tried. So units of five words or fewer go together, twenty to a request, and a batch whose pieces do not come back one for one is translated unit by unit. Translations into Chinese and Japanese lose the space the model leaves between sentences ("即可。 捕获").

**Drawing.** Every translated line is painted over with its background (the median of the pixels just outside its box) and the translation is set in its ink (the median of the inkiest half of the pixels that stand out), in the target language's system font. The size comes from the line's width: Vision's box is as wide as the text set in the system font to within 2% (measured on eight lines, Latin, Chinese, capitals, bold), while its height runs from 0.87 to 1.24 times the size and is sometimes half again as tall as the text; the width is measured again at the size the text had on screen, since the system font is about a tenth wider at text sizes than at display sizes. Sizes of neighbors in a column or row within 15% are made one, a unit a third larger than the body is set semibold (weight cannot be read from the pixels: bold Latin is wider, so it reads as larger instead; ink coverage told bold from regular by 1.04–1.26 against 0.92–0.99, too close), and lines are placed with their ink on their column's (the median of where the ink of its lines starts, translated or not, measured in the pixels: Vision's boxes start a little before the ink) and centered where their ink was. A translation that does not fit shrinks to 70% (a line on its own may first run on to the right, up to the first pixel that is not its background), then ends in an ellipsis; units cut short are counted.

On the ten real screenshots (2000–4112 px wide; Chinese pages translated into English, English pages into Chinese, as Automatic chose): 3–53 units translated per page, no spurious download prompt, a terminal and a code editor left alone apart from their prose (3–6 units), 0–15 units shortened per page; translating took 0.1–0.7 s and drawing 0.02–0.6 s. Still open: short labels translated alone keep the wrong sense when a page has no other short text to batch them with; Chinese into English roughly doubles the length, so dense interfaces shrink and shorten; a flat background patch shows on photos and gradients; vertical text is left as it is.

## Annotation readings (`TextRecognition`, 2026-10-10)

The redaction suggestions (`SensitiveTextScanner`) and the lines the highlighter snaps to
(`TextLineReader`) read the capture with the same accurate request: `[zh-Hans, en-US]`, language
correction off. The suggestions also read it with `[en-US]` alone. One `TextRecognition` per capture
serves both, so the Chinese reading is made once (`SharedWork`): whoever asks first starts it, later
askers wait for the same run or take what it kept, a failed run is forgotten so the next ask makes it
again, and a run nobody waits for any more is cancelled (one still waiting for a `RecognitionSlots`
slot never starts; one already inside Vision runs to its end or the timeout, as before). The editor's
session keeps one reading for both tools while the combined images and the canvas allow
(`AnnotationSession.sharedReading`).

On the drawn demo page (Debug build, `debug/reading-scan`): suggestions 320–360 ms, then the lines
61 ms (the ink fitting alone) instead of 400 ms read on their own; lines first, then the suggestions
in 144 ms (the Latin reading alone). Both entry points are `@concurrent`: called from the session's
main-actor task through the app's closures, the ink fitting (50–300 ms on the real screenshots) used to
run on the main thread.

## Large pictures, in bands (`PictureText`, 2026-10-15)

Capture History's search reads every screenshot with L1, so it met pictures the benchmark never had: whole 4K and
6K screens, and scrolling captures up to 50,000 pixels long. One request over a large picture loses text, and on
a tall one most of it: Vision shrinks what it is given, and small text goes. Read again in bands 2048 pixels tall
across the full width, 256 pixels into each other, the history's own captures gave (characters in distinct lines,
so a line read twice in an overlap counts once; Release reader, M3 Max):

| Picture | Whole | Bands of 2048 | Bands of 1400 |
| --- | --- | --- | --- |
| 3346 × 16811 (scrolling) | 0, 0.6 s | 1222, 2.4 s | 1256, 3.4 s |
| 3667 × 8418 | 20, 0.4 s | 1232, 1.6 s | 1289, 2.2 s |
| 3687 × 8237 | 2100, 11.0 s | 2478, 2.2 s | 2650, 2.7 s |
| 3700 × 8000 | 2126, 14.4 s | 2332, 2.0 s | 2600, 2.5 s |
| 3527 × 6020 | 309, 0.6 s | 1669, 1.5 s | 1690, 1.8 s |
| 4112 × 2658 (a 4K screen) | 1095, 0.6 s | 1182, 0.9 s | 1184, 1.0 s |
| 4112 × 2579 | 653, 0.7 s | 744, 0.8 s | 932, 1.1 s |
| 2336 × 2287 | 807, 0.4 s | (one band) | 807, 0.6 s |
| 10989 × 2880 (sideways scrolling) | 567, 0.6 s | 1100, 1.6 s | 396, 0.7 s |

On a drawn page 3700 × 8000 of 154 dense lines, the whole picture read nothing in 34 s; its bands read every line
in 3 s. Bands of 1400 read a little more again on some pictures, but a band seven times wider than tall reads
less, and they cost more time; `PictureText` uses 2048, and only for pictures more than a quarter taller than a
band. The one very wide picture read best cut across too, into squares as wide as it is tall (1451 characters,
against 1100 in bands across its width), though that cuts its lines: `PictureText` does it only for pictures over
4096 pixels wide and 2.5 times wider than tall.

Counting caveat: those characters are in *distinct lines of text*, so a line both bands read, a little differently
each time, counts twice, and a line cut by a band's edge counts once more as a fragment. Placed in the whole
picture and put together once (below), the same bands give 1180 characters for the 3346 × 16811 capture (1222
above), 2438 for 3687 × 8237 (2478), and for the four 4K-screen captures 0.1–0.6% more than the whole picture read,
not 8–14%: what bands gain is on tall pictures, and on dense small text.

Capture Text, the OCR panel, and Translate Area read in bands too, from `VisionPipeline.recognize`: see below.

## Large selections in bands (`VisionPipeline.recognize`, 2026-10-15)

`recognize` cuts an image the way `PictureText.pieces` does (bands 2048 tall with 256 pixels of overlap when the
image is more than 2560 tall; also columns as wide as the image is tall when it is over 4096 wide and 2.5 times
wider than tall) and reads the pieces one after another, each through the whole pipeline above (both models, gaps,
code, Latin lines, lone brackets), so every piece's Vision requests still hold two slots at most. Then:

1. **Each line is placed in the whole image** (its box moved by the piece's origin) and kept from the piece that
   owns its spot: a piece owns its *core*, itself less half the overlap (128 pixels) on every side it shares with
   another piece. The cores tile the image, and a line no taller than the overlap that an edge cuts lies, whole, in
   the core of the piece beside it, so the cut reading of it is dropped without comparing text. A reading from a
   piece that does not own its spot is kept only when the owner found nothing there (it can miss a line its
   neighbour reads), and a line that two pieces each own by a pixel is kept once when the text repeats.
2. **A line that runs across a whole column overlap** is cut in both columns: the left reading ends at the
   column's edge, the right one begins at its own, and they overlap. Such pairs are found (same row, one touching the
   left column's right edge, the other the right column's left edge) and each is cut out of the image whole, all of
   them stacked in one strip as for Latin lines (`LineStrip`), read in one request, and put in the pieces' place if
   the reading is about as long as the pieces together less their overlap.
3. **Line numbers** are removed once more from the merged lines (a piece with fewer than three numbers in view
   leaves its own), and `ReadingOrder` and `TextAssembler` then run once, over the whole image's lines.

`analyze` (the panel) reads its lines this way. Its document request and barcode request stay on the whole image: a
table or a code taller than the overlap would be cut in two. Measured over the 18 captures below (counts only),
the document request over the whole image found one table 7182 pixels tall with 281 cells in 3687 × 7335, where its
bands found two with 93 and 70, and its pieces found tables the whole image missed (three tables of 10, 82, and 25
cells in 3687 × 8237; one of 18 cells in 3700 × 8000; two with 38 cells in all in 3534 × 2619, where the whole image
gave one with 22). Keeping the whole-image result keeps what the panel showed before; a union of the two, with the
bands' small tables added where the whole image found none over them, is open. The cells' text comes from the
bands' lines either way (`filled(from:)`).

**Measured** on the 18 captures in this Mac's Capture History that are over 2560 pixels tall or 4096 wide
(Release, M3 Max, warm; a throwaway harness outside the repository, counts and times only: characters are those of
`OCRResult.text` without whitespace; two runs agree to the character, timings to within 5%):

| Capture | Whole: characters, ms | Bands: characters, ms | Lines whole → bands |
| --- | --- | --- | --- |
| 3346 × 16811 | 0, 590 | 1180, 2830 | 0 → 105 |
| 3710 × 9875 | 1685, 10050 | 1943, 2240 | 193 → 223 |
| 3499 × 8440 | 135, 450 | 2167, 2120 | 6 → 232 |
| 3667 × 8418 | 20, 320 | 1226, 1740 | 1 → 142 |
| 3687 × 8237 | 2126, 10570 | 2438, 2300 | 192 → 264 |
| 3700 × 8000 | 2198, 14640 | 2328, 2080 | 233 → 241 |
| 3687 × 7335 | 430, 630 | 2521, 2110 | 36 → 336 |
| 3527 × 6020 | 309, 560 | 1602, 1570 | 27 → 181 |
| 2173 × 4242 | 322, 600 | 1313, 1130 | 32 → 180 |
| 3658 × 4167 | 778, 670 | 1632, 1380 | 75 → 153 |
| 10989 × 2880 (sideways) | 567, 530 | 1372, 3210 | 18 → 92 |
| 4336 × 2672 (a 4K screen) | 1550, 740 | 1551, 930 | 81 → 86 |
| 4112 × 2658 | 1095, 540 | 1102, 870 | 52 → 57 |
| 3534 × 2619 | 553, 540 | 556, 720 | 81 → 88 |
| 4110 × 2573 | 1397, 580 | 1402, 810 | 52 → 50 |
| 4105 × 2327, 4699 × 2299, 4301 × 1723 | unchanged | unchanged (one piece) | — |

Over all 18: 15,563 characters whole, 26,731 in bands. Reading time summed over the 18: 43.3 s whole, 27.3 s in bands; the
panel's `analyze` 49.7 s against 33.4 s. A capture in bands costs 0.25–0.45 s per band; the three captures that took
10–15 s whole now take 2.1–2.3 s. The sideways capture is the slowest in bands (3.2 s; 10 pieces and one request to
read its cut lines whole), and the screens a little over 2560 pixels tall pay 170–330 ms for almost no more text.

**Does banding start too early?** The captures just over the threshold gained almost nothing, but the same
captures cut to 2600–3600 pixels (20 crops of five tall captures, top-aligned)
show that whole-picture loss is erratic with height, and banding is never meaningfully worse: +19% to +66% on 11 of the
20, +2% to +10% on 3, and −2% to +2% on 6 (two captures whose text the whole picture read as well, 530–1300 characters).
The threshold stays at 2560.

**What ownership drops.** Over the 15 captures that were cut, no line a piece read lies where the merged reading has
nothing. In characters: for 2 of the 15 a dropped line held 3 and 4 characters more than what replaced it, and that is
all; the rest dropped was repeats and cut fragments.

**Column cuts.** The sideways capture's 10 pieces gave 99 lines, 16 of them the two halves of 8 cut lines
(six at one cut, two at another); the stitching read seven of the eight whole (1445 → 1372 characters, 99 → 92 lines) for one extra request
(about 0.4 s). Without it a full-screen Capture Text on an ultrawide screen would split every long line that crosses
a cut, so the same was tried on drawn pages of 55 long lines (8487 characters, most of them across a cut):

| Page | Whole | In columns |
| --- | --- | --- |
| 5120 × 1440 (an ultrawide screen at 1×) | 65 lines, 5241 characters (62%), 1.9 s | 55 lines, 8480 characters, 3.5 s |
| 10240 × 2880 (the same at 2×) | 68 lines, 7230 characters (85%), 2.9 s | 55 lines, 8484 characters, 7.3 s |

The first version stacked every cut line in one strip, and at 2× that strip (55 rows) was far taller than 2048 pixels, so
Vision shrank it: nothing was read whole (109 lines, 9243 characters, every line split and its overlap read
twice). The strips are now at most 2048 pixels tall (`LineStrip.batches`), a request each, which gave the second
row. So the column rule makes a dense ultrawide screen read nearly everything, once, and costs 1.6 s (1×) to 4.4 s
(2×) on these pages: the latency to weigh if the rule (over 4096 wide, 2.5 times wider than tall) is ever tuned for
Capture Text. The tests `BandedReadingTests` draw one line across a cut and a 5120 × 1440 page of 30 long lines, and
fail without the stitching.

**The benchmark** gained a case, `tall-page` (1128 × 5950, 150 lines of English and Chinese at 11 pt, 2×): read
whole, content CER 23.1% and line order 0.31; in bands, 1.2% and 0.90 (what remains is Vision misreading Chinese at
22 pixels, not the bands). The other 27 cases and the 12 real crops in `Tools/ocr-bench/real` (all under 2100 pixels
tall, so one piece) give byte-identical text and scores to the code before, and the time per image is the same
(p50 184–205 against 184–190 ms, p95 348–406 against 365–373; four runs against three). The L1 baseline gained the one case. Peak resident size of the
harness, image decoding included: 3346 × 16811, 2561 → 1286 MB; 3700 × 8000, 984 → 604 MB; the sideways capture,
1417 → 1607 MB.

**Known limits.** A line taller than 256 pixels that a band's edge cuts (a heading at 3× or more) is cut in the owner
too, and a vertical line longer than that that crosses an edge likewise. Vision also reads a line a little differently
in two pieces now and then; the ownership rule takes the owner's reading, not the better one.

## L2 runtime (spike, 2026-10-09)

The plan's L2 is a model pack for what Vision reads poorly: Chinese-heavy interfaces, vertical text, low
confidence. The candidate is PP-OCRv6 (PaddleOCR, June 2026, Apache-2.0): tiny (1.5M parameters), small
(7.7M), and medium (34.5M, server-class, not considered), published on Hugging Face as ONNX and as
safetensors for the PyTorch implementation in transformers (5.12 and later). Small reads 18,708
characters (Simplified and Traditional Chinese, Japanese, Latin scripts) but not Korean; tiny reads
6,904 and no Japanese. The question was the runtime: ONNX Runtime, or Core ML. Harness and setup:
`Tools/l2-spike/`.

**Size.** ONNX Runtime's library is 33.2 MB (`libonnxruntime.1.30.0.dylib`), more than the app's whole
30 MB budget; Core ML ships with the system. The models: 9.9 + 21.2 MB as fp32 ONNX, 5.1 + 10.7 MB as fp16
Core ML ML programs (converted from the PyTorch implementation, which matches the ONNX exports to
1e-5).

**Speed and CPU time**, the same 34 cases (5 of the 39 did not fit the enumerated sizes tried), through
the Python harness (its pre- and post-processing included):

| Runtime | p50 | p95 | CPU time | Content CER |
| --- | --- | --- | --- | --- |
| ONNX Runtime, CPU | 129 ms | 346 ms | 47.6 s | 8.03% |
| ONNX Runtime, Core ML provider | 923 ms | 2056 ms | 39.6 s | 8.03% |
| Core ML, any size (times as on the CPU) | 71 ms | 209 ms | 5.1 s | 8.08% |
| Core ML, enumerated sizes, CPU and Neural Engine | 91 ms | 238 ms | 3.3 s | 8.25% |

The five left out are the largest real regions (both editor crops, the chat list, the forum category
list, `ls` output): on all 39, ONNX Runtime's p95 is 727 ms with 66.4 s of CPU time, and Core ML with
any size 499 ms with 7.6 s; on those five, Core ML took 127–635 ms against 183–975 ms. The enumerated
run recognized one line per call, each padded to the next enumerated width, where ONNX Runtime ran six
at once, so batching on the Neural Engine is untried headroom.

ONNX Runtime keeps every core busy (a dense terminal: 1 s of wall time, 7.6 s of CPU time). Its Core ML
provider splits the graphs (detection into 4 partitions, recognition into 11) and compiles again for
every new input size, 0.4–0.6 s each. With any size, Core ML's compute plan prefers the Neural Engine
but the timing matches CPU-only (detection at 736×1280 takes 39 ms natively, against 10 ms with
enumerated sizes), and with `.all` its GPU path asserts on macOS 27.2 beta; with enumerated sizes and
`.cpuAndNeuralEngine` every operation of the detector and all but one of the recognizer's (6% of its
cost) run on the Neural Engine. Natively
(`probe.swift`): detection of a 736×1280 image 10 ms, recognition of a line 2 ms at 320 px wide and 8
ms at 1280. The Neural Engine compiles every enumerated size the first time a compiled model is loaded
(15 s for the detector's 24 sizes, 6 s for the recognizer's 11); the system keeps the result, and a
second process loads in 40 ms.

**Accuracy against L1** (content CER; L2 raw, with none of L1's post-processing):

| Case | L1 | PP-OCRv6 small | tiny |
| --- | --- | --- | --- |
| Forum category list (real) | 13.2% | 6.1% | 25.4% |
| Forum thread (real) | 6.1% | 2.6% | 10.2% |
| Forum title (real) | 3.6% | 1.8% | 5.4% |
| Chat list (real) | 3.8% | 3.1% | 4.6% |
| Tweet (real) | 1.8% | 1.2% | 1.2% |
| Editor code (real) | 4.1% | 1.0% | 1.0% |
| Traditional Chinese | 1.3% | 0.0% | 13.2% |
| 9 px text | 2.4% | 0.0% | 9.5% |
| Chat bubbles | 2.9% | 0.0% | 8.8% |
| Social sidebar (real) | 2.0% | 16.7% | 11.3% |
| Article cards (real) | 1.1% | 4.5% | 3.4% |
| Korean | 0.0% | 97.4% | 96.2% |
| Mean, all 39 | 2.14% | 7.76% | 11.62% |

Vertical Chinese is read right (its columns come out left to right; the harness has no vertical
reading order). L2 also lacks what L1 learned on real screenshots: editor gutters and icons at line ends
stay in its text. Detecting at transformers' preprocessing (the shorter side upscaled to 736, where
PaddleX uses 64) read the weak cases a little better (mean 10.45% → 9.95%; the social sidebar 16.7% →
8.7%, the forum title 1.8% → 3.6%) at twice the time (p50 140 → 275 ms).

**Decision: Core ML**, PP-OCRv6 small as fp16 ML programs with enumerated sizes on
`.cpuAndNeuralEngine`, as a second reader of the regions L1 reads poorly rather than a replacement. ONNX
Runtime is out: its library alone exceeds the app's size budget, it spends ten times the CPU time, and
its Core ML provider recompiles for every size. For M6: a model pack of about 16 MB; compiled and warmed
in the background once downloaded, so nobody waits the 21 s; a size grid (or tiles) that holds tall and
wide regions without compiling too many sizes; never `.all` while the GPU path asserts.

## Model packs (M6 step 1, 2026-10-17)

A model pack is a set of files the app downloads to read what Vision reads poorly: a Core ML model and what
goes with it, its license among them (`OMSCore/ModelPacks`). This step built the pack manager. No pack is
published yet, so `ModelPackCatalog.packs` is empty and nothing in the app mentions packs (Settings shows the
row only when the build offers one). The first pack is L2's PP-OCRv6 small (step 2). The process that will
read with a pack is not built either. Step 2 decides it with L2, its first reader: the text reader extended
into one reader beside the app, or an XPC service.

**Listing.** Packs are listed in the app, never fetched from a server. Each lists its id and version, a name
and summary for Settings, its license (a name, a link, and one of its own files holding the text, any NOTICE,
and what was changed), the original model's page, the host's name, and its files (path, size, SHA-256). It
also lists mirrors: base addresses tried in order, each naming a fixed revision. The host is Hugging Face, on
the user's account (decided 2026-10-17); mirrors (hf-mirror.com, ModelScope) can be added to a listing later
with no change to the code, since a file is its path under any of them and is kept only if it hashes right.
`ModelPack.problem` refuses a listing with a path that is absolute, empty, `.`, or `..` in any part, a file
listed twice, a size of 0, a SHA-256 that isn't 64 lowercase hex digits, a license file that isn't one of
the files, or a mirror that isn't https ending in "/" (http on 127.0.0.1 too, in Debug builds).

**Storage.** `Application Support/<bundle id>/Model Packs/<id>/<version>/` holds an installed version, its
receipt (`Receipt.json`) written last. A download fills `<version>.download/`, each file arriving as
`<path>.partial`, renamed once it checks out. The receipt is written into the download's folder and the folder
is then renamed into place, so a version appears whole or not at all. An installed folder never moves. The
Neural Engine keeps a compiled model's compilation by its path (L2 runtime), so what step 2 compiles from a
pack's files stays valid there. Old versions and packs no longer listed are removed when Settings next looks.
A paused download stays, across relaunches.

**Downloading.** One `URLSession` per download, invalidated when it ends, and an `ActiveResources` lease
(`.download`) while it runs. Progress is reported about a hundred times over a pack. Before it starts, the
download checks for room: what is left to fetch plus 200 MB, on the volume. Each file is resumed with a
`Range` request from the end of its partial file. The partial bytes are hashed first, then each chunk as it
arrives. Answers are handled as follows:

- **206 starting elsewhere than asked:** fails that mirror.
- **200 to a range:** the file is started over.
- **416:** what is there gets checked.
- **A wrong size or SHA-256:** the file is thrown away and fetched once more from the start, from the next
  mirror; a second failure fails the download.
- **A mirror that fails (HTTP status, lost connection):** the next mirror is tried, and the partial file is
  kept.

Pausing or cancelling ends the task. Cancelling also removes what came.

**Hugging Face answers this.** Probed 2026-10-17 on `PaddlePaddle/PP-OCRv6_small_rec_onnx/resolve/main/inference.onnx`
(21,159,378 bytes):

- The `resolve` address answers 302 to `us.aws.cdn.hf.co` (Xet).
- The CDN answers `Range: bytes=1000-1999` with 206, 1000 bytes, and `Content-Range: bytes 1000-1999/21159378`.
- URLSession keeps the `Range` header across the redirect.
- The CDN's ETag is the file's SHA-256.

**Asking first.** The first download of a pack opens a sheet with what it is, its size, where it comes from,
links to its license and the original model, and the license's full text. The license file is fetched alone
for that (`ModelPackDownloader.license(of:)`) and kept, so the download doesn't fetch it again. A pack whose
download folder holds only its license counts as not started, so closing the sheet without agreeing never
turns into a paused download that resumes without asking.

**Checked.**

- **`ModelPackTests` (17 tests, through a `URLProtocol` stub):**
  - a pack downloads whole and installs
  - a cut-off download resumes with `Range`
  - a server ignoring `Range`
  - a wrong partial file caught and fetched again
  - a file damaged twice fails
  - the next mirror after a 503
  - every mirror down
  - a full disk stops before any request
  - cancelling keeps what came and the download goes on later
  - unused versions and packs removed while a paused download stays
  - the center's download, pause, resume, and remove
  - a license read but not agreed to
  - a failure's reason kept across refreshes
  - path and listing checks
- **In the Debug app, against `Tools/model-packs/lab-server.py`** (a made-up 25 MB pack served on 127.0.0.1 with
  `Range`, at a set speed, dropping one connection on request):
  - a download cut off at 6 MB, then resumed after a relaunch (`Range: bytes=6029312-`)
  - paused at 9.9 MB, relaunched, and resumed (`bytes=9961472-`)
  - installed with every file's SHA-256 right
  - removed, leaving nothing in `Model Packs/`
  - Settings rendered behind the wallpaper in every state, light and dark (`debug/modelpack-render`)

## The L2 pack (M6 step 2, 2026-10-17)

PP-OCRv6 small, converted again from PaddlePaddle's pinned revisions on Hugging Face by
`Tools/model-packs/ppocr_pack.py` (`convert`, `check`, `assemble`; the spike's converted models were gone). The
PyTorch weights match the ONNX exports to 1.3e-6 (detection) and 5.7e-5 (recognition) before conversion. The pack is
16 MB in 10 files: the two models as fp16 ML programs, `characters.txt` (18,708 characters; the recognizer's 18,710
classes are the blank, them, and a space), `config.json` (normalization, bands, thresholds, shapes), `LICENSE.txt`
(PaddleOCR's Apache-2.0 LICENSE with what was changed; PaddleOCR has no NOTICE), and a model card.

**Shapes, and reading in bands.** The spike's grid (24 detection sizes up to 1600 × 2560) skipped 6 of the 40 cases:
regions taller or wider than its largest size, such as 2016 × 512, 64 × 2624, and the 4000 × 768 tall page. The pack
reads a region as L1 reads a large picture instead:

1. The region is scaled so its shorter side is at least 736 and its width at most 4096, each side then rounded to a
   multiple of 32.
2. It is cut into bands 1280 tall that overlap by 256. Each line belongs to the band whose core holds its center
   (`PieceMerge`'s rule).
3. Each band is padded with zeros up to the smallest of 8 detection shapes that holds it: 640 or 1280 tall, by 640,
   1280, 2560, or 4096 wide.
4. Recognition pads a line, 48 tall, up to one of 12 widths from 160 to 4000. The widest line in the benchmark is
   2470.

Scaling the shorter side up to 736 (transformers' preprocessing) instead of 64 (PaddleX's) read better here.

| Benchmark, 38 cases scored (Korean and vertical Chinese left out) | Mean content CER |
| --- | --- |
| Flexible sizes, PaddlePaddle's processing, shorter side 64 / 736 | 2.81% / 2.59% |
| The spike's grid, shorter side 64: the 32 cases it read (6 skipped) | 2.52% (the pack on the same 32: 1.89%) |
| The pack, bands, shorter side 64 / 736 | 2.78% / 2.40% |

Every case was read. Against the flexible-size reading at 736, the pack read a few cases worse: the editor with
its gutter (+2.2 points), 13 px text (+2.3), and the forum title (+1.8). It read the social sidebar much better
(0.7% against 8.7%; 16.7% at 64).

**Speed, natively** (`Tools/l2-spike/probe.swift`, `.cpuAndNeuralEngine`):

- **Compiling for the Neural Engine on first load:** 5.3 s for detection's 8 shapes and 5.6 s for recognition's 12
  widths, 11 s in all against the spike's 21 s. A second load takes 34 ms.
- **Where it runs:** detection entirely on the Neural Engine; recognition 94% there and 6% on the CPU.
- **Warm detection:** 4 ms at 640 × 640, 16 ms at 1280 × 1280, 49 ms at 1280 × 4096.
- **Warm recognition:** 2 ms at 320 wide, 8 ms at 1600, 23 ms at 4000.

**Where it reads.** The pack will be read in the text reader, the process beside the app that already reads the
history's text (decided 2026-10-17), not in an XPC service. The Shortcuts action Recognize Text in Image moved there
first (`TextReaderTool`): the same text as before (401 characters, 23 lines on the drawn page), the reader at 252 MB
at most and gone when it exits, and the app 24 → 31 MB, where reading in the app took it from 63 to 119 MB.

**Published** (2026-10-17, with the user's OK on the name and the file list):
[MoraxCheng/ohmyshot-ppocrv6-small-coreml](https://huggingface.co/MoraxCheng/ohmyshot-ppocrv6-small-coreml), public,
so the app downloads it without signing in, at commit `f163489663ba2ef788f3389c61d21c7308cc554d`. Checks:

- **Anonymous download at that commit:** every file has its listed size and SHA-256, and a `Range` request on the
  10 MB weights answers 206.
- **Listing:** `ModelPackCatalog.ppocrV6Small`, its mirror that commit's `resolve/` address. It is not in `packs`,
  so Settings doesn't offer it: until the text reader reads with it, it would be 16 MB that change nothing.
  `debug/modelpack-offer` offers it in Debug builds.
- **Through the Debug app:** the consent sheet showed the license fetched from Hugging Face; the download took the
  rest (the license was kept from the sheet); the installed files hashed right. Core ML compiled and loaded both
  models from the installed folder: 5.5 s and 6.1 s on first load, then warm at 9 ms (detection, 640 × 1280) and
  5 ms (recognition, 960 wide).

**Read in Swift** (`OMSOCR/PPOCRReader`, 2026-10-17). Every size, threshold, and normalization comes from the pack's
`config.json` (`PPOCRConfiguration`, which refuses a format or a shape set it can't use). The steps:

- **Models:** compiled once into the pack's own folder (`Compiled/`). The Neural Engine keeps its own compilation of
  them for readers signed alike: the Release reader loaded in 0.2 s a pack the Debug reader had compiled, so an update
  of the app shouldn't pay it again. Programs signed otherwise don't share it: the Debug reader took 11 s on a pack
  that `ocr-bench` and the test runner had compiled. A pack's first read takes those 11 s, so it is to be warmed in the
  background once installed (`ModelPackCenter.onInstalled`), never on a read someone waits on.
- **Detection:** the region is scaled and read in bands. Each band is padded up to a shape, and DBPostProcess turns
  its probabilities into boxes: regions above the threshold (`OMSPixels/BinaryComponents`, built with optimization
  always), their minimum-area rectangles, their mean probability, and the rectangle grown by the unclip ratio from
  corners cut to whole pixels, as pyclipper is handed them. The boxes are put in PaddleOCR's reading order.
- **Recognition:** each box is cut out with a cubic perspective warp, edges extended, and turned a quarter when it is
  vertical. It is scaled to 48 pixels tall and padded up to a width, and CTC decodes it greedily.
- **Pixels:** OpenCV's own rules (`OMSPixels/Resample`: `INTER_LINEAR` resizing, `INTER_CUBIC` warping with
  `BORDER_REPLICATE`, `np.rot90`), so the models get what they got in the Python check. A first port with Core
  Graphics and vImage scaling read 2.57%. vImage's affine warp counts y up from the bottom row, which first cut every
  line from the mirrored place.

| Benchmark, the same 40 cases (`ocr-bench --engine l2 --pack DIR`) | Mean content CER, 38 scored |
| --- | --- |
| The pack in Python (`ppocr_pack.py check`) | 2.40% |
| The pack in Swift | 2.60% |
| Flexible sizes, PaddlePaddle's processing, shorter side 736 | 2.59% |

37 of the 40 cases are within half a point of Python's. Of the three that aren't, the social sidebar reads the same 23
lines in another order: two boxes a pixel apart fall on either side of PaddleOCR's 10-pixel rule. The other two are
within a point. The boxes are a pixel or two off Python's, from OpenCV's fixed-point resizing and contour tracing,
which aren't copied. Swift's p50 is 123 ms and p95 872 ms (Release, warm, both models on the Neural Engine).

**In the text reader.** A job with `"pack": "<an installed pack's folder>"` reads with L2, its reader loaded once a run.
`TextReaderTool` takes the pack too. Run from the shell over two benchmark pictures:

- **A fresh copy of the pack:** 11.3 s (compiling both models and the Neural Engine's first compile).
- **Again, in a new process:** 0.37 s for both pictures, the load included.
- **The reader's footprint:** about 350 MB at most, gone when it exits.

`PPOCRTests` (18) cover the bands, rectangles, order, unclipping, boxes from a made-up map, CTC decoding, the
resampling against OpenCV's values, the homography, and the configuration. `aDrawnPageReadsBack` reads a drawn page
end to end when `OMS_L2_PACK` names a pack.

What was left here (when L2 reads, how its lines join L1's, warming, listing the pack) is done in the next section.

## L2 beside L1 (`SecondReading`, M6 step 3, 2026-10-17)

L2 reads as a second reader of L1's lines, never in L1's place. The OCR panel and the history's search use it once
the pack is installed; Capture Text, Translate Area, the annotation readings, and the Shortcuts action still read
with L1 alone.

**L1 and L2 compared** (`ocr-bench --engine l1 --engine l2 --pack DIR`, the 28 drawn cases and the 12 real regions).
L2 alone read worse on the whole, 7.5% mean content CER against L1's 2.0%:

- **No Hangul:** the Korean case read nothing (100%), and the multilingual case lost its Korean line (13.6%).
- **Vertical text:** read right, but its columns came out left to right.
- **None of L1's post-processing:** line numbers stayed (the editor with its gutter: 12.2% against 1.5%), and so did
  icons.

Line by line, with each L2 line paired to the L1 line holding half its box or more, and each scored against the
nearest line of the truth:

| L1's line | L2 better | Same | L1 better | Characters L2 gained | Characters L2 lost |
| --- | --- | --- | --- | --- | --- |
| Han or kana | 45 | 143 | 2 | 86 | 3 |
| Han or kana with Latin words | 64 | 44 | 2 | 143 | 2 |
| Latin script alone | 52 | 542 | 43 | 98 | 57 |

In Latin lines the two make different errors. L2 reads `->`, `=>`, and `useLocation` right; L1 reads `|`, `Oct`, and
a leading `-` right where L2 reads `I`, `0ct`, and nothing. L1's confidence is no guide: Vision gives 0.3, 0.5, or 1.

**The rule** (`SecondReading.merged`). L1 decides which lines there are, where, and in what order. Each L2 line goes
to the L1 line that holds half its area or more. It goes to none when it also holds half of another L1 line: L2 reads
a name and the time beside it as one line where L1 reads two. An L1 line with Han or kana and no Hangul takes the text
of the L2 lines it holds, side by side. It doesn't when those read fewer than four fifths as many characters.
Latin, Korean, and lines L2 left alone keep L1's text, with one exception (`isMisreadAsHangul`). With Korean among
the preferred languages, L1 reads the gaps its first pass left with the Korean model, which makes Hangul of small gray
Chinese type. A line holding Hangul where L2 read two Han or kana characters or more, none of them Hangul, at 0.9 or
more, takes L2's reading as it is. In a tall chat capture read that way, L2 read Chinese in 22 of L1's 28 Hangul lines.
On the benchmark's Korean it read nothing at all. An L2 line that no L1 line holds, and that no L1 line covers a
quarter of, is added when it has two Han or kana characters or more and a confidence of 0.9 or more. L1 had missed
sidebar entries, buttons such as "回复", and a forum's category names; below 0.9 L2 reads icons as Han ("凶"). A page is
read again only when L1's lines hold two Han or kana characters or more (`SecondReading.wanted`).

**How the text is written** (`SecondReading.dressed`). L2 reads the characters better and Vision their form, so the
two readings are aligned character by character, spaces aside and widths folded:

- **Width:** a character both read alike takes L1's form. L2 writes "?", "(", and ")" half-width in Chinese at
  times, and digits full-width in Japanese ("午後２時").
- **Spaces:** where Han meets a Latin letter or a digit, they follow L1, which measures them in the ink. L2 leaves
  most of them out ("降到了10 ms以内") and puts one in where there is none ("打开 App Store"). Elsewhere a space either
  reading has is kept ("- 已全额支付", where L1 lost it).
- **Doubled marks:** a mark L2 reads twice where L1 reads it once ("px: ：") is read once.
- **Ellipsis:** L2's "..." is L1's "…" when L1 reads that.
- **Icons:** an icon before Chinese text that the two read as different symbols ("$ 开发调优" and "<>开发调优") goes.

The rule was tuned on the 40 cases above, then run once, unchanged, on the 12 real regions shrunk and recompressed
as a chat app sends them:

| Mean CER, L1 → L1 with L2 | Content | Raw | Cases worse |
| --- | --- | --- | --- |
| 28 drawn cases and 12 real regions (tuned on) | 1.99% → 1.48% | 3.78% → 3.33% | none |
| The 12 real regions downscaled (held out) | 5.76% → 4.69% | 10.32% → 9.45% | none |

The largest gains were all on real regions and dense small type:

| Case | Content CER, L1 → L1 with L2 |
| --- | --- |
| A forum's sidebar | 13.2% → 9.6% (downscaled 9.6% → 5.3%) |
| The same thread | 6.1% → 4.6% |
| 9 px Chinese | 2.4% → 0% |
| A Traditional Chinese page | 1.3% → 0% |
| A social sidebar | 2.0% → 0% |

Korean, vertical Chinese, both code editors, and the terminal listings read exactly as L1 reads them. In the
benchmark's own process, warm, a case took p50 216 → 297 ms and p95 652 → 766 ms; L2 runs only on pages with Han or
kana.

**Where it reads:**

- **The history's search.** The text reader reads Vision with the pack beside it (`PairedReading`) when a job names
  the pack. A pack that won't load, or a reading of it that fails, leaves Vision's reading. The kept text records the
  pack it was read with (`HistoryText.reading`). Once a pack is installed, captures read without it whose text holds
  Han or kana are read again; English ones are not. A pack removed leaves what it read, and a new version of it reads
  again. Older kept texts, which say nothing of a pack, count as read by Vision alone.
- **The OCR panel.** Vision reads in the app as before: text, tables, and codes. When its lines hold Han or kana, the
  picture is written to an uncompressed TIFF and the text reader reads it with the pack alone (`TextReaderTool.lines`).
  Its lines are put beside Vision's in the app (`TextAnalysis.withSecondReading`), and the tables take their cells
  from the merged lines again. The panel waits 3 s for that reading after Vision's, then shows Vision's alone. The
  reader isn't stopped when the wait ends. By then it is most likely compiling the models, and stopped, it would start
  that again on every panel.
- **Warming.** Once the pack is installed, it is loaded in the text reader at utility priority (`TextReaderTool.warm`)
  to compile its models for the Neural Engine, and the history is then read as above.
- **Settings.** `ModelPackCatalog.packs` lists the pack now, so Settings › Tools offers it.
- **Large pictures:** L2 reads in L1's pieces (`PictureText.pieces`) and merges them with `PieceMerge`. A picture L1
  cuts across (`PictureText.isCutAcross`) isn't read with L2, which would shrink it to 4096 wide.

**The text reader with the pack** (run from the shell, Debug build unless noted, a new process each run):

| Reading | Time | Peak footprint (resident size for the chat list) |
| --- | --- | --- |
| Warming a pack in a folder never compiled | 10.4 s | — |
| Warming once compiled | 0.05–0.08 s | — |
| A 366 × 1749 chat list, the pack alone (the panel's reading), compiled | 0.53 s | 172 MB |
| The same, Vision with the pack (the history's reading) | 0.87 s | 220 MB |
| The same, Vision alone | 0.35 s | 110 MB |
| Full-screen captures (2000–4112 wide), the pack alone | 0.95–2.52 s (Release 0.97–2.23 s) | 494–810 MB |
| The same captures, Vision with the pack | 1.5–4.1 s | 655–944 MB |
| The same captures, Vision alone | 0.6–1.4 s | 283–405 MB |
| The tallest capture in the history, 3346 × 16811, the pack alone | 4.8 s | 1009 MB |
| The same, Vision with the pack | 7.4 s | 1236 MB |
| The same, Vision alone | 3.3 s | 589 MB |

So the panel shows a Chinese full-screen capture's text 1.7–2.5 s later than before, within its wait. The history,
read again after the install, keeps one reader of about 1 GB running for as long as there are captures to read.

**Where the memory goes.** Core ML keeps working memory for each of the recognizer's enumerated widths it has used
(a probe of the recognizer alone, 20 predictions at one width):

| Width | 160 | 320 | 640 | 1600 | 4000 | All 12 in turn |
| --- | --- | --- | --- | --- | --- | --- |
| Footprint over the loaded model | 13 MB | 15 MB | 42 MB | 103 MB | 257 MB | 1.1–1.5 GB, steady |

It is no leak: 200 predictions at one width added 30 MB. The size comes from the output, a probability for each of
18,710 classes at every step, crossing from the Neural Engine to the CPU (› The recognizer's head on the CPU). None of
these moved the reader's peak:

- autorelease pools (the synchronous calls in pools took it to 3.4 GB)
- output buffers of the reader's own
- `malloc_zone_pressure_relief` after each piece
- decoding a step at a time instead of copying the output whole
- four widths instead of twelve: 1.50% CER against 1.48%, and no less memory

Turning off libmalloc's large-block cache (`MallocLargeCache=0`) took the history's reading of the tallest capture
from 1236 to 985 MB. It is undocumented, so it isn't used.

`SecondReadingTests` (16) cover:

- which lines take L2's reading
- a line two L1 lines share
- a reading too short
- pieces side by side and top to bottom
- the lines L2 adds and those it doesn't
- widths, spaces, doubled marks, the ellipsis, and icons

`HistoryTextTests` (3 more) cover reading again with a pack. `TextReaderToolTests` (2 more) cover the lines and warming
jobs.

**Not done yet:**

- **A pack whose recognizer gives each step's likeliest class and its probability**, two values a step instead of
  18,710. Tried: it didn't shrink the memory. Pack v2 applies the recognizer's last layer on the CPU instead
  (› The recognizer's head on the CPU).
- **L2's reading of Latin lines**, which reads arrows and the case of identifiers better than Vision does, and
  Capture Text, Translate Area, and the Shortcuts action, which read with L1 alone.

**In the Dev app** (Debug build, 2026-10-17, the pack downloaded through the app with the user's OK):

- **Installing:** the download from Hugging Face took 18 s. Warming took 10.9 s, the reader itself at 24 MB: the
  Neural Engine compiles in a service of its own. The app stayed at 24–26 MB.
- **The history read again:**
  - 46 of 91 captures held Han or kana and were read again, in 4 min 31 s at background priority, the reader at
    1073 MB at most. 38 of their texts changed, by a median of 11 characters; no English text was touched.
  - The most changed were tall scrolling captures, whose texts had been kept since earlier versions of L1. In the two
    most changed, L2 added 110 and 65 lines L1 had missed, most of them small type.
  - Twelve runs of four Han characters that none of the history's texts held before were each found by the search, in
    one capture each.
  - The merge's revision raised (`ppocr-v6-small/1/merge-2`) read 43 of them again at utility priority in 96 s, the
    reader at 1494 MB at most. The texts came out the same: with English and Chinese preferred, L1 never reads Hangul.
- **The OCR panel:**
  - **The drawn demo page:** L2 read its 23 lines in 0.35 s and changed none.
  - **Three real captures:** 2000 × 1254 took 1.55 s, with 14 of 75 lines changed and 11 added. Two 4K captures took
    2.0 s (19 of 103 changed) and 2.69 s (8 of 131 changed), the second close to the 3 s wait.
  - **The reader during these readings:** 381–674 MB at most, 0.6–2.3 s.
  - **A one-off:** the first real one took 21.5 s in all, L2's part 1.6 s. Opened again it took 2.6 s; not looked
    into.
  - **The app afterwards:** 150 MB after four panels. That is mostly freed blocks libmalloc keeps (49 MB large,
    33 MB small), as the panel's Vision reading left 110–125 MB before (Docs/perf.md, M2). Writing a 4K picture as
    TIFF, alone, leaves 1 MB.

## The recognizer's head on the CPU (pack v2, 2026-10-17)

Version 2 of the pack ends the recognizer at its encoder. The reader applies the last layer, the linear map from 120
features to the 18,710 classes, in Accelerate (`PPOCRHead`). The text is the same as with version 1, and L2 reads a
little faster. On full-screen captures the text reader needs less than half the memory for the pack alone, and about
a third less for Vision with the pack.

**Why the memory went** (a probe of the recognizer alone, each of the 12 widths in turn, 60 predictions each,
`.cpuAndNeuralEngine`). Core ML ran the 18,710-class linear on the Neural Engine and the softmax after it on the CPU,
so a [steps, 18,710] tensor crossed from the Neural Engine at every width. Core ML keeps that crossing's buffers for
each width it has used:

| Recognizer | Over the loaded model, all 12 widths | At 4000 wide, p50 |
| --- | --- | --- |
| Version 1: probabilities out, [1, steps, 18,710] | +762 MB | 17.7 ms |
| The likeliest class and its probability out (reduce_max, reduce_argmax) | +755 MB | 15.7 ms |
| Version 1 on the CPU alone | +187 MB | 29.9 ms |
| The encoder alone, [1, steps, 120] out | +190 MB | 5.2 ms |
| The encoder, then the head in Accelerate (version 2) | +99 MB | 15.5 ms |

Tried and dropped:

- **The likeliest class at the output** (`L2 beside L1` › Not done yet): the linear stays on the Neural Engine, and
  so does the cost.
- **The head kept in 32-bit floats inside the one model,** so that only it would run on the CPU: Core ML put the whole
  graph on the CPU (168 operations, none on the Neural Engine).
- **The recognizer on the CPU** (`.cpuOnly`, the detector left on the Neural Engine). The two drawn pages below were
  read whole, before `PPOCRReader` read in pieces: 374 and 688 MB, in 2.7 and 9.4 s. The probe's own encoder and head,
  measured the same way, took 341–356 and 594–601 MB, in 2.4 and 7.7–8.1 s. On the CPU the text also differed, by 6
  and 18 characters of content, as the CPU rounds 16-bit floats otherwise. It would have needed a setting per model
  in `config.json` as well, whose hash the catalog pins.

**The pack** (`Tools/model-packs/ppocr_pack.py`, `config.json` format 2):

- **`rec.mlpackage`** outputs `features`, [1, W/8, 120].
- **`head.bin`** holds the layer's weights, 18,710 × 120 row by row, then its 18,710 biases, as little-endian 16-bit
  floats (4,527,820 bytes).
- **`config.json`** names it: `"head": {"file": "head.bin", "type": "float16", "inputs": 120, "classes": 18710}`.
- **`convert` checks the split:** the encoder's output through the head is 9.3e-6 from the whole model's
  probabilities. The 16-bit head picks the ONNX export's class at every step.
- **`check` applies the head in NumPy:** mean content CER 2.40% over the 38 cases scored, as for version 1. No
  case's CER changed; one real case swaps one wrong character for another.
- **`assemble --detection <version 1>`** takes the published detector, after checking its weights are the ones
  converted. A new conversion writes the same weights with another date and other identifiers. So `det.mlpackage`
  and `characters.txt` are version 1's files, byte for byte.
- **Size:** 11 files, 15,829,753 bytes, against version 1's 10 files and 15,829,675. The recognizer's weights went
  from 10,543,020 bytes to 6,015,024 plus the head.

**Reading.** `PPOCRConfiguration` reads format 1 without a head and format 2 with a `float16` head, and refuses
anything else. `PPOCRReader.load` reads `head.bin` once, checks its size against the head's classes and inputs, and
checks the classes against the characters. It keeps the weights as 32-bit floats, turned (9 MB). For each line, the
reader:

1. multiplies 32 steps of features at a time by the weights (`vDSP_mmul`), and adds the biases
2. takes each step's likeliest class as its largest logit (`vDSP_maxvi`)
3. works out the softmax only at a step CTC keeps: 1 / Σ exp(logit − the largest)

A format-1 pack reads as before.

**Two drawn pages, whole L2 readings** (`PPOCRReader.load` and `recognize` in a Release probe, in `PictureText`'s
pieces with `PieceMerge` between them). Three readings each, peak = the ledger's peak footprint:

| Page | Version 1 | Version 2 |
| --- | --- | --- |
| 3840 × 2160, dense Chinese, Japanese, and Latin, 122 lines (one piece) | 1484–1495 MB, 3.0–3.1 s | 357–363 MB, 1.9–2.0 s |
| 2560 × 9000, 549 lines (five pieces) | 1509–1561 MB, 12.0–12.3 s | 323–324 MB, 9.0–9.3 s |

Every line read the same content; 8 lines on each page differ in spaces alone.

**The benchmark** (`ocr-bench --engine l1 --engine l2 --engine l1+l2 --pack DIR --real DIR`, one build, a fresh copy
of each pack, Release; the second round's times):

| Mean CER, version 1 → version 2 | Content | Raw | Cases worse | Output |
| --- | --- | --- | --- | --- |
| L1 with L2, 40 cases | 1.48% → 1.48% | 3.33% → 3.33% | none | identical in 40 |
| L1 with L2, the 12 real regions downscaled | 4.69% → 4.69% | 9.45% → 9.45% | none | identical in 12 |
| L2 alone, 40 cases | 7.49% → 7.49% | 11.70% → 11.69% | none | the same content in 40; one case's spaces differ |

| Time per case | p50 | p95 | Max |
| --- | --- | --- | --- |
| L2 alone | 126 → 113 ms | 933 → 766 ms | 4032 → 2853 ms |
| L1 with L2 | 306 → 294 ms | 822 → 778 ms | 7690 → 6345 ms |

**SecondReading's 0.9 gates.** The two packs' line confidences differ:

- **Lines read alike, over the benchmark and the downscaled regions** (52 pictures, 1214 lines, all but two read
  alike): 0.0127 at most.
- **Lines between 0.85 and 0.95:** 0.0007 at most (48 lines). The 0.0127 is on a line above 0.95.
- **The line closest to 0.9:** 0.9005 with version 1, 0.9002 with version 2.

No line crosses 0.9 either way.

**The text reader** (Helpers/TextReader/main.swift, built from the shell with SwiftPM in Debug, the same code for
both packs, a new process per reading, peak = `/usr/bin/time -l`'s peak footprint, the models compiled; the first
reading with Vision in a new build, 38 s, was read again). These
pictures are the full-screen captures and the tallest capture in the history, as in › L2 beside L1. That section's
numbers came from the app's own build of the reader, so only the two columns here compare exactly.

| Picture | The pack alone (the OCR panel), v1 → v2 | Vision with the pack (the history), v1 → v2 |
| --- | --- | --- |
| Full-screen captures, 2000–4112 wide (10) | 464–724 → 174–327 MB, 1.1–2.9 → 1.0–2.3 s | 640–931 → 394–611 MB, 1.7–4.6 → 1.6–3.8 s |
| Of them, the four 4K ones | 636–724 → 324–327 MB | 816–931 → 603–611 MB |
| The tallest, 3346 × 16811, four runs | 982–1014 → 806–808 MB, 4.9–5.6 → 4.4–4.7 s | 1145–1232 → 925–981 MB, 7.5–8.4 → 7.1–7.7 s |
| All 11 in one process, as the history is read again | — | 1236 → 1066 MB, 35.9 → 32.1 s |

| One process, warm, the 10 full-screen captures three times | p50 | p95 |
| --- | --- | --- |
| The pack alone | 1.63 → 1.39 s | 2.99 → 2.28 s |
| Vision with the pack | 2.49 → 2.15 s | 4.22 → 3.72 s |

The answers were byte for byte the same with both packs, for all 11 pictures in both modes.

**On the tallest capture,** what is left is detection, not the recognizer:

- Decoding the picture peaks at 266 MB by itself.
- The footprint then climbs with each of its ten pieces, 280 to 510–640 MB, all read as 1280 × 4096 bands. The
  detector's probability map crosses from the Neural Engine too.
- With version 1, the first piece's recognition alone added 400 MB.

Where that climb came from, and what took it out: › Tall pictures in the L2 reader, below.

`PPOCRTests` (20; 2 new) cover the format-2 configuration rules, the head decoding as `decode` does over its
softmax, across the 32-step chunks, and a head file's layout and sizes. `aDrawnPageReadsBack` passes with either pack.

**Published** (2026-10-17, with the user's OK): the 11 files as commit `787b19abc12b19a2b3faa3258777a330036ef222` of
MoraxCheng/ohmyshot-ppocrv6-small-coreml, on top of version 1's `f163489`, which still serves version 1.

- **Anonymous download at that commit:** every file has its listed size and SHA-256. A `Range` request on `head.bin`
  answers 206.
- **Listed:** `ModelPackCatalog.ppocrV6Small` is version 2, its mirror that commit's `resolve/` address.
  `ModelPackTests.theL2PackIsTheOneUploaded` checks the commit, the 11 files, and their 15,829,753 bytes.
- **What a build with it does:**
  - It doesn't read version 1. Version 1's folder is removed as unused when Settings › Tools next reads the packs
    (`ModelPackCenter.refresh`).
  - L2 is off until version 2 is downloaded there: 15.8 MB, with the consent sheet again.
  - Then the kept texts' reading, `ppocr-v6-small/2/merge-2`, reads the Chinese and Japanese captures again once.
    They come out with the same text.

## Tall pictures in the L2 reader (2026-10-17)

With pack version 2, the tallest capture in the history (3346 × 16811, ten pieces) still took about 800 MB for the
pack alone. Two things in `PPOCRReader` made the footprint climb piece after piece. Both are gone, and the lines read
are the same: text, confidence, and box.

**Where the footprint went** (a Release probe of `recognize`'s steps against OMSOCR, `phys_footprint` sampled every
millisecond, the tallest capture):

- **Each piece's pixels were drawn from `image.cropping(to:)`.** The footprint at the start of each piece was a
  piece's pixels (26 MB) more than at the last one's, for as long as the picture lived. A probe without Core ML shows
  it: ten times, draw a piece's crop into `PPOCRPixels`, then make one more array a piece in size. The footprint went
  from 56 to 275 MB. Drawing the crops alone, or making the two arrays without drawing, stayed flat. Why the two
  together keep memory wasn't pinned down: malloc's size in use grew by 26 MB with each crop drawn, even where the
  footprint stayed flat.
  - `PPOCRPixels(image, region:)` now draws the whole picture, moved so that the region lands in the bitmap. The same
    probe stays at 82 MB.
  - The bytes are the crop's, checked for every piece in seven formats: Display P3 RGBX, sRGB RGBA premultiplied
    with alpha last and first, gray, 16-bit RGBA, CMYK, and 16-bit floats in extended P3. Each was tall (with a short
    last piece) and wide (cut across), drawn from memory and from a PNG read back as `PictureText.image` reads it.
    The tallest capture's ten pieces were checked too.
  - A picture in the extended P3 space draws neither way, as before: `PPOCRPixels`' 8-bit context refuses that space,
    so L2 finds the picture unreadable.
- **The detector's map.** Each prediction at 1280 × 4096 grew the footprint by about 40 MB, which came back only
  later. Reading detection alone, the footprint climbed by 80 MB a piece, to 1.1 GB. `detect` now gives Core ML an
  array of its own to write the map into (`MLPredictionOptions.outputBackings`): the output's own type from the model's
  description (16-bit floats here), 1 × 1 × H × W, one for all of a piece's bands. With it, the footprint doesn't
  climb. A type other than 16- or 32-bit floats would read as before, without one.
- **The band's part of the map** was copied out of a 32-bit copy of the whole map. It is read straight from the
  backing now (`MLMultiArray.floats(rows:columns:)`), 9–10 MB less at the peak.

| The tallest capture, the pack alone | Peak (runs) | Lines |
| --- | --- | --- |
| Before (the probe's steps) | 793–794 MB (3) | 196 |
| Pieces drawn from the whole picture | 583 MB (1) | the same |
| And the map written into a backing, then copied whole | 479–482 MB (6) | the same |
| And the band's rows read from the backing | 470–473 MB (6) | the same |
| The shipped path (`PPOCRReader.load`, then `recognize`) | 797–798 MB (2) → 474–476 MB (3); 3.36–3.39 → 3.32–3.36 s | the same |

Tried and dropped, as they didn't lower the peak:

- **Synchronous predictions,** with or without an autorelease pool around each: 853–855 MB, against 793.
- **One input array for every band** of a reading.
- **A 16-bit input** (the detector's own input type): a plain array, 502 MB; on an IOSurface pixel buffer, 472 MB.
- **A backing kept for the whole reading** rather than for a piece: the same peak.
- **`malloc_zone_pressure_relief`** between pieces: it frees nothing.

**What is left,** about 475 MB on the tallest:

- **The decoded picture.** Once `PictureText.image` has decoded it, the footprint doesn't count it (42 MB just after).
  Each draw of a piece counts its 215 MB again while the draw lasts, so every piece's peak is its draw: about 255–283 MB
  before the draw, 470 MB during it.
- **Freed buffers malloc keeps.** At the end of a reading, vmmap shows 121–181 MB of "Malloc Large (empty)".
  - With `MallocSpaceEfficient=1` in the environment, the peak is 339 MB, and 67 MB after the reading. With
    `MallocLargeCache=0` it is 343 MB.
  - Neither variable is in `man malloc`: they were found as strings in the shared cache. What else they change wasn't
    looked into; with `MallocLargeCache=0` the process starts at 16 MB instead of 42.
  - Neither is used. Setting one in the text reader's environment is the user's decision.
- **The next cut** would be to read a tall PNG's rows piece by piece, as History's thumbnails are read
  (`PNGThumbnail`), and never hold the whole picture. Done the same day: › Pieces of a tall PNG, from the file, below.

**The text reader,** before and after, as measured in › The recognizer's head on the CPU (Docs/perf.md › M6 — The L2
reader on tall pictures has the rest):

| Picture | The pack alone | Vision with the pack |
| --- | --- | --- |
| The tallest, three runs | 807–812 → 475–480 MB | 940–963 → 750–763 MB |
| Full-screen captures (10) | 179–332 → 166–329 MB | 323–606 → 319–557 MB |
| All 11 in one process | — | 973 → 805 MB |

**The benchmark** (`ocr-bench --engine l1+l2`, a fresh copy of the pack for each build, Release): all 40 cases read
the same, with mean content CER 1.48% and raw 3.33% for both builds. The text reader's answers were byte for byte the
same for all 11 pictures in both modes.

The answers are the same, so the kept texts' reading, `ppocr-v6-small/2/merge-2`, stays.

**Vision's pieces** are still handed to it as `image.cropping(to:)` (`VisionPipeline.readImage`). In a probe of Vision
alone on the tallest capture, drawing each piece into a bitmap of its own first lowered the peak from 597–603 MB to
528–540, and what stays after the reading from 507–511 MB to 290–300. That is left for later: Vision's output with drawn
pieces wasn't compared, and the benchmark would need to show L1 unchanged.

## Pieces of a tall PNG, from the file (`PictureText.Bands`, `PNGBands`, 2026-10-17)

The text reader no longer decodes a tall PNG whole. `PPOCRReader.recognize(fileAt:)`,
`VisionPipeline.recognize(fileAt:)` and `PairedReading.recognize(fileAt:)` read each piece's rows from the file as it
comes, and the text reader hands them the file's path. The answers are byte for byte the same. On the tallest capture in the
history, the pack alone peaks at 279–287 MB instead of 477–481, and Vision with the pack at 523–556 MB instead of 758–768.

**How a piece is read.** `PNGBands` (OMSPixels) inflates the file's pixels a row at a time, as `PNGThumbnail` does for
History's cards. It undoes each row's filter and lays the row out as ImageIO lays out the decoded picture:

| The PNG | Laid out (as ImageIO decodes it) |
| --- | --- |
| RGBA, 8 bits | RGBA, alpha last, not premultiplied: the file's bytes |
| RGB, 8 bits | RGBX: a fourth byte of 255 |
| Gray, or gray with alpha, 8 bits | as in the file |
| Gray, 1, 2 or 4 bits | one byte a pixel, scaled up to 0–255 |
| Any of those at 16 bits | 16-bit samples, little-endian |
| A palette, 1 to 8 bits | one index a byte, in ImageIO's indexed color space |

`PictureText.Bands` asks ImageIO for the picture without decoding it (`kCGImageSourceShouldCache: false`). It reads the
format, color space, decode array and rendering intent from that, and makes each run of rows a `CGImage` of its own with
all of them. Every conversion is then CG's own, as before: gray or a palette to sRGB, 16 bits to 8, alpha over white.
If ImageIO's format isn't the one `PNGBands` laid out, the file is decoded whole instead.

- **L2** draws each piece into its `PPOCRPixels` in strips of at most 4 MB, each strip a picture of its own drawn
  where it belongs (`Bands.draw`).
- **Vision** gets each piece as one picture of its rows (`Bands.image(of:)`).
- **The file** is mapped, not read in: opening the tallest capture (a 13 MB file) this way added 1 MB to the
  footprint, and inflating every row of it, 10 MB.
- **Overlapping rows.** Pieces overlap by 256 rows: `PNGBands` keeps the last 256 rows it laid out, and a piece starts
  among them.

**What is read this way:** a picture in more than one piece, every piece across its whole width (not cut across), not
interlaced, without a `tRNS` chunk. Before the pixels it may carry iCCP, sRGB, cICP, gAMA, cHRM, sBIT, bKGD, pHYs,
text and time chunks, and eXIf. Everything else is decoded whole, as before:

- **Interlaced:** Adam7 spreads every row over the whole file, so each piece would inflate most of it again.
- **`tRNS`:** it turns ImageIO's layout into RGBA.
- **One piece:** a single piece gains nothing.
- **Other chunks** (an APNG's, Apple's iDOT): not tried.

A file whose pixels end before its last piece is decoded whole after all (`Bands.Ended`), and read as far as ImageIO
makes it out.

**The same pixels.** The rows and the drawn pixels were compared byte for byte (a probe, then `PictureBandsTests`):

- **Rows** against ImageIO's decoded picture.
- **Pixels**, in strips and as one picture a piece, against `PPOCRPixels(image, region:)` of the decoded picture, for
  every piece of `PictureText.pieces`.
- **Generated files**, 4700 tall, all five filters: 8- and 16-bit RGBA, RGB, gray, and gray with alpha; gray at 1, 2
  and 4 bits; palettes at 1, 2, 4 and 8 bits. Also RGBA with a Display P3 profile, an sRGB chunk, cICP for P3 and for
  PQ, gAMA, gAMA with cHRM, sBIT, bKGD, and text chunks.
- **Real captures:** the five tallest in the history (8237–16811 tall), and the ten in Tools/ocr-bench/real/source.
- All the same. Interlaced files, and files with `tRNS` on a palette, RGB or gray, are declined.

**Why strips.** Each L2 piece was first drawn from one picture of its rows. The answers were the same, but the peak
went up, to 512–527 MB, and the footprint climbed by about 25 MB with every piece and stayed there.

- **Not a leak.** At the end of a reading, malloc's live blocks were the same as with the decoded picture, and every
  piece's buffer had been freed. With `MallocLargeCache=0`, the same reading peaked at 220–227 MB (the decoded picture's
  path: 338–341).
- **Freed blocks malloc keeps dirty.** The 25 MB a piece were dirty pages in malloc's large regions, not blocks in use.
  The same draws and allocations without Core ML's predictions between them stayed flat.
- **Where the rows lived mostly didn't matter.** The climb was the same with the rows in a `CFData`, a malloc'd buffer,
  a mapping of their own, or one buffer kept for every piece, with or without an autorelease pool. The likeliest block
  is one CG makes to draw a piece's picture, its copy of the rows converted for drawing; that can't be watched from
  outside.
- **One case stayed flat and isn't explained:** the rows in an `NSMutableData` with an autorelease pool around making
  each piece's picture, 291–297 MB, twice. Without the pool an `NSMutableData` climbs too, and for a reason of its own:
  its `mutableBytes` comes with the data autoreleased, and the reader's task drains no pool until it ends, so every
  piece's rows stayed to the end.
- **Drawn in strips,** no block is a piece's size, and the footprint stayed flat however the rows were held. Strips of
  64 to 512 rows of the tallest capture (0.9–6.8 MB) kept the peak at 272–292 MB; 1024 rows (13.7 MB) climbed again.
  It stayed flat with malloc's medium zone turned off (`MallocMediumZone=0`, as on a Mac with less memory), at
  273–285 MB. Strips were kept rather than the pool, whose flat result hung on how the allocator happened to hand out
  blocks. `Bands.stripBytes` is 4 MB, measured against the larger of a row as read and as drawn. The rows are in a
  `CFData`, which nothing autoreleases.

**The text reader,** before (e8dc373 with › Tall pictures in the L2 reader above) and after. Built from the shell with
SwiftPM in Debug, a new process for each reading, peak from `/usr/bin/time -l`, pack version 2 (Docs/perf.md › M6 —
Pieces of a tall PNG has every run):

| Picture | The pack alone | Vision with the pack |
| --- | --- | --- |
| The tallest, 3346 × 16811, ten pieces (three runs) | 477–481 → 279–287 MB | 758–768 → 523–556 MB |
| The next four in the history, 8237–9875 tall, five or six pieces | 392–448 → 287–311 MB | 568–720 → 458–547 MB |
| 4K screens, 2574–2579 tall, two pieces (4) | 328–329 → 320–321 MB | 480–558 → 457–533 MB |
| Screens in one piece (6), read as before | 167–180 → 165–178 MB | 322–421 → 324–419 MB |
| All 15 in one process (the history read again, twice) | — | 921–932 → 806–808 MB |

- **The same answers,** byte for byte, for all 15 pictures in both modes, and for all 15 in one process.
- **Vision alone** (a Debug probe, two runs): the tallest went from 618–623 to 388–395 MB. A 4K screen in two pieces
  went from 396–401 to 388–392 MB at the peak, but kept 333–336 MB after its reading instead of 285–288.
- **A 4K screen in two pieces with the pack** read once at 480 → 533 MB, and three others lower (558 → 522, 494 → 467,
  492 → 457). The probe of that capture, three runs each way, gave 536–549 → 523–541 MB.

**Times** (Release, warm, one process per build, the nine pictures in more than one piece read twice, two runs each):
the pack alone went from p50 2.40 to 2.27 s, as no picture is decoded whole. Vision with the pack went from p50
4.05–4.14 to 4.12–4.18 s: each reading now inflates the file itself, once for Vision and once for L2, where the
decoded picture served both.

**The benchmark** (`ocr-bench --engine l1+l2 --real`, Release, a fresh copy of the pack for each build): all 40 cases
read the same, with mean content CER 1.4842% and raw 3.3305% for both. It reads pictures in memory, so what it checks
here is the reorganized `recognize(_:)` of the three readers; the files' path is checked by the text reader above.

**Left as it is:**

- **One piece.** A screen in one piece is decoded as before. It would gain little: 4K screens in two pieces, read from
  their files, took 8 MB less with the pack alone.
- **Vision's pieces of a picture in memory** (Capture Text, the OCR panel) are still crops, as are the pieces of an
  interlaced PNG or a JPEG in the text reader.
- **`tRNS` and interlaced PNGs** could be read too: their layout would have to be RGBA with alpha from the chunk, and
  Adam7 would need every piece to inflate most of the file again. OhMyShot writes neither.
