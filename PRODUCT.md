# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

Native Swift / SwiftUI (iOS 26+, iOS 27 SDK), XcodeGen project, WhisperKit via SPM. Stated in the owner's brief.

## Users

One person: the owner, using their own iPhone. They watch foreign-language videos in YouTube, Safari, TikTok and other players and want to understand them in English without leaving that app. The scene: phone in hand (often one-handed, often at night), video playing full-screen or in portrait, attention on the video, not on this app.

## Product Purpose

Turn spoken audio from whatever is playing on the iPhone into near-real-time English subtitles, entirely on-device. Success: one tap to start, switch to the video app, readable English captions appear and keep up; one tap (or closing the floating window) to stop.

## Positioning

Fully offline and private: no accounts, no API keys, no cloud inference, no Alibaba/Qwen or Chinese-hosted services. It works across other apps (ReplayKit broadcast extension on iOS 26, ScreenCaptureKit on iOS 27) instead of being its own video player, and detects the spoken language automatically (Whisper).

## Operating Context

- The app is mostly a launcher and a settings place; the product lives in the floating Picture-in-Picture subtitle window over other apps.
- iOS forbids drawing over other apps; PiP is the only sanctioned floating surface. iOS shows its own screen-recording consent and indicator.
- Internet is needed only once, to download a speech model (75 MB to 947 MB) and optional Apple language packs.

## Capabilities and Constraints

- Engines: Whisper (auto-detects about 100 languages, translates on-device) or Apple SpeechAnalyzer + Translation (faster, user picks the language).
- Sources: audio of videos on this iPhone, or the microphone.
- Start/stop from the app, Siri/Shortcuts/Action button, closing the PiP window, or the system recording indicator.
- DRM-protected audio may be excluded by iOS; the app must not attempt to bypass it.
- Personal use only: no monetization, analytics, ads or backend.

## Brand Commitments

Name: LiveSubs. No other brand assets exist yet.

## Evidence on Hand

No testimonials, metrics, or benchmarks. Device performance numbers have not been measured on an iPhone yet and must not be claimed.

## Product Principles

1. The subtitles are the product; the app gets out of the way.
2. One obvious control: on or off.
3. Say plainly what iOS allows and what it doesn't.
4. Private by construction; the UI never implies a network round-trip.
