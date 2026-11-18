---
name: LiveSubs
description: On-device English subtitles that float over any video app, set like a burnt-in cinema release print.
colors:
  subtitle-yellow: "#FFE14D"
  house-black: "#000000"
  projector-gate: "#333333"
  leader-stock: "#171717"
  leader-line: "#FFFFFF24"
  leader-ring-idle: "#474747"
  inset-row: "#1C1C1C"
  instruction-grey: "#B8B8B8"
  footnote-grey: "#8C8C8C"
  provisional-white: "#FFFFFFDB"
  stop-red: "#FF5C52"
typography:
  subtitle-frame:
    fontFamily: "Helvetica Neue Bold (HelveticaNeue-Bold), fallback system bold"
    fontSize: "76px (buffer), scaled 0.7x to 1.4x by the Text size setting"
    fontWeight: 700
    lineHeight: 1.08
  frame-reel-label:
    fontFamily: "Helvetica Neue Bold"
    fontSize: "42px (buffer)"
    fontWeight: 700
  leader-numeral:
    fontFamily: "Helvetica Neue Bold"
    fontSize: "56pt, relative to largeTitle"
    fontWeight: 700
    fontFeature: "tnum"
  leader-title:
    fontFamily: "Helvetica Neue Bold"
    fontSize: "21pt, relative to title3"
    fontWeight: 700
  step-numeral:
    fontFamily: "Helvetica Neue Bold"
    fontSize: "15pt, relative to subheadline"
    fontWeight: 700
  body:
    fontFamily: "SF Pro (system), Dynamic Type subheadline"
    fontSize: "15pt at default size"
    fontWeight: 400
  footnote:
    fontFamily: "SF Pro (system), Dynamic Type footnote"
    fontSize: "13pt at default size"
    fontWeight: 400
rounded:
  none: "0"
  leader: "50%"
spacing:
  leader-stack: "18pt"
  status-stack: "8pt"
  reel-line-inset: "20pt"
  status-inset: "12pt"
  step-gap: "12pt"
  frame-side: "60px"
  frame-foot: "48px"
components:
  subtitle-frame:
    backgroundColor: "{colors.house-black}"
    textColor: "{colors.subtitle-yellow}"
    typography: "{typography.subtitle-frame}"
    rounded: "{rounded.none}"
    size: "1434x600px buffer, 2.39:1"
  leader-control:
    backgroundColor: "{colors.leader-stock}"
    textColor: "{colors.subtitle-yellow}"
    typography: "{typography.leader-title}"
    rounded: "{rounded.leader}"
    size: "184pt"
  leader-control-running:
    backgroundColor: "{colors.leader-stock}"
    textColor: "#FFFFFF"
    rounded: "{rounded.leader}"
  inset-list-row:
    backgroundColor: "{colors.inset-row}"
    textColor: "#FFFFFF"
---

# Design System: LiveSubs

## Overview

**Creative North Star: "Burnt-in Cinema Subtitles"**

The app is a darkened auditorium and its screen is the subtitle itself. Lineage is the 35mm release print with laser-etched subtitles: a CinemaScope (2.39:1) frame, yellow Helvetica Bold lettering with a black edge, set in two fixed line slots at the foot of the frame. Everything around that frame is house dark, and the single control is drawn as an Academy countdown leader, the circle and crosshair at the head of every reel.

The world is deliberately narrow. One bright color, one display face, one custom control; everything else is stock iOS (inset grouped lists, segmented picker, navigation links, sheets) recoloured by the forced dark appearance and the yellow tint. The density is low: the frame, a reel line, the leader, one caption of status, then the options list. The floating Picture-in-Picture window is the real product surface and renders the same frame the app previews, pixel for pixel.

