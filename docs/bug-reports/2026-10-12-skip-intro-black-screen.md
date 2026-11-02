# Player goes black after Skip Intro (2026-10-12, Mac simulator)

**Build:** Phase 1 (`017e673`), iPhone 17 Pro simulator, iOS 26.2 runtime, Xcode 27.0.

**What happened:** an episode started playing normally. After pressing **Skip Intro**,
the video went black and playback never resumed. No failure screen appeared.

**Log:** `2026-10-12-skip-intro-black-screen.log` (removed once fixed) was the simulator's unified log for the
`Anilili` process over the last 40 minutes (`xcrun simctl spawn <udid> log show --last 40m
--predicate 'process == "Anilili"'`). It held AVFoundation/CoreMedia/AVKit entries only:
the app's own `[Anilili]` lines go through `print()` to stdout, so they are not in it. The
in-app Debug log was not copied.

**Not yet looked into:** the cause. Near the end, AVKit sets the rate to 0 at about
22.2 s with reason `ClientInitiated`, and segments keep downloading while the playhead
stays at 22.202. Whether that is the skip's seek, or an earlier pause, is unchecked.

## Diagnosis (PC, 2026-10-12)

Two separate things are in the log.

1. **The black screen (00:04).** A server switch at 1:21 loaded a new item and resumed it with a
   seek to 81.957 s (`Seeking to 81.957 from 0, seekID 1`). The segment pump then downloaded
   segments 70.3 s, 81.9 s, 91.1 s… but the demuxer reported `substream 0 has received 0, now at
   0.000000` throughout: nothing decoded, the item sat in `waitingToPlay
   (AVPlayerWaitingToMinimizeStallsReason)` with an empty buffer, and AVFoundation raised no
   error. Skip Intro's seek to 90 s (`seekID 2`) cancelled the stuck seek and got stuck the same
   way. The player only had a timeout for the *first* load, so nothing failed over and no failure
   screen appeared. It sat black for three minutes until the item was closed.
2. **The pause at 22.2 s (00:07:53).** The log shows a UIKit control action into AVKit
   (`AVPlayerController setPlaying: 0`, rate change reason `ClientInitiated`) and no seek
   after it. The tap landed on AVKit's own play/pause control rather than the app's Skip
   button, so playback paused. AVKit's chrome and the Skip button share the bottom of the
   video; the custom player in phase 4 removes AVKit's controls.

## Fix

- A stall watchdog: once a second, while an item is ready but waiting to play, the player checks
  that the clock moves. After 15 s it re-seeks once; after 15 s more it marks the server failed and
  moves to the next one, keeping the position.
- Every seek goes through one helper that records its target, logs where it was going and
  whether it landed or was superseded. A failover during a stuck seek resumes at the seek's target
  instead of at 0, which is what lost 1:21 here.
- `Log` now also writes to the unified log (subsystem `com.anilili.ios`), so the next capture
  has the app's own lines (server, seeks, stalls) beside AVFoundation's:
  `xcrun simctl spawn booted log show --last 30m --predicate 'subsystem == "com.anilili.ios" OR process == "Anilili"'`
