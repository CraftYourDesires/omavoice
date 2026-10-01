# omavoice

Local, private dictation for [Omarchy](https://omarchy.org) that feels like Wispr Flow or Super Whisper. You talk, and clean text lands wherever your cursor is: filler words gone, self-corrections applied, names spelled right, formatted for the app you are in. Nothing leaves your machine.

It is a tuned setup around [Voxtype](https://github.com/peteonrails/voxtype), the dictation tool Omarchy installs from its menu, plus a local LLM cleanup pass and a few helpers that make long dictations fast and accurate.

## Will it run on my machine?

omavoice runs on Omarchy (Arch Linux with Hyprland) on x86 PCs. The installer checks your hardware and picks the setup that won't bog the machine down.

| Your machine | What you get | Speed after you stop talking |
|---|---|---|
| **NVIDIA GPU with 12GB+ VRAM**<br>(desktop RTX 3060 12GB, 4070 and up, 5070 and up) | Everything: GPU transcription, LLM cleanup, live cleanup while you talk | About 0.2 to 1 second, even for a 5 minute dictation (measured) |
| **NVIDIA GPU with 6 to 11GB VRAM**<br>(most gaming laptops, RTX 4060, 4070 laptop, Dell XPS with an RTX 4050/4060) | Everything; transcription runs on the CPU so both models fit | About 1 to 2 seconds (estimate) |
| **No NVIDIA GPU**<br>(Dell XPS 13/14 with Intel graphics, Framework, ThinkPad, AMD laptops) | Transcription only, on the CPU. You get Cohere's punctuated, capitalized text without the LLM cleanup | About 1 to 3 seconds (estimate) |
| **Mac** (MacBook, Mac mini, iMac) | Not supported. Omarchy doesn't run on Apple Silicon and Voxtype is Linux only | Use Super Whisper or Wispr Flow on macOS; they use Apple's own chips well |

**Minimums for the CPU-only setup:** a CPU with AVX2 (any Intel or AMD from roughly 2015 on), **16GB of RAM** (the transcription model holds about 9.4GB while loaded), and 5GB of disk. On a laptop, dictating uses a few CPU cores in bursts while you talk, and nothing when you don't.

**For the full GPU setup:** an NVIDIA card with the Omarchy-installed driver, 16GB of RAM, and about 16GB of disk (3.9GB speech model, 9GB cleanup model, CUDA libraries). Idle cost is zero CPU and 4.4GB of VRAM; the cleanup model unloads after 10 idle minutes, and a guard moves everything off the GPU while games or other AI tools need the memory.

**AMD Radeon GPUs:** Voxtype and Ollama both have ROCm builds, but omavoice hasn't been tested on them, so the installer treats Radeon machines as CPU-only for now.

Why the cleanup needs a GPU: the LLM rewrites your text word by word. On an RTX 5080 that takes 0.1 seconds for a sentence; on a desktop CPU it took about 10 seconds, which is too slow to feel like dictation.

## What it adds to Omarchy's stock Voxtype

| | Omarchy's Voxtype setup | omavoice |
|---|---|---|
| Speech model | Whisper base.en (150MB) | Cohere Transcribe (3.9GB), #1 on the Open ASR Leaderboard, on the GPU when there is one |
| Recording length | 60 seconds | 10 minutes, transcribed in 20 second chunks while you talk (Cohere garbles anything past about 35 seconds in one pass) |
| Cleanup | None | Local LLM (Gemma 4 E4B via Ollama) removes filler, applies "no wait" corrections, formats lists and paragraphs |
| Speed on long dictations | Waits for everything after you stop | Cleans finished sentences while you are still talking; only the last few words are left at the end |
| Names and jargon | Often misheard | Your personal dictionary, plus names from your selected text and clipboard |
| Per-app style | One style everywhere | Casual in chat, laid out as an email in Gmail and HEY, exact file names in terminals, Markdown in Obsidian |
| GPU sharing | Model stays loaded | Steps aside automatically when a game or another AI tool needs the VRAM |
| Output | Types the text character by character | Pastes the whole text at once, then puts your clipboard back exactly as it was |
| Recovery | None | A private, searchable history: click a dictation to copy it when it went to the wrong window |
| Overlay | Voxtype's own OSD | Two theme-matched styles, a neon waveform pill or a cyberpunk line trace |

## Measured results

On an RTX 5080 (16GB) with an i9-14900KF, 2026-09-26:

| What | Result |
|---|---|
| Transcription accuracy, 3 minute read-aloud passage | 1.5% word error rate in 20 second chunks; one 180 second pass came out garbled |
| Transcription time per 20 second chunk | 1.6s on the GPU, about 2.7s on 4 CPU threads |
| Time from stopping to cleaned text, 3 minute dictation | 0.24s with live cleanup, 3.4s without |
| Cleanup test suite (`tests/`) | 27 of 27 cases pass |
| Cleanup time, one sentence | about 0.1s |

A single cleanup pass over a long text once dropped a 69 word passage without complaint, so anything over 150 words is now cleaned a few sentences at a time.

## Install

```bash
git clone https://github.com/CraftYourDesires/omavoice ~/Projects/omavoice
cd ~/Projects/omavoice
./install.sh --name YourFirstName
```

The installer:

1. Detects your GPU, VRAM and RAM and picks one of the setups above (override with `--cleanup` or `--no-cleanup`).
2. Installs `voxtype-bin` and `wtype`, plus `ollama-cuda` and `cudnn` when there is an NVIDIA GPU.
3. Downloads Cohere Transcribe (3.9GB) and, with cleanup on, `gemma4:e4b` (9GB).
4. Symlinks the scripts into `~/.local/bin` and the service files into `~/.config/systemd/user`, so `git pull` updates them, and builds `omavoice-clipboard` (a small C helper) into `build/`.
5. Creates your config files only if they are missing. A stock Voxtype config is moved to `config.toml.before-omavoice`. An existing omavoice config only gets its `[output]` switched to file mode (saved first as `config.toml.before-omavoice-output`); your replacements, paste keys and everything else stay.
6. Holds `voxtype-bin` back from routine updates and links the Omarchy hooks that check the setup after each update (see below).
7. Links the recording overlay into `~/.config/omarchy/plugins` and enables it in omarchy-shell.
8. Starts `omavoice-output.service` and adds the omavoice app to the app launcher.
9. Prints the Hyprland key bindings to paste into `~/.config/hypr/bindings.lua` (also in `hyprland/bindings.lua`).

## Use

- **Tap Super + Alt** to start, tap again to stop. The text is pasted where your cursor is.
- **Hold F9** to talk, release to paste.
- **Super + Ctrl + X** toggles, like Omarchy's default.

While you talk, a small pill at the top of the focused monitor shows a glowing waveform that follows your voice: it swells with loudness, moves faster when you talk faster, and throws a few thin sparks on stressed syllables. It settles into a slow ripple while the text is transcribed and disappears when it lands. It never takes focus or clicks. Every color comes from your current Omarchy theme: the accent (or the theme's cool hue) paints the rim and a thin neon glow around the pill, a warm theme color the core, and each is kept bright or dark enough to read against the theme's background. Switch themes and it follows within a moment, crossfading if it is on screen. A light film grain and dither give it a soft, slightly raw texture without banding. Set `overlay = false` or `overlay_position = "bottom"` in `~/.config/voxtype/omavoice.toml` to hide or move it.

The overlay has a second style, **Trace**: a lie detector pen on scrolling paper inside a chamfered cyberpunk panel. It draws a calm baseline while you are quiet, swings into jagged, wilder peaks as your voice gets louder, and lights the glow around the line as grainy ASCII glyphs over a graticule that scrolls with the paper. It uses the same theme colors and live theme following as the neon pill. Pick it in the omavoice app, or set `overlay_style = "trace"`.

Two more styles share the Trace panel and its ASCII glow but react instantly, since nothing waits for paper to scroll. **Scope** is a synth oscilloscope: a wave that stays in place, soft when you are quiet, taller with sharper harmonics as you get louder, with a phosphor ghost of the moment before. **Clip** is a DAW clip waveform that grows out from the center, so your newest sound is always in the middle. Set `overlay_style = "scope"` or `"clip"`. All styles scale to your own recent loudness, so a normal voice sits mid-height and only speaking up reaches the top.

The text is pasted into the focused app and your clipboard is put back right after, with every format it had (text, rich text, images), so dictating never replaces what you copied. Every finished dictation is also kept in a private history. If it went to the wrong window, or no text box had focus, open the omavoice app and click it to copy it.

### The omavoice app

Open **omavoice** from the app launcher (or run `omavoice`). It follows your Omarchy theme and font, live.

- **Style**: both overlay styles playing live side by side, rendered by the real overlay code. Click one to use it. Also turns the overlay on or off and moves it to the top or bottom.
- **History**: every dictation, newest first, with time, app, word count and words per minute. Search it, click one to copy it (the only way anything here touches your clipboard), delete one, clear all, and choose how long to keep them: off, 7, 30 or 90 days, a year, or forever.
- **Dictionary**: edit `~/.config/voxtype/dictionary.txt` by section, with a term and an optional hint per line. Only the lines you change are rewritten; comments and layout stay. A raw file view is there for anything else.
- **Stats**: words and words per minute for today, 7 days, 30 days and all time, plus words per day for two weeks. Words are counted in the final text (`don't`, `e-mail` and `3.5` are one word each, punctuation and list dashes none), and words per minute use the time you were actually recording.

Ctrl+1 to Ctrl+4 switch pages, Ctrl+F searches history, Ctrl+S saves the dictionary.

Say "new line", "new paragraph" or "bullet point" for layout. Correct yourself mid-sentence with "no wait", "I mean" or "scratch that".

## Configuration

Everything lives in `~/.config/voxtype/`:

| File | What it's for |
|---|---|
| `dictionary.txt` | Names, products and jargon, one per line. Add `term \| hint`, for example `Aoife \| coworker, misheard as "eefa"`; a "misheard as" hint also becomes a worked example for the model |
| `app-styles.toml` | Per-app cleanup styles, matched on the window class or title |
| `omavoice.toml` | Your first name, whether cleanup is on, the overlay (`overlay`, `overlay_position`, `overlay_style`: neon, trace, scope or clip) and history (`history`, `history_days`). The app edits it in place |
| `config.toml` | Voxtype itself: model, chunk size, paste keys, instant word replacements |
| `omavoice.env` | Only on machines where transcription runs on the CPU |

`dictation-dictionary-refresh` suggests dictionary terms from your own writing (Claude Code and Codex prompts, Markdown notes in `$OMAVOICE_NOTES`, GitHub repo names). Nothing is added automatically.

## How it works

```
key press ─▶ dictation-record ─┬─▶ warms the cleanup model
                               ├─▶ starts dictation-live
                               └─▶ voxtype record
while you talk:  Voxtype transcribes 20s chunks ─▶ dictation-live cleans finished sentences
key release:     Voxtype transcribes the tail ─▶ dictation-cleanup cleans only what is left
                 ─▶ Voxtype writes the text to RAM ─▶ omavoice-output saves it to history
                 ─▶ omavoice-clipboard pastes it (Shift+Insert) and puts your clipboard back
```

- `bin/dictation-record` wraps `voxtype record` for the Hyprland keys.
- `bin/dictation-live` follows Voxtype's chunk log, rebuilds the transcript exactly as Voxtype stitches it, and cleans each finished sentence in the background.
- `bin/dictation-cleanup` is Voxtype's post-processing command. It merges the live pieces, cleans the rest, and falls back to a full cleanup if anything doesn't line up, so text is never lost.
- `bin/dictation-vram-guard` watches the GPU. When other apps use too much VRAM it unloads the cleanup model and restarts Voxtype on its CPU build, and moves both back once the GPU is quiet for a minute.
- `systemd/voxtype.service.d/override.conf` runs the right Voxtype build and sends its chunk log to RAM.
- `shell/omavoice.overlay` is the recording overlay, an omarchy-shell plugin. While idle it only watches Voxtype's state file. When recording starts it opens a click-through layer surface, reads the microphone's peak level through a separate read-only PipeWire monitor (Voxtype's capture is untouched; behind EasyEffects it meters the hardware mic), and draws one GPU shader at 60 fps. `OverlayModel.js` turns the levels into loudness, a speech gate and syllable rate, and maps the theme's `colors.toml` onto the overlay's color roles by perceived hue (OKLCH), not key names; `shaders/voice.frag` draws them. It watches `~/.local/state/omarchy/current/theme.name`, which Omarchy rewrites on every theme switch, since the switch replaces the whole theme folder. After editing the plugin, run `omarchy restart shell`, since the shell can keep an old copy cached.
- `bin/omavoice-output` (run by `omavoice-output.service`) delivers each dictation. Voxtype runs in file mode, so it never touches the clipboard: it writes the finished text to `$XDG_RUNTIME_DIR/voxtype/omavoice-output.txt` (RAM) and, once per recording, a `.done` sidecar. The service waits on those with inotify, reads and deletes the text, saves it to history once, and pastes it. It also follows Voxtype's state file to time each recording for words per minute. It logs counts only, never text. A dictation found when the service starts late is saved to history but not pasted, since the cursor has moved on.
- `clipboard/omavoice-clipboard.c` does the paste over Wayland's ext-data-control protocol: it snapshots every format of your current clipboard in memory, offers the dictation (marked `x-kde-passwordManagerHint`, so Omarchy's clipboard history and other watchers skip it), sends the paste keys with wtype, waits until the focused app has actually read the text, then puts the snapshot back and keeps serving it until you copy something else. If you copy something while the paste is in flight, yours wins and nothing is restored over it.
- `lib/omavoice_store.py` and `bin/omavoice-store` hold the history, word stats and settings; the app and the service both use them.
- `app/` is the omavoice app, a small Quickshell program (`qs -p app`), and `shell/omavoice.overlay/TraceVisualizer.qml` with `shaders/trace.frag` is the Trace style.
- `bin/omavoice-doctor`, `bin/omavoice-upgrade`, `bin/omavoice-hold` and `hooks/` keep it working across system updates (below).

## Updates without surprises

omavoice depends on details of Voxtype 1.0.1 (its chunk log lines and how it stitches chunks), and on CUDA libraries that system updates also touch. So instead of letting a routine update swap Voxtype underneath you:

- **Voxtype is held back.** The installer adds `voxtype-bin` to pacman's `IgnorePkg`, so `omarchy-update` skips it. An Omarchy `pre-refresh-pacman` hook puts the hold back if `omarchy refresh pacman` rewrites `/etc/pacman.conf`.
- **Every system update is checked.** An Omarchy `post-update` hook runs `omavoice-doctor` in the background after each update. You only get a notification if something broke (for example a cuDNN update that knocks transcription off the GPU) or a new Voxtype is waiting.
- **New Voxtype versions are tested before they are installed.** `omavoice-upgrade` saves the working package, unpacks the new one, runs the checks against its binary, and only installs it if they pass. If the installed version then fails the full check, it rolls back to the saved package on its own. `omavoice-upgrade --rollback` does that by hand.

| Command | What it does |
|---|---|
| `omavoice-doctor` | Checks the chunk log format, transcription of a known clip, GPU acceleration, the running service, the LLM cleanup, live cleanup, the paste path (file mode, omavoice-output, omavoice-clipboard) and the update hold |
| `omavoice-upgrade` | Tests, installs and verifies a new Voxtype, with automatic rollback |
| `omavoice-trace start [N]` | Traces your next N dictations: what the speech model heard, what replacements and cleanup changed (`omavoice-trace show`), and how long each step took after you released the key (`omavoice-trace summary`). `omavoice-trace clear` deletes it all |
| `omavoice-dictionary-review` | Runs every Sunday at 21:45 (`omavoice-dictionary-review.timer`): finds likely mishearings in the last week of history, near misses of your dictionary terms plus names and jargon the local cleanup model flags, and opens a window to approve each one. Approving adds the right spelling to `dictionary.txt` with a `misheard as` hint and, if you choose, an exact word replacement in `config.toml` (validated before saving). Run it any time with `omavoice-dictionary-review run` |
| `omavoice-doctor --fix-mic` | When dictation only produces symbols, the microphone is silent; this points EasyEffects back at a real microphone and restarts it |
| `omavoice-hold [--release]` | Adds or removes the `IgnorePkg` hold |

Even when something does break, dictation keeps working: a CUDA failure falls back to the CPU, a cleanup failure pastes the raw transcript, and a live cleanup mismatch falls back to a full cleanup.

## Privacy

- Audio, transcripts and cleanup never leave the machine. The LLM runs in a local Ollama bound to 127.0.0.1, and screen context is only sent there.
- Voxtype's chunk log, which contains your words, lives in RAM (`$XDG_RUNTIME_DIR`) instead of the on-disk journal, and is emptied at the start of every recording.
- `omavoice-trace` is off unless you start it, and stops by itself after the number of dictations you asked for. Its records hold text only (no audio, no screen context), live in RAM (`$XDG_RUNTIME_DIR/omavoice-trace`, folder 0700, files 0600), and are deleted after 24 hours, on `omavoice-trace clear`, or at logout.
- The recording overlay only ever sees the microphone's peak level, never audio samples, and stores nothing. Its monitor stream exists only while Voxtype is recording.
- History is kept in `~/.local/share/omavoice/history.jsonl` (folder 0700, file 0600), final text only: no audio, no partial chunks. It is pruned to your chosen retention on every dictation and when you change it, and `history = false` stops saving text. Word stats (`stats.json`) hold counts only and stay when you clear history.
- Voxtype's finished text sits in RAM only until omavoice-output reads it, then it is deleted. Your clipboard snapshot during a paste lives in memory only. Neither the service, the helper nor the tests ever log dictation or clipboard content.
- Selected text and clipboard are never read while a password manager has focus, never when the clipboard is marked as a password, and never when the text looks like a key, token, password or card number. Output that repeats 8 or more words of screen text you didn't say is thrown away.

## Tests

```bash
tests/run-cleanup-tests.py   # 27 cleanup cases against the local model, exit 0 on success
tests/live-replay.py         # replays a real 3 minute chunked dictation, times live vs full cleanup
```

Both use a fictional dictionary and a temporary runtime folder, so they don't touch your running setup. They need Ollama running with `gemma4:e4b`.

The recording overlay has its own tests:

```bash
node tests/overlay-model-test.mjs       # signal model and state machine, driven by fake levels
tests/overlay-render-test.sh            # renders the real shader offscreen and checks the pixels follow the level
tests/overlay-render-test.sh --preview  # also writes /tmp/omavoice-animation-preview.png and .mp4
tests/overlay-live-smoke.sh             # inside the running shell: a simulation, then a real voxtype start and cancel
tests/overlay-theme-live-test.sh        # theme hot switching in a throwaway second overlay with a scratch theme folder
```

The render test covers four themes (your current one, Tokyo Night, Gruvbox and Catppuccin Latte) and a dark to light switch in the middle of speech. The theme test never changes your own theme.

Dictation output, history, the dictionary editor and the app:

```bash
tests/review-test.py                    # weekly dictionary review on synthetic data: near misses, filters, ignore list, dictionary and validated config edits
tests/trace-test.py                     # omavoice-trace on a synthetic log: stages, timings, armed count, permissions, expiry, no screen context
tests/store-test.py                     # word counts, history save and dedup, permissions, retention, stats, settings, Voxtype [output] migration
node tests/dictionary-test.mjs          # dictionary editor: byte-exact round trips, one-line edits, sections, what dictation-cleanup reads
tests/clipboard-test.py                 # omavoice-clipboard on the live session: every format restored byte for byte, empty clipboard, no reader, a newer copy wins
tests/output-test.py [--with-window]    # omavoice-output replaying Voxtype's file mode: pasted once, stored once, timed, RAM files removed; --with-window pastes for real into a foot window
tests/overlay-trace-render-test.sh      # the Trace style's pixels in four themes, calm vs wild, processing, a live theme switch; --preview writes /tmp/omavoice-styles-preview.png and .mp4
tests/overlay-style-live-test.sh        # style switching in a throwaway overlay with scratch settings: hidden, on screen, with a theme switch
tests/app-ui-test.py [--shots DIR]      # launches the real app on synthetic data: window, previews, style choice, search, copy, delete, retention, dictionary save, theme switch
tests/real-dictation-test.py            # a real Voxtype dictation of tests/fixtures/check.wav through a temporary virtual mic into a foot window
```

The clipboard tests save your clipboard first and put it back at the end (checked byte for byte), and mark their synthetic clipboards so clipboard history skips them. The app and output tests use synthetic history in scratch folders, never yours. The real dictation test switches your default microphone to a temporary virtual one for about 15 seconds and restores it.

The live smoke test refuses to run while you are dictating. Its real check uses `voxtype record cancel`, which discards the audio, so nothing is transcribed or pasted. The render test needs `g++`, `qt6-declarative`, `ffmpeg` and `python-numpy`.

## Known limitations

- Words right at a 20 second chunk boundary can come out slightly off, for example a name corrected only later in the text, or a numbered list that changes style halfway.
- Voxtype 1.0.1's own `on_demand_loading` must stay off: with it, no chunks are transcribed while you talk.
- Pressing the dictation key during the few seconds the guard restarts Voxtype does nothing; press again.
- Tested on an NVIDIA desktop only. The laptop and CPU numbers above are estimates.
- Clipboard restore limits: the restored clipboard is a copy served by `omavoice-clipboard`, not the app you copied from. Formats an app only produces slowly (more than 0.6 s each, 1.5 s in total) or anything past 64MB are left out, which omavoice-output logs as a count. A password manager that clears its clipboard after a timeout may no longer be the owner and so may not clear it. The primary selection (middle click) is never touched.
- The paste waits up to 2 seconds for the focused app to read the text. An app that reads it later than that gets your old clipboard instead; the dictation is still in history. When nothing reads it at all (no text box focused) you get a notification pointing to the history (`notify_unpasted = false` turns that off).
- Like Voxtype's own paste here, there is no check for modifier keys still held when the paste is sent (that needs the `input` group). Let go of Super and Alt quickly after stopping.
- Without the ext-data-control Wayland protocol (Hyprland has it), omavoice-output types the text with wtype instead, which never touches the clipboard but types newlines as Enter.

## Credits

Built on [Voxtype](https://github.com/peteonrails/voxtype), [Cohere Transcribe](https://huggingface.co/onnx-community/cohere-transcribe-03-2026-ONNX), [Ollama](https://ollama.com) and Google's Gemma 4, for [Omarchy](https://omarchy.org).

## License

MIT