**Key Characteristics:**
- Forced dark appearance; true black house (#000000) behind everything.
- Subtitle yellow is the only bright, saturated color, and the global tint.
- Helvetica Neue Bold is the world's face, used only for subtitle-register lettering.
- A full-bleed 2.39:1 frame with a 1pt projector-gate hairline.
- One circular leader control (184pt) whose states are a film leader's states.
- Stock iOS lists below the frame; no custom chrome around them.

## Colors

A black auditorium with one laser-etched yellow; every other value is a neutral grey stepping up from the house.

### Primary
- **Release-Print Yellow** (subtitle-yellow): finished subtitle lines in the frame, the lit leader ring while running, the leader's idle lettering, the How-it-works numerals, the app tint (toolbar icons, list icons, selection), and, at 50% alpha, the frame's reel label. At 18% to 22% alpha it is the leader's sweep fill during download and loading.

### Neutral
- **House Black** (house-black): app background, list background, frame background, frame row background. Forced; there is no light mode.
- **Projector Gate** (projector-gate): the 1pt hairline around the preview frame.
- **Leader Stock** (leader-stock): the leader control's face.
- **Leader Line** (leader-line): the leader's crosshair and inner ring, 1pt, white at 14%.
- **Idle Ring** (leader-ring-idle): the leader's 2pt outer ring when not running.
- **Inset Row** (inset-row): backgrounds of the options and How-it-works list rows.
- **Instruction Grey** (instruction-grey): reel line under the frame and the status caption under the leader.
- **Footnote Grey** (footnote-grey): hints, PiP errors, the privacy footer.
- **Provisional White** (provisional-white): words still being heard, in the frame's lower slot, before they commit to yellow.

### Semantic
- **Stop Red** (stop-red): failure status label only (with the triangle symbol).

### Named Rules
**The One Bright Thing Rule.** Subtitle yellow is the only saturated color on screen. Neutrals carry everything else; a second accent breaks the house lights.

**The Commit-to-Yellow Rule.** In the frame, white means still being heard and yellow means finished. Never render provisional words in yellow or finished words in white.

## Typography

**Display Font:** Helvetica Neue Bold (HelveticaNeue-Bold, fallback system bold)
**Body Font:** SF Pro via Dynamic Type text styles
**Label Font:** SF Pro footnote

**Character:** Helvetica Bold is the genuine face of release-print subtitling and is reserved for the subtitle register; SF carries every instruction and setting so the lettering in the frame stays special.

### Hierarchy
- **Subtitle line** (700, 76px in the 1434x600 buffer, line height 1.08, centred): frame text. Scales 0.7x to 1.4x with the Text size setting.
- **Reel label** (700, 42px buffer, yellow at 50%, top-left at 56,36): detected language, e.g. "Spanish → English".
- **Leader numeral** (700, 56pt relative to largeTitle, monospaced digits, numeric content transition): download percentage on the leader face.
- **Leader title** (700, 21pt relative to title3): "Start", "Get model", "Loading", "Stop".
- **Step numeral** (700, 15pt relative to subheadline, yellow, 16pt column): How-it-works list numbers.
- **Body** (SF subheadline): status caption and list step text, centred under the leader.
- **Footnote** (SF footnote): reel line, hints, footers.
- Navigation large title and list rows use stock SF styles.

### Named Rules
**The Subtitle Register Rule.** Helvetica Neue Bold appears only where the text is speaking in the subtitle's voice: the frame, the leader lettering, and leader-like numerals. Instructions, settings and footers stay in SF.

**The Fixed Object Rule.** The leader and the reel line cap Dynamic Type at accessibility1; the leader is a fixed 184pt object and its lettering stops growing before it overflows. All other text follows Dynamic Type fully.

## Layout

A single scrolling inset-grouped list under a large "LiveSubs" title, in a fixed order: frame, leader, options, How it works. The frame section has zero horizontal section margins and zero row insets, so the 2.39:1 frame runs edge to edge; its footer (the reel line) is inset 20pt. The leader section is a centred vertical stack (18pt between leader and status, 8pt inside the status stack, 12pt horizontal inset, 8pt vertical padding) on a clear row. Options and the guide are stock inset rows. Settings is a sheet with a stock Form.

The frame buffer is 1434x600px: 60px side margins (1314px slot width), text stacks upward from 48px above the bottom edge, the reel label sits at 56,36.

## Elevation & Depth

Flat. There are no shadows and no material blur in the system's own surfaces; depth is the house dark versus lit lettering. The only layering is the stock iOS inset list and sheet. The frame's black edge on glyphs (a 16-weight black stroke drawn under the fill) is legibility, not elevation.

### Named Rules
**The House Lights Rule.** Nothing glows or floats inside the app except the subtitle. Hierarchy comes from brightness against black, never from shadow.

## Shapes

Two shapes carry the world: the hard-cornered 2.39:1 rectangle (frame, gate hairline, app icon) and the circle (leader). Neither is rounded off toward the other: the frame has square corners, the leader is a perfect circle with a 1pt crosshair and an inner ring inset 30pt. Stock iOS rows keep their system radius.

## Components

### Subtitle Frame (signature)
The product surface: the same renderer feeds the in-app preview and the PiP window.
- **Shape:** 2.39:1, square corners, 1pt projector-gate hairline in-app.
- **Content:** two fixed line slots at the foot. While someone speaks, the top slot holds the last finished line in yellow and the bottom slot the provisional words in white; with nothing provisional, the yellow line may use both slots.
- **Overflow:** slots never reflow. When a line outgrows its slots, the oldest words leave from the front.
- **Edge:** black outline (stroke width 16) drawn under the fill so it never thins the glyphs.
- **Reel label:** optional detected-language badge, top-left, yellow at 50%.

### Leader Control (signature)
The one control, 184pt circle on leader stock with crosshair and inner ring.
- **Start:** idle 2pt grey ring, yellow play symbol (38pt bold) over yellow "Start".
- **Get model:** same, with the down-arrow symbol.
- **Downloading:** a clockwise wedge from 12 o'clock fills in yellow at 22%; the face shows the percentage numeral in white at 90%. Disabled.
- **Loading:** the wedge turns continuously (1.4s cycle) in yellow at 20%; with Reduce Motion it holds at half. No numeral: loading has no known length, so never fake a count. Disabled.
- **Running:** ring lights yellow at 4pt; a second yellow ring at 35% breathes outward (scale 1.04 to 1.16) with the audio level; white stop symbol and "Stop". The breathing ring is skipped under Reduce Motion.
- **Paused:** white pause symbol and "Stop".
- **Press:** scales to 0.96 and brightens 6%, spring 0.2s. State changes spring 0.35s; medium impact haptic on returning to Start.

### Lists / Rows
- **Style:** stock inset grouped rows on inset-row grey over house black; SF symbols tinted yellow.
- **Source picker:** stock segmented control.
- **Footers:** footnote grey, with an SF symbol label (e.g. the lock on "Runs on this iPhone").
- Options are disabled while a session is active.

### Navigation
- Large title "LiveSubs"; a single trailing toolbar button (slider symbol) opens Settings as a sheet with an inline title and a Done confirmation action.

## Do's and Don'ts

### Do:
- **Do** keep subtitle yellow the only saturated color; it is the tint and the lit state.
- **Do** render frame text in Helvetica Neue Bold with the under-drawn black edge, centred in two fixed slots.
- **Do** keep the frame 2.39:1, full-bleed, square-cornered, with the 1pt gate hairline.
- **Do** express progress on the leader as a clockwise sweep from 12 o'clock, and show a number only when the length is known.
- **Do** honour Reduce Motion by holding sweeps static and dropping the breathing ring.
- **Do** leave settings, lists and pickers as stock iOS under the forced dark appearance.

### Don't:
- **Don't** add a light appearance or a non-black background behind the frame.
- **Don't** use Helvetica Neue Bold for instructions, settings or footers.
- **Don't** let the frame reflow or scroll; drop the oldest words instead.
- **Don't** add shadows, glows or blur to make anything feel elevated.
- **Don't** introduce a second control competing with the leader on the main screen.
