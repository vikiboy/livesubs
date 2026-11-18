# Rehearsal: LiveSubs showcase
Gold: `phone-touch` (copied into `src/livesubs/`, then rewritten). Kept: a phone pinned one gutter from the top and running off the bottom, a card-sized stage, the touch cursor, one object carried across screens, the script's beat structure. Changed: everything else. The ground is true black, the look is Burnt-in Cinema Subtitles (#000, #1C1C1E, #FFE14D Helvetica Bold with a black edge), and the content is LiveSubs' own (strings and geometry from `LiveSubs/UI/*.swift` and `SubtitleFrameRenderer.swift`). From `dynamic-island` I borrowed one idea: a moving shape with its content on a separate layer. The in-app frame hands off to the PiP shape, which flies to the corner, and no text rides the resize.

Beats: 1. LiveSubs is idle. A tap on the ▶ Start leader starts the loading sweep. 2. The iOS red recording pill comes up round the clock, and the leader lights yellow with a white Stop. 3. The app goes home while its frame flies to become the PiP over a neutral video app ("京都の朝ラーメン"). 4. The badge goes from [ listening ] to Japanese → English. Words stream in white and settle yellow, sentence 1 then sentence 2, with the settled sentence rising out. 5. The payoff holds for 1.9s. A tap on the PiP brings up its controls, and the × closes it. The pill clears and the video app goes home as LiveSubs opens idle (the visible cause of the reset). The loop runs about 16s.

Captured: wide 440×560 (viewport 1280) and compact 358×540 (viewport 390), both from dev and from the built `dist/` (vite preview). `--states` at both widths. `--reduced` poster at both widths (`poster.png` 880×1120 and `poster-compact.png` 716×1080, both 2x captures of the stage, cropped to the stage). A `file://dist/index.html` still. Zoomed 60–70ms sequences of the badge, the word stream and the sentence roll. A `jumps.mjs` 20s scan: no issues.

Film: `--gate` printed `rehearsal passed` on the wide loop, the 390 loop and `--states` at both widths. The one remaining candidate:
- `appears, then moves: .ls-progress__fill`. This is the video's progress bar advancing while it plays, so it stands as intended.

Fixed along the way:
- `uneven padding` on the in-app frame: the gate hairline is now its own layer, matching the PiP's shape and content split.
- `lopsided` segmented bars.
- A near-aligned badge vs title edge.
- A translucent icon in the loading state (now opaque gray).
- Three `lands on a transform` lines (fixed with will-change).
- `settle snap` from `Swap` on the PiP badge (replaced with a fixed-box crossfade).
- A loop seam where the cursor did not return to rest.
- `clipped` on the speaker's body: the video frame crop is deliberate, so the player is marked `data-crop`.
- Sentence 1 overlapping sentence 2 during the roll.

Review: there was no separate fresh-eye reviewer (review.md). I compared against the gold myself. The eye lands on the yellow subtitles first, and one phone leads.

Assumptions:
- The PiP is 320×134pt at the lower right, with subtitles at 17pt.
- The badge is 13.5pt, larger than the renderer's ratio, so it stays readable at 0.76 scale.
- The loading state keeps the play glyph in gray instead of SF Symbols' `film` glyph, because no kit glyph exists for it.
- The PiP close control is a gray disc with an ×, drawn after iOS's PiP controls.
- The idle frame shows the app's real placeholder copy.
- All subtitle lines, the Japanese video title and the badge text are synthetic demo content (marked in the code).

Unresolved:
- The phone's titanium edge is faint against #000 by design.
- The loop runs about 16s, at the top of the 10–16s range.
- The `uneven padding` fix is structural (the gate became a layer). A fresh eye should confirm it is not just a way of hiding the check.

Not checked:
- Real Safari or an iOS device, and touch.
- Toggling reduced motion mid-playback.
- Pause, replay and return from offscreen.
- Live rAF pacing on a real page.
- A second-reviewer fresh-eye pass.
