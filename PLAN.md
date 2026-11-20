# recper — voice + visual feedback tool for agents

> Status: design draft (2026-11-20). No code yet.
> Decisions: **Mac first, Linux later** · delivery: **copy to clipboard + MCP server**.

## 1. Problem and goal

While having Claude Code / Codex / Antigravity build their app, the user gives feedback either
by typing or by taking screenshots one by one and pasting them. With many changes this gets slow and tedious.

recper is **not a video recorder**. The user talks and points at the screen. The app transcribes
the speech, takes screenshots at the moments of pointing, and produces a single output that
**binds the two together by time**. The agent reads this output and understands what to do.

## 2. Usage flow

1. **Menu bar icon.** The app does not appear in the Dock (`LSUIElement`). Clicking the icon opens no window;
   a small bar appears at the bottom of the screen: **Window · Area · Full screen** (similar to the macOS ⇧⌘5 bar).
   Shortcut: `⌥⇧R` (customizable).
2. **Target selection.**
   - *Window:* the window under the mouse is highlighted; clicking selects it.
   - *Area:* a rectangle is drawn by dragging.
   - *Full screen:* the screen under the cursor is selected.
   - After selection **everything outside the target is dimmed** (55% black overlay). The target stays bright.
3. **Session starts.** The microphone opens and live text streams in a small bar. A toolbox appears next to it.
4. **Toolbox** (draggable, floating panel):
   | Tool | Shortcut | What it does |
   |---|---|---|
   | Cursor (pass-through) | `V` | Drawing off, clicks go to the app underneath |
   | Pen | `P` | Freehand drawing |
   | Box | `B` | Rectangle mark |
   | Arrow | `A` | Draws an arrow |
   | Blur | `X` | The selected region is permanently blurred (for sensitive data) |
   | Snapshot | `S` | Takes a screenshot manually |
   | Undo / clear | `⌘Z` / `C` | |
   | Finish | `Esc` ×2 or `⏎` | Closes the session |

   At the bottom there is a **screenshot strip**: captured screenshots are lined up as thumbnails.
   Clicking a thumbnail deletes or renames it.
5. **Finish.** The output is written, and the `feedback.md` path plus a ready prompt are copied to the clipboard. The MCP server serves the latest session.

**Important interaction rule:** The user must be able to use the app underneath while drawing.
That is why the default tool is *Cursor*. Holding `⌘` temporarily enables the pen; releasing it returns to the cursor.

## 3. When a screenshot is taken

- **Automatically after drawing.** After a pen, box or arrow is drawn, a screenshot is taken if no new stroke arrives within 700 ms.
  Consecutive strokes are collected into a single screenshot.
- **Manually:** the `S` key or the toolbox button.
- **Silence in speech + a drawing present:** optional setting (v2).

**Strokes are burned into the pixels** of the screenshot (the agent sees the arrow/box). Blur is applied
**permanently** to the pixels before saving; the raw image is never written to disk. The dimming overlay, the toolbox and the text bar
are **excluded** from capture (ScreenCaptureKit `excludingWindows`).

## 4. Text ↔ screenshot relationship (the part that needed clarifying)

A single **session clock** is used (`t = 0` is the start of the session, in seconds). Everything is stamped against this clock:

- **Speech segments:** a `[t0, t1]` range and text. Word-level timing is kept as well.
- **Events:** happen at time `t`. Types: stroke, blur, screenshot, target change.

**Binding rule:** Each screenshot is bound to the sentence nearest to its capture time `t`.
- If `t` falls inside a sentence, the screenshot is attached **to the end of that sentence**.
- If `t` falls in the silence between two sentences, it is attached to the **previous** sentence.
  People usually talk first and then point; if the silence is longer than 3 s, it is attached to the **next** sentence.
- If there is no speech at all, the screenshot becomes an item of its own.

The **coordinates** of each stroke (relative to the target, in pixels) are also stored per screenshot. That way the agent
knows where the "logo" is from the box too.

### 4.1 `feedback.md` (the main file the agent reads)

```markdown
# Feedback — 2026-11-20 15:42
Target: window "MyApp — localhost:5173" (1440×900) · duration 1:12 · 3 screenshots

1. This button's padding is too large, shrink it a bit. [00:04]
   ![1](shots/01.png) — red box: (812,540)–(940,588)

2. The logo in the header is shifted left, center it. [00:11]
   ![2](shots/02.png) — arrow: (120,40)→(64,40)

3. The animation stutters when the sidebar opens. [00:19]
   (no screenshot)
```

- Numbered items = spoken sentences, in the order they were said.
- Screenshot paths are **relative**; Claude Code, Codex and Antigravity can read a local image from its path.
- Text copied to the clipboard: `Apply this feedback: /Users/.../recper/2026-11-20_1542/feedback.md`

### 4.2 `session.json` (for machines; MCP uses this)

```json
{
  "version": 1,
  "startedAt": "2026-11-20T15:42:03+03:00",
  "target": { "kind": "window", "app": "Google Chrome", "title": "MyApp — localhost:5173", "size": [1440, 900] },
  "locale": "en-US",
  "segments": [
    { "id": "s1", "t0": 3.1, "t1": 6.8, "text": "This button's padding is too large, shrink it a bit.",
      "words": [{ "w": "This", "t0": 3.1, "t1": 3.3 }] }
  ],
  "events": [
    { "t": 5.9, "type": "stroke", "tool": "box", "rect": [812, 540, 128, 48] },
    { "t": 6.6, "type": "shot", "id": "01", "file": "shots/01.png", "segment": "s1" }
  ]
}
```

### 4.3 Session folder

```
~/.recper/sessions/2026-11-20_154203/
  feedback.md   session.json   shots/01.png 02.png ...
```

