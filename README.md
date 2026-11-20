# recper

**Talk and draw on your screen; your coding agent gets a clean, timestamped checklist with annotated screenshots.**

recper is a tiny macOS menu-bar app for giving visual feedback to coding agents such as Claude Code, Codex or Antigravity.
Instead of typing long descriptions or pasting screenshots one by one, you pick a window, area or screen, say what's wrong
and circle it. recper transcribes your speech on-device, captures screenshots with your marks burned in, binds each
screenshot to the sentence you were saying, and hands the result to your agent as a Markdown file, via the clipboard or over MCP.

It is not a screen recorder: no video, no audio files. Just text, numbered marks and screenshots.

## Features

- **Pick a target**: window, area or full screen (`⌥⇧R`). Everything outside the target is dimmed.
- **On-device dictation** with Apple's `SpeechAnalyzer` / `DictationTranscriber`; live text while you talk.
- **Draw & edit** with pen, box, ellipse, arrow and blur in 6 colors. Click any box, ellipse, arrow or blur region while on screen to move, resize, or delete (`⌫`) it. Blur is applied permanently before anything is saved.
- **Circle gesture**: in cursor mode, move the mouse in a closed circle around something (without clicking) to drop a numbered ellipse mark automatically (configurable in Settings).
- **Numbered marks**: every mark gets a `#n` badge, and the UI element under it is looked up via Accessibility
  (role, title, identifier).
- **Screenshots** with a shutter: `Space` / `T` / `⏎` while drawing, `⌥⇧S` anywhere, or the button in the bar.
- **Voice commands**: "take screenshot", "undo", "finish".
- **Review screen** before sending (optional): edit sentences, click screenshots to inspect them large, or remove unneeded items (`⌘⏎` sends, `Esc` saves without copying).
- **Output**: `feedback.md` checklist + `session.json` + `shots/*.png`, and a ready-to-paste prompt on the clipboard.
- **MCP server** (`Recper --mcp`) so agents can read feedback, check off items, and ask you for feedback themselves.

## Requirements

- macOS 26 or later, Apple Silicon
- Swift 6 toolchain (Xcode or just the Command Line Tools)

## Build and run

```sh
scripts/bundle.sh
open build/Recper.app
```

`bundle.sh` builds a release binary and wraps it in `build/Recper.app` with an ad-hoc signature.
Optionally run `scripts/dev-cert.sh` once to create a local self-signed signing identity, so macOS permissions
survive rebuilds.

## Permissions

| Permission | Why |
|---|---|
| Microphone | Live dictation. Audio is never recorded or saved. |
| Speech Recognition | On-device transcription. |
| Screen Recording | Capturing the selected window, area or screen. |
| Accessibility (optional) | Naming the UI element under each mark. |

## Usage

1. Press `⌥⇧R` (or click the menu-bar icon) and choose a window, area or screen.
2. Talk. Draw on anything you mention. Press the shutter (`Space`) when the marks are ready; marks still on screen
   are captured automatically when you finish. (Auto-capture at the end of each sentence can be enabled from the menu.)
3. Press `⌥⇧R` again (or say "finish") to finish. Review, send, and paste the prompt into your agent.

### Shortcuts

| Key | Action |
|---|---|
| `⌥⇧R` | Start / finish a session |
| `1` / `2` / `3` | Target mode: window / area / screen (while choosing) |
| `P` `B` `O` `A` `X` | Pen, box, ellipse, arrow, blur |
| `1`–`6` | Ink color (while drawing) |
| `Space` / `T` / `⏎` | Take a screenshot (while drawing) |
| `⌘Z` | Undo the last mark, edit, deletion, or screenshot |
| `⌫` / `Delete` | Remove the selected mark |
| `Esc` | Deselect a selected mark; otherwise back to the cursor (clicks go to the app underneath) |
| Click & drag a mark | Select a box, ellipse, arrow, or blur region to move its body or drag edges/corners/endpoints to resize (works while drawing and in cursor mode when hovering a mark) |
| Circle with mouse | In cursor mode (without clicking), loop around a region to drop a numbered ellipse mark |
| `⌥⇧S` | During a session, from any app: opens a radial menu at the pointer; click pen, box, arrow, finish, undo or blur, or the center for a screenshot. Click outside, Esc or `⌥⇧S` closes it |
| `⌥⇧V` `P` `B` `O` `A` `X` `S` `Z` | During a session, from any app: cursor, pen, box, ellipse, arrow, blur, screenshot, undo |
| `⌘⏎` / `Esc` (Review) | Send (save & copy prompt) / save without copying; click any thumbnail to inspect it large |

## Output

Each session is saved to `~/.recper/sessions/<timestamp>/`:

```
feedback.md   session.json   shots/01.png 02.png ...
```

`feedback.md` is a checklist of what you said, with screenshots attached to the sentence they belong to:

```markdown
# Feedback — 2026-11-20 15:42

- [ ] 1. This button's padding is too large, shrink it a bit. [00:07]
  ↳ drawn while speaking: #1 (screenshot 1)
  ![1](shots/01.png) — #1 box (10,20)–(110,60) → AXButton "Save"
- [ ] 2. The logo in the header is shifted left, center it. [00:15]
```

`session.json` holds the same data for machines: segments with timings, screenshots and mark coordinates.

## MCP

Register the server with your agent, for example Claude Code:

```sh
claude mcp add recper -- /path/to/Recper.app/Contents/MacOS/Recper --mcp
```

| Tool | What it does |
|---|---|
| `get_feedback` | Returns the latest (or a given) session: checklist text plus downscaled screenshots and mark summaries. |
| `list_sessions` | Lists recent sessions with duration, screenshot count, done/total items and the first sentence. |
| `mark_done` | Checks off (or unchecks) an item in `feedback.md`. |
| `request_feedback` | Opens recper on your screen (via `recper://start`), optionally with a question, and waits until you finish. |

## Privacy

Everything stays on your Mac. Speech is transcribed on-device, audio is never stored, and recper makes no network
requests. Blurred regions are blurred in the pixels before a screenshot is written to disk.

## Tests

```sh
scripts/test.sh
```

## Roadmap

- Optional local Whisper model for speech recognition
- Linux support
- Short motion clips alongside screenshots

## License

[MIT](LICENSE)
