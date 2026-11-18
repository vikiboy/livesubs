import type { CSSProperties } from 'react'
import { Stage, Phone, Bar, Icon, States, type Act } from '../kit'
import './livesubs.css'

// LiveSubs, a personal and fully offline iPhone app: one round control starts
// it, iOS shares screen audio, and English subtitles float in a
// Picture-in-Picture window over whatever video app is playing.
//
// Started from the phone-touch gold: a phone pinned a gutter from the top and
// running off the bottom, one object carried across screens, a touch cursor.
//
// Beats (about 16s):
//   1  LiveSubs: the frame at the top, the countdown leader. A tap on Start;
//      the leader's sweep turns while the model loads.
//   2  iOS's red recording pill comes up round the clock (screen audio shared),
//      the leader lights: Stop.
//   3  The app goes home; its frame keeps going and becomes the floating PiP
//      window over a neutral video app playing a Japanese clip.
//   4  Words arrive white as they are heard and turn yellow once settled; the
//      first sentence rises out as the second is heard. (Payoff, poster.)
//   5  A tap on the PiP shows its controls, the × closes it, the recording
//      pill goes, and the loop returns to LiveSubs, idle. The × is the cause.
//
// Every point is in iPhone screen points (402 × 874); the Phone scales them.
//
// SYNTHETIC DEMO CONTENT: every subtitle line, the Japanese video title and the
// badge text below are illustrative strings written for this showcase. They
// are not output captured from the app or from any real video.
const S1 = 'This little shop opens at six every morning.'.split(' ')
const S2 = "It's said the soup is simmered for 12 hours.".split(' ')
// The provisional part of each sentence: these words settle (turn yellow)
// first, while the rest of the sentence is still being heard
const S1_FIRST = 5 // "This little shop opens at"
const S2_FIRST = 5 // "It's said the soup is"
// The app's own idle frame copy (SubtitlePiPController's placeholder)
const PLACEHOLDER = 'Subtitles appear here in English, as people speak.'

type Leader = 'start' | 'loading' | 'running'
type Pip = 'off' | 'docked' | 'float' | 'closing'
type S = {
  scene: 'app' | 'video'
  leader: Leader
  rec: boolean
  appCopy: boolean
  appBadge: boolean
  pip: Pip
  pipBadge: 'listening' | 'source'
  pipText: boolean
  s1: number
  s1done: number
  s2: number
  s2done: number
  rolled: boolean
  controls: boolean
  progress: number
}

const START: S = {
  scene: 'app',
  leader: 'start',
  rec: false,
  appCopy: true,
  appBadge: false,
  pip: 'off',
  pipBadge: 'listening',
  pipText: false,
  s1: 0,
  s1done: 0,
  s2: 0,
  s2done: 0,
  rolled: false,
  controls: false,
  progress: 0.18,
}

// The first sentence settled in yellow over the clip: the frame that tells the
// whole story on its own (the hold after it lands, never mid-change)
const POSTER: S = {
  ...START,
  scene: 'video',
  leader: 'running',
  rec: true,
  appCopy: false,
  pip: 'float',
  pipBadge: 'source',
  pipText: true,
  s1: S1.length,
  s1done: S1.length,
  progress: 0.34,
}

// The frame in the app (full bleed, 2.39:1) and floating as PiP (same aspect)
const APP_FRAME = { x: 0, y: 124, w: 402, h: 168 }
const PIP = { x: 66, y: 430, w: 320, h: 134 }

const WORD_GAP = 185
// Where the finger rests between taps: off the screen's content
const REST = { wide: { x: 410, y: 540 }, compact: { x: 340, y: 520 } }

