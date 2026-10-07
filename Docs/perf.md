# Performance log

Every milestone ends with a power gate. Numbers here are measured, never estimated. Reproduce them with
`Scripts/power-sample.sh` (CPU, idle wakeups, footprint) and `Scripts/latency.sh` (latency probes).

Targets: idle CPU 0.0% (60 s average), fewer than 1 idle wakeup per second, footprint under 30 MB after
launch and under 60 MB after use.

## M0 — foundations (2026-10-07)

Debug build (`-Onone`), MacBook Pro M3 Max, macOS 27.2 beta, two displays (3440×1440 at 2× HiDPI as
primary, built-in XDR in a scaled mode). The app sat in the menu bar with no window open.

| Measurement | Result | Target |
| --- | --- | --- |
| Idle CPU, 60 s | 0.00% average, 0.0% peak | 0.0% |
| Idle wakeups, 60 s | 0 | < 60 |
| Footprint after launch | 14 MB | < 30 MB |
| CPU time to launch | 0.13 s | — |
| Footprint after opening and closing Settings and onboarding | 35 MB, 0 leaks, no live resources | < 60 MB |
| App size | 2.2 MB Debug, 1.3 MB Release | < 30 MB |

### Findings

- **Never touch `AVCaptureDevice` at launch.** Reading the microphone or camera permission status
  initializes AVFoundation's capture stack, which loads every camera plug-in on the Mac. On this machine
  that cost 2.8 s of CPU and about 30 MB of memory before any window appeared (launch CPU 2.93 s and
  footprint 44–49 MB, versus 0.13 s and 14 MB without it). `PermissionCenter` now reads statuses only on
  request; launch reads Screen Recording alone.
- **SwiftUI windows leave about 20 MB of framework caches behind.** After the first settings window closes,
  the controllers are released (verified with `heap`) and `leaks` reports nothing, but SwiftUI, AppKit,
  and font caches stay resident. Returning freed pages with `malloc_zone_pressure_relief` changes little.
  This is within the after-use budget; surfaces that are always on (status item, overlay) stay AppKit.
- **Signposts are not persisted** unless a tool records them, so latency is logged by `LatencyProbe` as
  persisted `latency <name> <ms> ms` notices, which `Scripts/latency.sh` reads.
