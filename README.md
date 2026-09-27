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
| Output | Types the text character by character | Pastes the whole text at once and keeps it on the clipboard |

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
4. Symlinks the scripts into `~/.local/bin` and the service files into `~/.config/systemd/user`, so `git pull` updates them.
5. Creates your config files only if they are missing. A stock Voxtype config is moved to `config.toml.before-omavoice`.
6. Prints the Hyprland key bindings to paste into `~/.config/hypr/bindings.lua` (also in `hyprland/bindings.lua`).

## Use

- **Tap Super + Alt** to start, tap again to stop. The text is pasted where your cursor is.
- **Hold F9** to talk, release to paste.
- **Super + Ctrl + X** toggles, like Omarchy's default.

Say "new line", "new paragraph" or "bullet point" for layout. Correct yourself mid-sentence with "no wait", "I mean" or "scratch that".

## Configuration

Everything lives in `~/.config/voxtype/`:

| File | What it's for |
|---|---|
| `dictionary.txt` | Names, products and jargon, one per line. Add `term \| hint`, for example `Aoife \| coworker, misheard as "eefa"`; a "misheard as" hint also becomes a worked example for the model |
| `app-styles.toml` | Per-app cleanup styles, matched on the window class or title |
| `omavoice.toml` | Your first name and whether cleanup is on |
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
                 ─▶ joined text is pasted (Shift+Insert) and stays on the clipboard
```

- `bin/dictation-record` wraps `voxtype record` for the Hyprland keys.
- `bin/dictation-live` follows Voxtype's chunk log, rebuilds the transcript exactly as Voxtype stitches it, and cleans each finished sentence in the background.
- `bin/dictation-cleanup` is Voxtype's post-processing command. It merges the live pieces, cleans the rest, and falls back to a full cleanup if anything doesn't line up, so text is never lost.
- `bin/dictation-vram-guard` watches the GPU. When other apps use too much VRAM it unloads the cleanup model and restarts Voxtype on its CPU build, and moves both back once the GPU is quiet for a minute.
- `systemd/voxtype.service.d/override.conf` runs the right Voxtype build and sends its chunk log to RAM.

## Privacy

- Audio, transcripts and cleanup never leave the machine. The LLM runs in a local Ollama bound to 127.0.0.1, and screen context is only sent there.
- Voxtype's chunk log, which contains your words, lives in RAM (`$XDG_RUNTIME_DIR`) instead of the on-disk journal, and is emptied at the start of every recording.
- Selected text and clipboard are never read while a password manager has focus, never when the clipboard is marked as a password, and never when the text looks like a key, token, password or card number. Output that repeats 8 or more words of screen text you didn't say is thrown away.

## Tests

```bash
tests/run-cleanup-tests.py   # 27 cleanup cases against the local model, exit 0 on success
tests/live-replay.py         # replays a real 3 minute chunked dictation, times live vs full cleanup
```

Both use a fictional dictionary and a temporary runtime folder, so they don't touch your running setup. They need Ollama running with `gemma4:e4b`.

## Known limitations

- Words right at a 20 second chunk boundary can come out slightly off, for example a name corrected only later in the text, or a numbered list that changes style halfway.
- Voxtype 1.0.1's own `on_demand_loading` must stay off: with it, no chunks are transcribed while you talk.
- Pressing the dictation key during the few seconds the guard restarts Voxtype does nothing; press again.
- Tested on an NVIDIA desktop only. The laptop and CPU numbers above are estimates.

## Credits

Built on [Voxtype](https://github.com/peteonrails/voxtype), [Cohere Transcribe](https://huggingface.co/onnx-community/cohere-transcribe-03-2026-ONNX), [Ollama](https://ollama.com) and Google's Gemma 4, for [Omarchy](https://omarchy.org).

## License

MIT
