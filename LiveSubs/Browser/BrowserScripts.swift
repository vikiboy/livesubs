import Foundation

/// JavaScript injected into every frame of a page opened in the private browser.
/// Self-contained (one closure, nothing global), every hook wrapped in try/catch and
/// always calling the page's original function, so it can never break a site.
enum BrowserScripts {
    static let handlerName = "livesubs"

    static let hook = #"""
    (() => {
      if (window.__liveSubsHooked) return;
      Object.defineProperty(window, '__liveSubsHooked', { value: true });
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.livesubs;
      if (!handler) return;
      const send = (m) => { try { handler.postMessage(m); } catch (e) {} };
      const frameId = Math.random().toString(36).slice(2);
      const buffers = new WeakMap();
      let nextId = 0;

      // 0. Ask for AAC audio: say WebM audio (Opus) isn't supported, so players that offer
      //    both (YouTube does) pick MP4/AAC, which LiveSubs can read. Video formats untouched.
      for (const C of [window.MediaSource, window.ManagedMediaSource]) {
        try {
          if (!C || !C.isTypeSupported) continue;
          const its = C.isTypeSupported;
          C.isTypeSupported = function (t) {
            try { if (/^audio\/webm/i.test(String(t))) return false; } catch (e) {}
            return its.apply(this, arguments);
          };
        } catch (e) {}
      }

      // 1. Copy the audio chunks the page's player appends (Media Source Extensions).
      const wantsAudio = (type) => /audio\/|mp4a|opus|ac-3|ec-3|flac/i.test(type || '');
      const wrapAdd = (proto) => {
        if (!proto || !proto.addSourceBuffer) return;
        const original = proto.addSourceBuffer;
        proto.addSourceBuffer = function (type) {
          const sb = original.apply(this, arguments);
          try { buffers.set(sb, { id: frameId + ':' + (nextId++), type: String(type), audio: wantsAudio(type) }); patchAppend(sb); } catch (e) {}
          return sb;
        };
      };
      try { wrapAdd(window.MediaSource && MediaSource.prototype); } catch (e) {}
      try { wrapAdd(window.ManagedMediaSource && ManagedMediaSource.prototype); } catch (e) {}
      // Patch appendBuffer wherever this browser defines it (SourceBuffer on Mac/iPad,
      // only ManagedSourceBuffer on iPhone), once per prototype.
      const patched = new WeakSet();
      function patchAppend(sb) {
        let proto = Object.getPrototypeOf(sb);
        while (proto && !Object.prototype.hasOwnProperty.call(proto, 'appendBuffer')) proto = Object.getPrototypeOf(proto);
        if (!proto || patched.has(proto)) return;
        patched.add(proto);
        const append = proto.appendBuffer;
        proto.appendBuffer = function (data) {
          try {
            const info = buffers.get(this);
            if (info && info.audio && data && !adShowing()) {
              const u8 = data instanceof ArrayBuffer ? new Uint8Array(data)
                       : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
              let bin = '';
              for (let i = 0; i < u8.length; i += 0x8000) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
              send({ k: 'chunk', id: info.id, type: info.type, data: btoa(bin) });
            }
          } catch (e) {}
          return append.apply(this, arguments);
        };
      }

      // YouTube in-video ads: skip them as soon as possible, play the unskippable ones
      // muted at high speed, and don't mistake their audio for the programme's.
      const isYouTube = /(^|\.)youtube\.com$/.test(location.hostname);
      const adShowing = () => isYouTube && !!document.querySelector('.ad-showing, .ad-interrupting');
      let wasAd = false;
      if (isYouTube) setInterval(() => {
        try {
          const ad = adShowing();
          if (ad) {
            const skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, button[class*="skip"]');
            if (skip) skip.click();
            const v = document.querySelector('video');
            if (v && isFinite(v.duration) && v.duration > 0) { v.muted = true; v.playbackRate = 16; if (v.duration - v.currentTime > 0.5) v.currentTime = v.duration - 0.1; }
          } else if (wasAd) {
            const v = document.querySelector('video'); if (v) { v.muted = false; v.playbackRate = 1; }
            send({ k: 'reset' });
          }
          wasAd = ad;
        } catch (e) {}
      }, 300);

      // Note playlists the page's player downloads (hls.js and similar fetch the .m3u8
      // themselves), so LiveSubs can read the whole video ahead, not just the player's buffer.
      const notePlaylist = (u) => {
        try {
          const url = new URL(String(u), location.href).href;
          if (/\.m3u8(\?|#|$)/i.test(url)) send({ k: 'playlist', url });
        } catch (e) {}
      };
      try {
        const f = window.fetch;
        if (f) window.fetch = function (input) { try { notePlaylist(input && input.url ? input.url : input); } catch (e) {} return f.apply(this, arguments); };
        const open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (m, u) { try { notePlaylist(u); } catch (e) {} return open.apply(this, arguments); };
      } catch (e) {}

      // 2. Report the main video's position, so subtitles follow playback exactly.
      let track = null;
      const mainVideo = () => {
        let best = null, area = 0;
        for (const v of document.querySelectorAll('video')) {
          const r = v.getBoundingClientRect(), a = r.width * r.height;
          if (a > area || (!best && v.currentTime > 0)) { best = v; area = a; }
        }
        return best;
      };
      setInterval(() => {
        try {
          const v = mainVideo();
          if (!v) {
            // Players often live in an embedded frame: the top page reports where it is.
            if (window === window.top) {
              let best = null, area = 0;
              for (const f of document.querySelectorAll('iframe')) {
                const r = f.getBoundingClientRect(), a = r.width * r.height;
                if (r.width > 200 && r.height > 100 && a > area) { best = r; area = a; }
              }
              if (best) send({ k: 'frameRect', x: best.x, y: best.y, w: best.width, h: best.height });
            }
            return;
          }
          if (!v.hasAttribute('playsinline')) v.setAttribute('playsinline', '');
          const src = v.currentSrc || v.src || '';
          const r = v.getBoundingClientRect();
          send({ k: 'time', t: v.currentTime, paused: v.paused, rate: v.playbackRate, d: v.duration,
                 kind: src.startsWith('blob:') ? 'stream' : (src ? 'file' : 'none'),
                 src: src.startsWith('blob:') ? '' : src,
                 protected: !!v.mediaKeys, main: window === window.top,
                 x: r.x, y: r.y, w: r.width, h: r.height,
                 fullscreen: !!(v.webkitDisplayingFullscreen || document.fullscreenElement) });
        } catch (e) {}
      }, 250);

      // Hold: pause the main video until subtitles are ready, then resume.
      window.__liveSubsHold = (hold) => {
        try {
          const v = mainVideo(); if (!v) return;
          if (hold && !v.paused) { v.__liveSubsHeld = true; v.pause(); }
          if (!hold && v.__liveSubsHeld) { v.__liveSubsHeld = false; v.play().catch(() => {}); }
        } catch (e) {}
      };

      // 2b. Fullscreen inside LiveSubs: the system's fullscreen player would cover the
      //     subtitles, so fullscreen requests enlarge the player in the page instead and
      //     LiveSubs hides its own bars. In an embedded frame, the top page enlarges the frame.
      const FS_STYLE = 'position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;' +
                       'max-width:none!important;max-height:none!important;margin:0!important;z-index:2147483647!important;' +
                       'background:#000!important;transform:none!important;';
      let fsEl = null, fsSaved = '';
      const enterFS = (el) => {
        try {
          if (fsEl) return;
          fsEl = el; fsSaved = el.getAttribute('style') || '';
          el.setAttribute('style', fsSaved + ';' + FS_STYLE);
          if (el.tagName === 'VIDEO') el.style.setProperty('object-fit', 'contain', 'important');
          document.documentElement.style.setProperty('overflow', 'hidden', 'important');
          if (window !== window.top) window.top.postMessage({ liveSubsFS: true }, '*');
          send({ k: 'fs', on: true });
        } catch (e) {}
      };
      const exitFS = () => {
        try {
          if (!fsEl) return;
          fsEl.setAttribute('style', fsSaved); fsEl = null;
          document.documentElement.style.removeProperty('overflow');
          if (window !== window.top) window.top.postMessage({ liveSubsFS: false }, '*');
          send({ k: 'fs', on: false });
        } catch (e) {}
      };
      window.__liveSubsExitFS = () => {
        exitFS();
        try { for (const f of document.querySelectorAll('iframe')) f.contentWindow.postMessage({ liveSubsExitFS: true }, '*'); } catch (e) {}
      };
      // Top page: enlarge the embedded frame that asked.
      window.addEventListener('message', (e) => {
        try {
          if (e.data && e.data.liveSubsExitFS) { exitFS(); return; }
          if (!e.data || typeof e.data.liveSubsFS !== 'boolean' || window !== window.top) return;
          for (const f of document.querySelectorAll('iframe')) {
            if (f.contentWindow === e.source) { e.data.liveSubsFS ? enterFS(f) : exitFS(); break; }
          }
        } catch (err) {}
      });
      const takeOver = (proto, name, exit) => {
        try {
          if (!proto || !proto[name]) return;
          proto[name] = function () { exit ? exitFS() : enterFS(this); return Promise.resolve(); };
        } catch (e) {}
      };
      takeOver(Element.prototype, 'requestFullscreen');
      takeOver(Element.prototype, 'webkitRequestFullscreen');
      takeOver(Element.prototype, 'webkitRequestFullScreen');
      takeOver(HTMLVideoElement.prototype, 'webkitEnterFullscreen');
      takeOver(HTMLVideoElement.prototype, 'webkitEnterFullScreen');
      takeOver(Document.prototype, 'exitFullscreen', true);
      takeOver(Document.prototype, 'webkitExitFullscreen', true);
      // The video's own built-in fullscreen button: leave the system player at once, enlarge here.
      document.addEventListener('webkitbeginfullscreen', (e) => {
        try { const v = e.target; setTimeout(() => { try { v.webkitExitFullscreen(); } catch (x) {} enterFS(v); }, 50); } catch (x) {}
      }, true);

      // LiveSubs' own playback controls (used in its fullscreen).
      window.__liveSubsControl = (action, value) => {
        try {
          const v = mainVideo(); if (!v) return;
          if (action === 'toggle') { v.paused ? v.play().catch(() => {}) : v.pause(); }
          else if (action === 'skip') { v.currentTime = Math.max(0, Math.min((v.duration || 1e9) - 0.5, v.currentTime + value)); }
          else if (action === 'seek') { v.currentTime = Math.max(0, value); }
        } catch (e) {}
      };

      // 3. Fullscreen: the native player only shows the video's own text tracks.
      window.__liveSubsCue = (start, end, text) => {
        try {
          const v = mainVideo(); if (!v) return;
          if (!track || track.__video !== v) { track = v.addTextTrack('subtitles', 'English (LiveSubs)', 'en'); track.__video = v; }
          track.addCue(new VTTCue(start, end, text));
          track.mode = (v.webkitDisplayingFullscreen || document.fullscreenElement) ? 'showing' : 'hidden';
        } catch (e) {}
      };
      document.addEventListener('webkitbeginfullscreen', () => { try { if (track) track.mode = 'showing'; } catch (e) {} }, true);
      document.addEventListener('webkitendfullscreen', () => { try { if (track) track.mode = 'hidden'; } catch (e) {} }, true);
    })();
    """#
}
