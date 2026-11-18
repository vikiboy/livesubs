# CLAUDE.md

Guidance for Claude Code (and people) setting up or working on LiveSubs: an iPhone app that
makes English subtitles for foreign-language video entirely on the device. The README covers what
it does and why each engine was chosen; this file covers how to build, change and check it.

## Principles (don't break these)

- **On-device only.** No cloud inference, paid APIs, analytics, crash reporting or backend.
  The only network use is model and language-pack downloads, and pages the user opens in the
  private browser. Don't add SDKs that phone home.
- **Stateless private browser.** WKWebView with a non-persistent data store. Subtitles live
  in memory. Nothing about what's watched is written to disk, logged or donated to
  Siri/Spotlight. Debug prints stay behind `LIVESUBS_DEBUG` and never include URLs or titles
  in release paths.
- **Licences.** New dependencies, models or data need an entry in `THIRD_PARTY_NOTICES.md`.
  Prefer MIT/Apache/BSD code. Model weights are downloaded at runtime, never committed.
- **Measure before switching engines.** Engine choices in the README come from benchmarks
  (`Tests/Harness`). Re-run them rather than going by reputation.

## Set up

1. Xcode 27.2+ (iOS 27 SDK; the app deploys to iOS 26+), `brew install xcodegen`.
2. Create `Config/Signing.local.xcconfig` (git-ignored; never commit it):
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   BUNDLE_ID_PREFIX = com.yourname
   APP_GROUP_ID = group.$(BUNDLE_ID_PREFIX).livesubs
   ```
3. `xcodegen generate`. `LiveSubs.xcodeproj` is generated and git-ignored. Edit
   `project.yml`, never the project file, and regenerate after adding or removing files.
4. MLX needs Xcode's Metal toolchain. If the build says it's missing:
   `xcodebuild -downloadComponent MetalToolchain`.

## Build and run

```sh
# Simulator build (fast compile check; most engine features need a real iPhone)
xcodebuild -project LiveSubs.xcodeproj -scheme LiveSubs -destination 'generic/platform=iOS Simulator' build

