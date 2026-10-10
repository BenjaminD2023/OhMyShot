# Recording spike

How the M4 recording decisions were measured (Docs/perf.md › M4 — recording spike). Nothing here is
built into the app.

`encode-bench.swift` is the encoder half: synthetic 4:2:0 frames (glyph blocks, or real text drawn with
Core Text at 2×) through AVAssetWriter with the recorder's settings, nothing read from the screen.

```sh
swiftc -O -parse-as-library -target arm64-apple-macos26.0 -o /tmp/encode-bench Tools/recording-spike/encode-bench.swift
/tmp/encode-bench probe              # the encoder each codec and size gets, hardware or not
/tmp/encode-bench keys               # the compression properties AVAssetWriter accepts
/tmp/encode-bench limits             # the frame shapes H.264 still encodes in hardware
/tmp/encode-bench matrix [frames]    # throughput, CPU per frame, and bitrate across sizes and codecs
/tmp/encode-bench realtime [seconds] # paced at the frame rate: CPU while recording
/tmp/encode-bench textrealtime       # the same on real text
/tmp/encode-bench quality            # bitrate by quality on real text, with a 1:1 still of each
```

Files go to `$BENCH_DIR` (the temporary folder by default) and are removed, except the quality stills.
CPU is this process plus VideoToolbox's encoder service (`VTEncoderXPCService`).

The stream half runs in the Debug app: `open -g 'ohmyshot-dev://debug/record-demo?seconds=5&w=1280&h=720&fps=60&speed=240'`
records a window of scrolling text the app draws behind the desktop picture through the real recorder and
logs frames, drops, bitrate, and the CPU of the app, the encoder service, and replayd.