const script = async (a: Act<S>) => {
  await a.wait(700)
  a.mark('tap')
  await a.click('leader')
  a.put({ leader: 'loading' })
  await a.wait(1150)
  // iOS shares screen audio: its own red recording pill round the clock
  a.mark('consent')
  a.put({ rec: true })
  await a.wait(500)
  a.put({ leader: 'running', appBadge: true })
  await a.wait(950)
  // Leaving the app: the frame's copy clears, then the frame itself floats
  a.put({ appCopy: false, appBadge: false })
  await a.wait(260)
  await a.snap({ pip: 'docked' })
  a.mark('float')
  a.put({ pip: 'float', scene: 'video', progress: 0.62 })
  await a.wait(800)
  a.put({ pipText: true })
  await a.wait(500)
  a.mark('speech')
  a.put({ pipBadge: 'source' })
  for (let i = 1; i <= S1_FIRST; i++) {
    a.put({ s1: i })
    await a.wait(WORD_GAP)
  }
  await a.wait(260)
  a.put({ s1done: S1_FIRST })
  for (let i = S1_FIRST + 1; i <= S1.length; i++) {
    a.put({ s1: i })
    await a.wait(WORD_GAP)
  }
  await a.wait(240)
  a.put({ s1done: S1.length })
  a.mark('s1')
  await a.wait(1300)
  // The next sentence is heard: the settled one rises out of the two lines
  a.put({ rolled: true })
  await a.wait(200)
  for (let i = 1; i <= S2_FIRST; i++) {
    a.put({ s2: i })
    await a.wait(WORD_GAP)
  }
  await a.wait(220)
  a.put({ s2done: S2_FIRST })
  for (let i = S2_FIRST + 1; i <= S2.length; i++) {
    a.put({ s2: i })
    await a.wait(WORD_GAP)
  }
  await a.wait(220)
  a.put({ s2done: S2.length })
  a.mark('payoff')
  await a.wait(1900)
  // The reset's visible cause: the PiP's own close control
  a.mark('controls')
  await a.click('pip')
  a.put({ controls: true })
  await a.wait(550)
  a.mark('close')
  await a.click('close')
  a.put({ pip: 'closing', rec: false })
  await a.wait(500)
  // Hidden now: the app is away, the PiP gone. Reset unseen, then go back to
  // LiveSubs the way iOS does (the video app goes home, LiveSubs opens)
  await a.snap({ ...START, scene: 'video', progress: 0.62 })
  a.mark('return')
  a.put({ scene: 'app' })
  await a.wait(600)
  await a.snap({ progress: START.progress, pipBadge: 'listening', pipText: false, s1: 0, s1done: 0, s2: 0, s2done: 0, rolled: false, controls: false })
  await a.move(a.layout === 'compact' ? REST.compact : REST.wide)
  await a.wait(200)
}

function Play({ size }: { size: number }) {
  // Shifted toward its point by a sixth of its width, as a play glyph is centered by eye
  return (
    <span style={{ display: 'block', transform: `translateX(${size / 12}px)` }}>
      <Icon name="play" filled size={size} />
    </span>
  )
}

function StopGlyph({ size }: { size: number }) {
  return (
    <svg viewBox="0 0 16 16" width={size} height={size} aria-hidden style={{ display: 'block' }}>
      <rect x="2.5" y="2.5" width="11" height="11" rx="2" fill="currentColor" />
    </svg>
  )
}

/** The Academy countdown leader: LiveSubs' one control, 184pt */
function LeaderControl({ mode }: { mode: Leader }) {
  return (
    <span className="ls-leader" data-target="leader" data-mode={mode}>
      <svg className="ls-leader__face" viewBox="0 0 184 184" width="184" height="184" aria-hidden>
        <circle cx="92" cy="92" r="92" className="ls-leader__disc" />
        <line x1="92.5" y1="0" x2="92.5" y2="184" className="ls-leader__line" />
        <line x1="0" y1="92.5" x2="184" y2="92.5" className="ls-leader__line" />
        <circle cx="92" cy="92" r="61.5" className="ls-leader__inner" />
      </svg>
      {/* The sweep turns from the start, so it is already moving as it fades in */}
      <span className="ls-leader__sweep" />
      <span className="ls-leader__breath" />
      <span className="ls-leader__ring" />
      <span className="ls-leader__label">
        <States
          value={mode}
          states={{
            start: (
              <span className="ls-leader__stack">
                <Play size={34} />
                <span>Start</span>
              </span>
            ),
            loading: (
              <span className="ls-leader__stack">
                <Play size={34} />
                <span>Loading</span>
              </span>
            ),
            running: (
              <span className="ls-leader__stack">
                <StopGlyph size={34} />
                <span>Stop</span>
              </span>
            ),
          }}
        />
      </span>
    </span>
  )
}

function Words({ words, count, done }: { words: string[]; count: number; done: number }) {
  return (
    <>
      {words.map((w, i) => (
        <span key={i}>
          <span className="ls-w" data-on={i < count || undefined} data-done={i < done || undefined}>
            {w}
          </span>
          {i < words.length - 1 ? ' ' : ''}
        </span>
      ))}
    </>
  )
}

const rectStyle = (r: { x: number; y: number; w: number; h: number }): CSSProperties => ({ left: r.x, top: r.y, width: r.w, height: r.h })

