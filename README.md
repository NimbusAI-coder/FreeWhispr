# FreeWhispr

A private Mac dictation app. Hold `fn`, talk, and what you said is pasted into
whatever field you're in.

Transcription runs entirely on-device using Apple's `SpeechAnalyzer` (macOS 26).
There is no API key, no account, and no server. It works offline.

Built for personal use, inspired by [FreeFlow](https://github.com/zachlatta/freeflow)
(MIT, © 2026 Zach Latta). This is an independent implementation, not a fork of
its source.

## Use

| Gesture | Effect |
|---|---|
| Hold `fn` | Record while held; releases and pastes |
| Press `⌘` while holding `fn` | Latch on — keep recording after releasing `fn` |
| Tap `fn` while latched | Stop and paste |
| `esc` while recording | Cancel without pasting |

Also available from the menu bar icon.

## Build

```bash
make run
```

To keep it around:

```bash
make install
```

That copies it to `/Applications`. Accessibility permission is tied to the
binary's location and signature, so expect to re-grant it after moving or
rebuilding the app.

## Permissions

**Microphone** — to hear you.

**Accessibility** — unavoidable, and worth being clear about. macOS offers no
other way to observe a modifier key globally or to paste into another app. This
means FreeWhispr *can* see keystrokes system-wide. What it actually does with
that is in [`HotkeyManager.swift`](Sources/HotkeyManager.swift): the event tap
is created `.listenOnly` (it cannot alter or swallow events), it inspects only
modifier flags plus the `esc` keycode, and it stores no key data. It's about
110 lines and worth reading rather than taking on trust.

**Screen Recording is never requested.** Nothing here captures the screen.

## What it does not do

The app this was modelled on sends a screenshot of your active window, the
window title, and your currently-selected text to a cloud model on every
dictation, to infer "context." None of that exists here:

- No screenshots, no Screen Recording permission
- No reading window titles, app names, or selected text
- No auto-updater, no version pings, no telemetry
- No API keys, so no credential file and no Keychain use

The only URL compiled into the binary is `http://127.0.0.1:11434`. Verify:

```bash
strings build/FreeWhispr.app/Contents/MacOS/FreeWhispr | grep -iE '^https?://'
```

## Optional cleanup via Ollama

Off the shelf you get the raw transcript, which the on-device model already
punctuates well. Enable cleanup (filler-word removal, grammar) by running
[Ollama](https://ollama.com):

```bash
ollama pull llama3.2
```

FreeWhispr detects it automatically — the menu bar shows whether it's connected.
Two things keep this safe to leave switched on:

1. `OllamaCleanup` parses the host and **refuses anything that is not loopback**,
   so a typo can't start shipping transcripts off the machine.
2. Failure is never fatal. If Ollama is missing, stopped, slow, or returns
   something unusable, the raw transcript is pasted instead. Cleanup is a
   nicety, not a dependency.

Your transcript text does reach the local model when this is on. Nothing leaves
the Mac.

Change the model with:

```bash
defaults write local.freewhispr ollama_model qwen2.5
```

## Settings

No settings window yet — everything is `defaults`:

```bash
defaults write local.freewhispr cleanup_enabled -bool false
defaults write local.freewhispr restore_clipboard -bool true
defaults write local.freewhispr play_sounds -bool false
defaults write local.freewhispr locale_identifier en_US
```

## Troubleshooting

**Start with the log.** Every session is traced to
`~/Library/Logs/FreeWhispr.log`:

```bash
cat ~/Library/Logs/FreeWhispr.log
```

A healthy dictation looks like this:

```
begin: model ready
start: engine running rate=48000.0 ch=1
stop: dur=3.05s buffers=26 peak=0.11885 device=MacBook Pro Microphone
finish: session=1 fed=26 yielded=26 finalChars=28 volatileChars=27 finalizeError=none
```

Read it as a pipeline, and the first line that looks wrong is the fault:

- **Missing `engine running`** — setup stalled, so the microphone was never
  opened. The overlay appears and hears nothing.
- **`buffers=0`** — the audio tap never fired.
- **`buffers>0` but `peak=0.00000`** — audio is flowing but is digital silence:
  a revoked microphone grant, the wrong input device, or a hardware mute.
  macOS reports a revoked mic by feeding zeroed buffers, not by failing.
- **`fed` > `yielded`** — audio is being dropped in format conversion.
- **`volatileChars>0` but `finalChars=0`** — speech was recognised but never
  finalised.

Only mechanical facts are recorded — device names, buffer counts, audio
levels, error text. Transcript content is never written. The file rotates
at 512KB.

**`fn` does nothing, but Accessibility is already switched on.**

This is the one everybody hits. FreeWhispr is ad-hoc signed, and macOS ties an
Accessibility grant to the app's code signature. Every rebuild produces a new
signature, so macOS treats it as a different app — while still showing your old
grant as switched on. The toggle lies.

Fix it by clearing the stale grant and re-adding:

```bash
tccutil reset Accessibility local.freewhispr
```

Then reopen System Settings › Privacy & Security › **Accessibility** (this is a
different pane from the Accessibility one in the main sidebar, which is for
VoiceOver and Zoom), and grant it again.

To check whether it actually took, open the FreeWhispr menu: if the
"⚠ Grant Accessibility permission" line is gone, it is genuinely trusted. That
line reads live trust state rather than a cached flag, so it will not show a
false positive.

Install to a fixed location so this stops recurring:

```bash
make install
```

Expect to re-grant once after each rebuild. If you plan to change the code
often, sign with a stable self-signed certificate instead and the grant will
survive rebuilds.

**`fn` stops working while a password field is focused.** Expected. macOS
suppresses event taps whenever secure input is active. Click out of the field
and it returns.

## Notes

- The speech model downloads once on first launch, in the background.
- Dictations are marked transient on the pasteboard, so clipboard-history apps
  should skip them. Your previous clipboard contents are restored after pasting.
- Audio is streamed straight to the transcriber and released. It is never
  written to disk.