# Device build; LIVESUBS_STAMP is optional and shows as "built …" at the foot of Settings
xcodebuild -project LiveSubs.xcodeproj -scheme LiveSubs -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates LIVESUBS_STAMP="$(date '+%b %d, %H:%M')" build
```

Install with `xcrun devicectl device install app --device <id> <path>.app`.

On a new device, launch once by hand. iOS blocks free-team apps until the user trusts the
developer (Settings ▸ General ▸ VPN & Device Management). Never retry `devicectl … launch` in
a loop: each attempt raises the "Untrusted Developer" alert again and can lock the phone up.

What needs a real iPhone: Picture in Picture, screen-audio capture (ReplayKit/ScreenCaptureKit),
Apple's speech recogniser (the Simulator can't install its model), and TranslateGemma (Metal GPU).

## Layout

```
project.yml                 XcodeGen spec: targets, packages, entitlements, Info.plist keys
Config/                     signing defaults (+ your git-ignored Signing.local.xcconfig)
Shared/                     ring buffer, notifications, audio converter (app + broadcast extension)
BroadcastExtension/         ReplayKit capture for iOS 26
LiveSubsControls/           Control Center control and Live Activity widget
LiveSubs/App                session orchestration (LiveSession), settings (AppSettings)
LiveSubs/Audio              screen capture, broadcast reader, microphone
LiveSubs/Engine             Live-mode pipelines (Whisper, Apple), recognisers, TranslateGemma, filters
LiveSubs/Browser            private browser: page hooks, audio decoding, ahead-of-time engine, ad blocking
LiveSubs/Subtitles          PiP controller and subtitle frame renderer
LiveSubs/UI                 SwiftUI screens and settings
LiveSubs/Models             Whisper model store, download and warm-up
LiveSubs/Resources/AdBlock  generated content-blocker rules (see Tools/make-blocklist.py)
Tests/Harness               Mac harness running the app's real sources (symlinked)
Showcase/                   Stageshow demo that produces docs/demo.gif
```

## How the pieces fit

**Live mode** (any app). Screen audio arrives at 16 kHz mono, then goes through:
- **Recogniser:** Apple's `SpeechTranscriber` when one language is known, otherwise Whisper
  via WhisperKit.
- **Translation:** Apple Translation.
- **Display:** subtitles are drawn into video frames and shown in Picture in Picture (iOS
  doesn't allow overlays on other apps).

**Private browser** (`LiveSubs/Browser`):
- `BrowserScripts.swift` is injected at document start in every frame.
  - It hooks `SourceBuffer.appendBuffer`, patched on the real prototype: `ManagedSourceBuffer`
    on iPhone.
  - It denies `audio/webm`, so sites serve AAC.
  - It notes `.m3u8` playlists and handles fullscreen and controls.
- `FMP4AudioDecoder` and `HLSAudioReader` decode audio in memory.
- `AheadSubtitles.swift` (`AheadTranscriber` actor) subtitles the whole video ahead of the
  playhead.
  - Windows are cut at pauses.
  - Recognisers come in order with a fallback: Apple, then Whisper Small.
  - Apple Translation gives a first line immediately. TranslateGemma (`GemmaTranslator`)
    then re-translates lines into natural English, starting with those nearest the playhead.
  - Audio downloads are paced: about 2 minutes are kept waiting ahead of transcription, which
    is the bottleneck.

## Gotchas

- **Apple's recogniser:**
  - It needs `AssetInventory.reserve(locale:)` before `assetInstallationRequest`.
  - `LanguageAvailability` can report false negatives. `ApplePipeline` probes with a real
    translation and retries.
- **iOS forbids GPU work in the background.** TranslateGemma pauses while the app isn't active
  (`GemmaTranslator.allowed`) and isn't used in Live mode. The increased-memory-limit
  entitlement is needed for it.
- **Core ML recompiles models for the Neural Engine after every install or update.**
  `ModelWarmup` does this up front so the first subtitles aren't delayed.
- **Page scripts must stay self-contained.** One closure, nothing global, every hook in
  try/catch. A thrown error or a name clash breaks the site's player.
- **One bad cosmetic selector rejects its whole WebKit rule list.** That's why cosmetic rules
  are compiled in batches of 20.
- **One file is excluded from the app on purpose.** `ParakeetRecognizer.swift` (FluidAudio) is
  harness-only; see `excludes` in `project.yml`. `SubtitlePolisher.swift` (Apple Intelligence
  rewrite) still compiles but is unused, because it reversed a meaning in testing.
  Shared engine code receives TranslateGemma as an injected `Refiner` closure so the harness
  builds without MLX.

## Checking changes

On a Mac, from `Tests/Harness/` (needs network once for models; scratch files go to `$TMPDIR/livesubs-harness`):

```sh
./run.sh                    # Spanish + German end-to-end through the Live-mode Whisper pipeline
./bench.sh [filter]         # Japanese + Korean speed and English lines per engine setup
swift build -c release --product Bench
.build/release/Bench ahead:apple:ja <16kHz-mono.wav> ja   # private-browser engine on a file
```

`ahead:<engine>:<lang>` engines are `apple`, `parakeet` and `whisper-turbo`. For accuracy, compare
the printed lines with reference transcripts. Set `LIVESUBS_DEBUG=1` for engine traces and
`LIVESUBS_GEMMA_DIR=<folder>` to point at downloaded TranslateGemma weights.

Before calling something done: build the app, run the relevant harness mode, and for anything
touching capture, PiP, the browser or TranslateGemma, try it on a device. The Simulator can't
show those.

## Ad-block lists

Regenerate with `python3 Tools/make-blocklist.py hosts easylist.txt easyprivacy.txt`, after
downloading the three sources yourself (URLs in the script). Each output list must stay under
WebKit's 150,000-rule limit.

## Demo animation

`cd Showcase && npm install && npm run dev`. The scene lives in `src/livesubs/index.tsx`. Its
lines are made up for the demo. To refresh the README GIF, film the built page and re-encode it
to `docs/demo.gif` (about 360 px wide, looping).