export default function LiveSubsShowcase() {
  return (
    <Stage<S>
      width={440}
      height={560}
      compact={{ below: 440, width: 358, height: 540 }}
      initial={START}
      poster={POSTER}
      script={script}
      theme="dark"
      cursor={{ at: REST, style: 'touch' }}
      className="ls"
    >
      {(s, _rect, layout) => {
        const compact = layout === 'compact'
        const shape = s.pip === 'docked' ? APP_FRAME : PIP
        return (
          <Phone width={compact ? 326 : 360} dark wallpaper="#000" className="ls-phone">
            {/* iOS's screen-recording indicator: a red pill behind the clock */}
            <span className="ls-rec" data-on={s.rec || undefined} />

            {/* ---- LiveSubs ---- */}
            <div className="ls-screen ls-app" data-away={s.scene !== 'app' || undefined}>
              <div className="ls-title">LiveSubs</div>
              <div className="ls-frame" style={rectStyle(APP_FRAME)}>
                <span className="ls-frame__gate" />
                <span className="ls-badge ls-badge--app" data-on={s.appBadge || undefined}>
                  [ listening ]
                </span>
                <span className="ls-sub ls-sub--app" data-on={s.appCopy || undefined}>
                  <span className="ls-line" data-done>
                    {PLACEHOLDER}
                  </span>
                </span>
              </div>
              <div className="ls-control">
                <LeaderControl mode={s.leader} />
                <States
                  className="ls-status"
                  value={s.leader}
                  states={{
                    start: <span>Tap Start, then play a video in any app.</span>,
                    loading: <span>Choose “Entire Screen” to share audio…</span>,
                    running: <span>Swipe up to go home; the frame will float.</span>,
                  }}
                />
              </div>
              <div className="ls-list">
                <div className="ls-seg">
                  <span className="ls-seg__on">
                    <Bar w={84} h={7} r={4} tone={4} />
                  </span>
                  <span className="ls-seg__off">
                    <Bar w={84} h={7} r={4} tone={2} />
                  </span>
                </div>
                <div className="ls-row">
                  <Bar w={74} h={8} r={4} tone={3} />
                  <Bar w={60} h={8} r={4} tone={2} />
                </div>
                <div className="ls-row">
                  <Bar w={104} h={8} r={4} tone={3} />
                  <Bar w={38} h={8} r={4} tone={2} />
                </div>
              </div>
            </div>

            {/* ---- A neutral, unbranded video app ---- */}
            <div className="ls-screen ls-video" data-away={s.scene !== 'video' || undefined}>
              <div className="ls-player" data-crop>
                <span className="ls-scene__sky" />
                <span className="ls-scene__sun" />
                <span className="ls-scene__b ls-scene__b1" />
                <span className="ls-scene__b ls-scene__b2" />
                <span className="ls-scene__b ls-scene__b3" />
                <span className="ls-scene__b ls-scene__b4" />
                <span className="ls-scene__street" />
                <span className="ls-scene__head" />
                <span className="ls-scene__body" />
                <span className="ls-progress">
                  <span className="ls-progress__fill" style={{ transform: `scaleX(${s.progress})` }} />
                </span>
              </div>
              <div className="ls-meta">
                <div className="ls-vtitle">京都の朝ラーメン</div>
                <Bar w={150} h={7} r={4} tone={2} />
              </div>
              <div className="ls-channel">
                <span className="ls-channel__avatar" />
                <Bar w={96} h={8} r={4} tone={3} />
                <span className="ls-channel__pill">
                  <Bar w={50} h={7} r={4} tone={4} />
                </span>
              </div>
              {[0, 1, 2].map((i) => (
                <div key={i} className="ls-next" style={{ top: 420 + i * 104 }}>
                  <span className={`ls-thumb ls-thumb--${i}`} />
                  <span className="ls-next__text">
                    <Bar w={[150, 128, 160][i]} h={8} r={4} tone={3} />
                    <Bar w={[112, 140, 96][i]} h={8} r={4} tone={3} />
                    <Bar w={[70, 82, 64][i]} h={6} r={3} tone={2} />
                  </span>
                </div>
              ))}
            </div>

            {/* ---- The floating frame: one shape, its content a separate layer ---- */}
            <div className="ls-pip" data-state={s.pip}>
              <span className="ls-pip__shape" data-state={s.pip} style={rectStyle(shape)} />
              <div className="ls-pip__content" data-target="pip" data-on={(s.pip === 'float' && s.pipText) || undefined} style={rectStyle(PIP)}>
                {/* The language is detected, so the badge crossfades in place */}
                <span className="ls-badge ls-badge--pip">
                  <span data-on={s.pipBadge === 'listening' || undefined}>[ listening ]</span>
                  <span data-on={s.pipBadge === 'source' || undefined}>Japanese → English</span>
                </span>
                <span className="ls-sub ls-sub--pip" data-on>
                  <span className="ls-line" data-rolled={s.rolled || undefined}>
                    <Words words={S1} count={s.s1} done={s.s1done} />
                  </span>
                  <span className="ls-line">
                    <Words words={S2} count={s.s2} done={s.s2done} />
                  </span>
                </span>
                <span className="ls-pip__controls" data-on={s.controls || undefined}>
                  <span className="ls-pip__close" data-target="close">
                    <Icon name="close" size={16} stroke={2.4} />
                  </span>
                </span>
              </div>
            </div>
          </Phone>
        )
      }}
    </Stage>
  )
}

