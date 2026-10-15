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
