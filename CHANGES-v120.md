# CHANGES v120 (2026-11-18)

Authorized by her list of 2026-11-18 17:50-17:56 + the GPT v120
verdict (full evidence brief, Think on; she ordered: implement
strictly per GPT). Engine 109.19 shipped separately online
(commits 7a51342 + 5323fa5) before this build.

## Engine 109.19 (already live via online update)
GPT's diagnosis: the 30s previews are full-track webPlayback /
FairPlay license requests dying inside throttled windows; the
109.13-109.18 heal AMPLIFIED the failure (attempt counted and a
rebuild enqueued while a previous rebuild could still be queued
- healInFlight was only set once the op started). Implemented
exactly per spec:
- Preview heal rewritten: same-item + catalog >90s + asset
  stably 10-45s and <60% of catalog for 2.5s of ticks; page
  visible >=3s; no setQueue/completion/recovery in flight;
  healScheduled set BEFORE enqueueing (single-flight); ONE
  rebuild per song per foreground epoch; failure posts
  previewExhausted once per epoch and stands down until the
  next foreground window. Credible-heal rule kept (109.17).
- Queue completion DEFERRED: startRotated no longer completes
  immediately; a gate on the 500ms tick releases playLater only
  once the head item is confirmed (right item, clock advancing,
  asset not a preview - or the single heal has run its course,
  so a stuck preview never strands the queue at one song).
- playVerifyTick: ONE nudge per item max (was 3); never nudges
  a confirmed preview; yields to a scheduled/in-flight heal.
- MEDIA_KEY: log only, never triggers a rebuild.
- JS forceReload() entry REMOVED (second recovery owner).
- Kept untouched per GPT: setQueueDroppingBad / setQueueTarget /
  startRotated core, HEAD_WINDOW=1, mutate() serial mutex (the
  setQueue path never used bounded(), so the mutex is never
  released early), COMPLETION_GAP_MS=500, hidden-pause of
  completion, authSnapshot / recoverAuth / healthCheck,
  initMK retry, lastTargetResource.
- Harness: now pumps intervals + a simulated playback clock;
  full suite ALL PASS with the gate active.

## Swift (this build)
1. Motion artwork: the whole LOCK-SCREEN pipeline deleted at
   her decision - Player's attachAnimatedArtwork /
   prepareMotionFile / fetchMotionFile / fetchHLSByConcat,
   the MPMediaItemAnimatedArtwork publishing in
   updateNowPlayingInfo, animatedArtworkBox, and APIClient's
   motionURLs/pickMotionURLs. Static covers stay. The IN-APP
   motion headers (Now Playing / Collection / Artist, via
   motionURL singular) are a different feature and stay.
2. handlePreviewExhausted: no longer resolves a storefront
   twin and replays the queue (GPT: that made Swift a second
   recovery owner). It logs; the badge stays; the engine may
   earn a fresh single attempt next foreground window. The
   "region_switched" toast path and the previewStorefrontTried
   / pendingRegionToast state are gone with it.
3. EngineBridge.forceReloadQueue() deleted (no callers; its
   JS entry is gone too).
4. Shazam removed wholesale at her decision: Shazam.swift
   deleted, the rail button + listening pill + notification
   routing in RootView, NotificationPresenter and the
   aoiShazamSongTap name in the app file, the Shazam widget
   (player widget + App Group KEPT), the microphone usage
   string, the aoimusic:// URL scheme, and the shazam_* strings.
   Player's generic interruption-resume code stays.
5. Lifecycle: back to SwiftUI App + WindowGroup. v119's UIKit
   scene lifecycle fixed the keyboard but regressed the root
   layout (blank bands at both edges - her 17:49 screenshot).
   The keyboard exclusion survives via KeyboardRegionController:
   a runtime probe sets safeAreaRegions on SwiftUI's own
   hosting controller IF the runtime exposes it, reads the
   value back via KVC, and logs honestly either way; the launch
   geometry (host frame + safe insets) is logged once. Info.plist
   scene manifest reverted to match (no SceneDelegate class).

## Verification done locally
- Engine: full-script node syntax check (all 4 blocks) +
  harness ALL PASS.
- Swift: dangling-reference sweep clean (only explanatory
  comments mention removed names); brace/paren balance clean
  on every edited file; Info.plist parses. No local Swift
  compiler exists - Codemagic is the compile check, as always.

## Device test list
1. Kill/reopen first (engine 109.19 lands), then install v120.
2. 30s previews: play the usual suspects; Settings log should
   show at most ONE "single queue rebuild" per song per
   foreground window, "queue completion deferred" then
   "head song confirmed ... releasing", and NO repeated
   rebuilds. If a preview survives a window, it should heal on
   the next foreground return, not by hammering.
3. Blank bands: gone on every page; log line "root geometry:"
   present.
4. Search: field stays put with the keyboard up; log line
   "root keyboard safe area OFF (search page, regions=1)" -
   if instead the log says safeAreaRegions is NOT exposed,
   tell me: the keyboard fix is inactive on this path and we
   take the other route.
5. Shazam button/widget gone; player widget still works;
   lock screen shows the static cover.