Audio is **not kept** by default (privacy and disk). A setting can keep `audio.m4a`.

## 5. Speech to text

### Mac: built-in dictation (verified)

macOS 26 `SpeechAnalyzer` + **`DictationTranscriber`** was tested on this Mac:

- **Turkish (tr-TR) is supported**, the model is downloaded to the device (one-time download, managed by the system) and it runs **fully offline**.
  Note: the new `SpeechTranscriber` does **not support** Turkish (30 languages, no tr). `DictationTranscriber` supports 54 languages.
- The `timeIndexedLongDictation` preset + `audioTimeRange` give **per-word timing**. That is what the binding rule needs.
- Speed: a 3 s clip was transcribed in 0.5 s. It also gives live (volatile) results.
- **Weak spot: English terms inside non-English speech.** In a test with synthetic Turkish speech, *header* came out as "Lothar",
  *sidebar* as "Sidra". Supplying a term list via `AnalysisContext.contextualStrings` fixed *padding*,
  but not the others. Needs to be re-measured with real speech.
  - The term list can be fed automatically: labels in the target app's accessibility tree (AX), component names
    in the project folder, and a fixed UI vocabulary (button, padding, margin, header, navbar, modal...).
- **Fallback:** a "Whisper (local)" option in settings. `whisper.cpp` + the `small` or `large-v3-turbo-q5` model,
  downloaded if the user wants (~180 MB / ~550 MB). May do better on mixed-language speech; to be compared on the same audio.

### Linux: whisper.cpp required

Live streaming with `whisper.cpp`, sentence splitting with VAD (Silero). Word timing via `--max-len 1 -ojf`.

## 6. Technical structure (Mac)

| Part | Choice |
|---|---|
| Language | Swift 6, SwiftPM. No Xcode needed, builds with Command Line Tools |
| Menu bar | `NSStatusItem`, `LSUIElement` |
| Overlay and drawing | One borderless, transparent `NSPanel` per screen (`.screenSaver` level). In cursor mode `ignoresMouseEvents = true` |
| Window selection | `SCShareableContent` window list + highlight of the window under the mouse |
| Screenshot | ScreenCaptureKit `SCScreenshotManager` (window or area), excluding our own windows |
| Stroke burn-in | Draw on top of the image with Core Graphics. Blur: Core Image `CIGaussianBlur` (permanent) |
| Audio | `AVAudioEngine` → `SpeechAnalyzer` (live) |
| Output | `feedback.md` + `session.json` + PNG |
| MCP | `recper mcp` in the same binary (stdio). Tools: `list_sessions`, `get_latest_feedback`, `get_session(id)` |
| Permissions | Screen Recording and Microphone (TCC) |

**Permission note:** With an unsigned (ad-hoc) build, the Screen Recording grant may reset on every rebuild.
Using a stable self-signed certificate during development solves this. The first live trial will be in the user's hands.

## 7. Linux (later)

Wayland restricts many things X11 allows. The plan must be built around these limits:

- **Screen capture:** `xdg-desktop-portal` ScreenCast/Screenshot + PipeWire. Window/area selection is done by the **portal's own
  dialog**; "highlight the window under the mouse" is not possible on Wayland.
- **Dimming and on-screen drawing:** doable with `wlr-layer-shell` on wlroots-based desktops (Sway, Hyprland) and KDE.
  **GNOME has no layer-shell**. There, a fullscreen transparent window or a GNOME Shell extension is needed. *To be verified.*
- **Global shortcut:** portal GlobalShortcuts (GNOME 48+, KDE).
- **X11:** everything can be done much like on the Mac.
- The session format (section 4) stays the same. MCP and output code can move into a shared library.

## 8. Phases

| Phase | Scope | Done when |
|---|---|---|
| 0 — validation | ✅ Dictation tr-TR + timestamps (done). Remaining: mixed Turkish-English quality with real speech, comparison with Whisper | Measurement table |
| 1 — skeleton | ✅ Code written (2026-11-20): menu bar, ⌥⇧R, bottom bar, area/window/screen selection, dimming, window tracking. .app 220 KB, 11 MB idle. Awaiting manual test | Selection and overlay work |
| 2 — core | ✅ (tested live 2026-11-20) Code written (2026-11-20): live dictation, pen/box/arrow, automatic screenshot after drawing, `feedback.md` + clipboard; last area is remembered | One end-to-end session |
| 3 — polish | ✅ (2026-11-20) Blur, 6 colors, tool cursors, silent screenshot (sentence end / pause), glass bar (audio waveform, screenshot stack, square palette), numbered marks (#n badges), element under the mark (AX: role, name, #id, .class), voice commands ("take screenshot", "undo", "finish"), review screen (⌘⏎ to send), feedback.md checklist (`- [ ]`) | Ready for daily use |
| 4 — MCP | 🟡 Code written (2026-11-20): `Recper --mcp` (stdio): get_feedback (text + downscaled JPEG), list_sessions, mark_done, request_feedback (opens via `recper://start`, waits until the session finishes). Tested via stdin; awaiting test from inside an agent | get_feedback works from Claude Code |
| 5 — Whisper | Optional model download | Selectable in settings |
| 6 — Linux | Section 7 | Sway/KDE + X11 |

## 9. Open questions

1. Should the screenshot cover **only the target** (window/area) or **the whole screen**? Suggestion: only the target. No unnecessary pixels go to the agent.
2. Where should the session folder live? Decision: ~/.recper/sessions (no spaces in the path, easy for agents to read). A setting can put it inside the project as `.feedback/` (added to gitignore).
3. Preview on finish? Decision: there is a review screen; it can be turned off from the menu (on by default).
4. App name: should "recper" stay as the working name?
