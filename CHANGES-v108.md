# v108 changes (from her v107 defect reports, 2026-11-17 morning)

1. **Playback switching (her #1, "很严重，必须仔细检查")** — root cause found
   by diffing the native engine against the WEB app's engine, which plays
   and switches fine on her phone: v105–v107 wrapped MusicKit in an
   adversarial control system (per-call timeouts, a 2.6 s target verifier
   that force-re-jumped and restarted slow loads, a stall watchdog) AND
   Player.swift ran a second watchdog that re-sent the whole playQueue
   if unconfirmed after 6 s. On a real network a switch legitimately
   takes longer than those windows, so the mechanisms fought MusicKit's
   own loading — switches collapsed and fake "playback failed" errors
   fired, while the first play of a session (nothing to fight) worked.
   Fix: the engine core is now the web app's proven shape — one
   serialized op chain; playQueue = setQueue → shuffle/repeat → jump
   only when startIndex > 0 → play(); no timeouts, no verification, no
   retries; errors posted only on real rejections. Player's re-issue
   watchdog deleted entirely. The queue-readback/'queue' channel is
   gone. Node harness (14 checks: slow 3 s setQueue, rejected setQueue,
   rapid double playQueue serialization, jumpTo single-shot) all pass.
   ALSO: EngineHost's WKWebView was 1×1 pt — WebKit may treat such a
   page as barely visible and throttle its timers/media pipeline; it now
   hosts full-size (still invisible, opacity 0.01, hit-testing off)
   behind all content. Login/init/authorize untouched. Per her request
   the rewritten playback code went through a two-round DISCUSSION
   with Codex (not a rubber stamp): it confirmed the root-cause
   analysis and the serialized design, and caught real issues that are
   fixed here — superseded playQueue ops now coalesce (only the
   latest request executes; a station request likewise invalidates a
   waiting queue), shuffle/repeat are captured per call and applied
   from the capture (a mid-await mode change can't leak in), jump
   failures and playQueue start/settle timings are logged to the
   Settings diagnostics instead of being swallowed, the vestigial
   expectedId jump parameter is gone, and the error-toast grace is
   3 s so optimistic UI state can be corrected by real engine events
   first. Node harness: 17 checks, all pass.
2. **Widget** — her screenshot showed the empty placeholder (gradient +
   note, no cover, NO buttons). Two fixes: (a) the buttons no longer use
   .glassEffect(.clear.interactive()) — in the widget extension those
   labels rendered as nothing; they're now plain ultraThinMaterial
   circles with a white stroke and the glyph as a sibling layer, over a
   soft bottom scrim. (b) Settings' diagnostics line now reports the
   widget data channel: whether the app group survived signing and
   whether song data is present — so a dead channel is visible instead
   of silent. Artwork still rides the container background (clear-theme
   glassification unchanged).
3. **Icon** — the glyph was redrawn as a traced copy of the official
   classic icon (reference image fetched and matched over two passes:
   slanted beam with parallel underside, two fat teardrop heads, the
   right one higher). The note layer's glass + translucency are OFF so
   it stays flat solid white like the official icon instead of washing
   pink; the red base #FA2D48 is unchanged.
4. **Radio layout** — station artwork arrives in mixed aspect ratios and
   the old ZStack let scaledToFill images push cards to their own size.
   Station cards are now uniform squares (clear base defines the size,
   image fills as a clipped overlay), with fixed-height title/subtitle
   slots so rows line up.
5. **Album page artist name** — the artist name under the album title is
   now a tappable link (accent colour + chevron) that opens the artist
   page; the id is resolved by searching the artist name (exact-name
   match preferred), the same fallback pattern used elsewhere. If it
   can't be resolved the name stays plain text.
6. **Rapid favorite taps froze then crashed the app (her report)** —
   every tap spawned its own write Task carrying a stale snapshot of
   the state; completions reverted each other and the churn (plus a
   toast per task) froze the UI until iOS killed the app. Song and
   album favorites now use a desired-state worker: a tap flips the
   heart instantly and records the latest desire; ONE worker per item
   walks Apple's ratings to that desire and reports once when settled;
   on failure it rolls back to the last Apple-confirmed state.
7. **General freezes ("老卡住卡死")** — two steady main-thread taxes
   removed. (a) MarqueeText re-ran NSString measurement on every
   render of every row, and the player publishes progress twice a
   second, re-rendering the whole tree — measurements are now cached
   per (text, slot width). (b) hydrateFav fired up to two ratings
   requests per song row appearance and retried inconclusive answers
   on EVERY appearance, so scrolling meant a request storm; it now
   dedupes in-flight keys and backs off unknown answers for 2 minutes.

Untouched, as always: engine init/authorize, EngineBridge page loading,
the login path.
