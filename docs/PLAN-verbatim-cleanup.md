# Plan: Wispr Flow style verbatim cleanup

Status: proposed, not implemented. Written 2026-09-30 from two planning rounds
with Codex (diagnosis, then a revision after review by Claude).

## Goal

1. Keep the speaker's exact words. Only punctuation, capitalization, approved
   dictionary spellings, true fillers, and abandoned corrections may change.
2. When the speaker backs up and restates ("Tuesday, actually no, Wednesday",
   or a restart with no cue word), keep only the final version.

## Core idea

The cleanup model stops writing text. It receives the transcript as numbered
words and returns a JSON edit object (spans to drop, sparse casing and
punctuation, and spelling swaps chosen from precomputed dictionary
candidates). The host validates it and rebuilds the output from the original
words, so the model cannot paraphrase, invent words, or reorder anything.
Invalid JSON means the untouched input is pasted.

## Reviewer note (Claude): keep long dictations fast

A whole-session pass at release could take seconds for 1,500 words. The
numbered word list only ever grows while you talk, so the prompt prefix is
stable: run the edit pass on the growing transcript during recording (as
dictation-live does today) and let Ollama's prompt cache make each call pay
only for the new words. At release, one more pass sees the whole session and
can still drop words from any earlier sentence. Verify cache reuse with
prompt_eval_count before relying on it.

---

## Point-by-point response

### 1. Make structured edits Priority 1

**Agreed, after the diagnostic baseline.** Replace free-form transcription generation with validated edit instructions.

The guarantee needs precise wording: reconstruction prevents invented wording and reordering. Incorrect deletions, spelling substitutions, or punctuation can still change meaning. Those require semantic tests.

Currently, the model generates unrestricted text, and the guard mainly checks character length (`bin/dictation-cleanup:261-302`). That is the wrong enforcement boundary for verbatim fidelity.

**Proposed response format**

```json
{
  "drop": [[2, 5]],
  "case": [[0, 1]],
  "after": [[5, 2]],
  "swap": []
}
```

Definitions:

- `drop`: zero-based, half-open source-word intervals `[start,end)`.
- `case`: `[word_index,operation]`. Operations: `1` uppercase first letter, `2` lowercase first letter, `3` uppercase word, `4` lowercase word.
- `after`: `[word_index,punctuation_code]`. Codes: `0` remove existing trailing punctuation, `1` comma, `2` period, `3` question mark, `4` exclamation mark, `5` colon, `6` semicolon.
- `swap`: IDs of precomputed spelling candidates. Each candidate already binds a source interval to an approved dictionary spelling. The model cannot supply replacement strings.

For example, candidate `0` might mean source words `[4,6)` containing “hub spot” become the dictionary entry “HubSpot”. Restrict initial candidates to explicit aliases and approved ASR spelling corrections. Arbitrary substitution with any dictionary entry would weaken the guarantee.

**Numbered input**

```text
<words>
0:"let's" 1:"meet" 2:"Tuesday," 3:"actually" 4:"no," 5:"Wednesday"
</words>
```

Use JSON-escaped surface words, preserving existing punctuation. Keep byte offsets, whitespace, and punctuation decomposition in the host tokenizer. Protect internal apostrophes, decimals, paths, and identifiers. Indices always refer to the original input, never to the already edited result.

Operations are sparse: an omitted word retains its original spelling, casing, and punctuation. The renderer resolves whitespace after deletions. Existing spoken-layout commands need a separate validated command-to-layout operation, with literal uses preserved; those features currently originate in `bin/dictation-cleanup:46` and `tests/cleanup-cases.json:164-198`.

**Reliable generation**

At `bin/dictation-cleanup:261-268`:

- Supply an actual JSON Schema through Ollama’s `format` field.
- Require all four keys and reject additional properties.
- Define span and formatting entries as exactly two nonnegative integers. Define swaps as integer candidate IDs.
- Include the compact contract and examples in the prompt.
- Retain `temperature=0`, `think=false`, and `stream=false`.

Ollama documents schema-constrained output and recommends grounding the schema in the prompt. This supports the proposed local E4B/Qwen comparison, but their accuracy at selecting indices remains untested. [Ollama structured outputs](https://docs.ollama.com/capabilities/structured-outputs)

Validate independently after parsing:

- Bounds, interval ordering, overlap, operation codes, candidate IDs.
- Formatting targets survive deletion.
- Swaps and deletions do not overlap.
- Protected identifiers receive only permitted transformations.
- Completion finished normally rather than hitting its token limit.

A schema establishes structure, not correct repair decisions.

**Invalid-output policy:** reject the entire edit set and return the untouched cleanup input. Record a count-only failure reason. Do not repair malformed JSON heuristically or retry with free-form generation. This replaces the permissive guard at `bin/dictation-cleanup:285-302`.

Valid empty edits mean “preserve everything”. Valid deletion of a filler-only transcript may produce empty output.

**Latency correction:** sparse indices can reduce output tokens substantially, but not universally. A formatting instruction for every word could exceed the original transcript’s token count. Sparse overrides are essential.

### 2. Add Step 0: opt-in attribution tracing

Agreed. We cannot attribute the complaint to the LLM until we compare stages.

Propose `bin/dictation-trace start 10`, capturing the next ten completed dictations into a private directory under `$XDG_RUNTIME_DIR/voxtype/trace/`.

Each record contains:

- Session ID and monotonic timestamps.
- Raw ASR chunk results and tail result.
- Reconstructed pre-replacement transcript, explicitly labeled as reconstructed.
- Exact cleanup stdin, representing the post-replacement stage.
- Final cleanup output.
- Model/prompt identifiers, timings, and failure flags.

Cleanup input and output are available at `bin/dictation-cleanup:455-483`. Chunk capture already exists at `bin/dictation-live:148-161`. The repository checks for a `Tail transcription:` binary marker, but does not establish that complete raw text is observable for every short-dictation path (`bin/omavoice-doctor:38-39`, `bin/omavoice-doctor:80-89`).

**First prove capture completeness.** Missing raw stages must be marked unavailable, never substituted with cleanup stdin. If Voxtype does not expose a short recording’s pre-replacement result, obtaining it requires a Voxtype instrumentation hook. Its source location is not verified in this repository.

Privacy requirements:

- Explicit opt-in, bounded count, byte cap, expiry, and explicit clear command.
- Verified runtime tmpfs, directory mode 0700, files 0600; refuse a disk-backed `/tmp` fallback.
- No audio, clipboard contents, screen context, prompts, or dictionary contents captured.
- No transcript output to the journal or persistent debug log.
- Review locally in a transient viewer; purge on clear, expiry, and stale-session cleanup.
- Keep this diagnostic separate from ordinary final-text history.

The service already routes transcript logs into the runtime directory (`systemd/voxtype.service.d/override.conf:18-23`), matching `README.md:158-162`.

Do **not** enable `DICTATION_DEBUG`: it writes text to persistent storage through `bin/dictation-cleanup:35`, `bin/dictation-cleanup:105-109`, and `bin/dictation-cleanup:480-481`.

The user should review stage-by-stage word diffs. For reliable ASR attribution, include several known read-aloud references; text-stage comparisons alone cannot establish what was actually spoken.

### 3. Whole-session editing can replace the revisable suffix

**For correctness, yes.** A final edit plan over the entire source transcript can delete words from any earlier sentence. The revisable suffix is unnecessary if that full pass always runs.

Current append-only merging prevents this at `bin/dictation-live:176-179` and `bin/dictation-cleanup:426-443`.

**For latency, the answer remains conditional.** Numbering every word increases prefill work. Fewer generated tokens do not eliminate that cost.

Illustrative E4B sizing calculation for the documented RTX 5080 class of machine (`README.md:43`):

- Assume 4 to 6 model tokens per numbered word, plus 1,000 tokens of fixed instructions/examples.
- Assume prefill throughput of 2,000 to 6,000 tokens/second.
- Assume generation throughput of 100 to 250 tokens/second.

These are deliberately unmeasured planning assumptions, not benchmark claims.

For **300 words**:

- Input: approximately 2,200 to 2,800 tokens.
- Prefill: approximately 0.37 to 1.4 seconds.
- An 80-token sparse edit response adds 0.32 to 0.8 seconds.
- Regenerating approximately 400 transcript tokens adds 1.6 to 4 seconds instead.

For **1,500 words**:

- Input: approximately 7,000 to 10,000 tokens.
- Prefill: approximately 1.2 to 5 seconds.
- A 300-token edit response adds 1.2 to 3 seconds.
- Regenerating approximately 2,000 transcript tokens adds 8 to 20 seconds instead.

ASR, queuing, dictionary size, and delivery are additional. Formatting-heavy transcripts can exceed those edit-response assumptions. The current 8192-token context can also be insufficient at 1,500 numbered words (`bin/dictation-cleanup:267`).

**Recommendation:**

1. Make one whole-session structured pass the initial implementation.
2. Retain eager ASR. Disabling speculative LLM cleanup does not mean disabling Voxtype’s 20-second transcription chunks (`config/config.toml:37-42`).
3. Target short dictations below one second end to end. Propose long-dictation p95 targets of three seconds at 300 words and five seconds at 1,500 words, subject to measurement and user acceptance.
4. Remove live LLM cleanup only after those targets pass.
5. If necessary, repurpose live processing to maintain speculative edit proposals or warm a stable prompt prefix. Earlier deletions remain reversible.

A cache of proposed spans does **not** itself save whole-session prefill. KV reuse needs identical prompt prefixes and actual cache support. Do not claim the cache solves latency until `prompt_eval_cached_count` and timing measurements prove it. Those fields are available in Ollama’s [chat API](https://docs.ollama.com/api/chat).

### 4. Concrete cue-less-restart prompt and eight examples

Replace the explicit-marker requirement at `bin/dictation-cleanup:44` and the free-text examples at `bin/dictation-cleanup:53-67` with:

> Goal: Identify the smallest edits that preserve the speaker's final wording.
>
> Success means returning a valid edit object whose surviving words retain their original order and wording.
>
> Stop after the JSON object.
>
> Use the supplied zero-based word indices and half-open deletion intervals.
>
> Remove hesitation sounds and phrases serving solely as fillers.
>
> For explicit corrections, delete the abandoned words and correction phrase. Keep the surrounding request and the final replacement.
>
> For cue-less restarts, identify an interrupted construction immediately replaced by a fresh construction serving the same local purpose. Delete only the abandoned construction.
>
> Treat ASR punctuation as evidence, not proof that a thought was complete.
>
> Preserve independent statements before a restart.
>
> Preserve emphasis, meaningful hedges, parallel requests, and intentional repetition. Preserve both passages when abandonment is ambiguous.
>
> Use sparse casing and punctuation operations. Select spelling swaps only from the supplied candidates.

The following examples use the format defined above.

**1. Explicit date correction**

```text
0:"let's" 1:"meet" 2:"Tuesday," 3:"actually" 4:"no," 5:"Wednesday"
```

```json
{"drop":[[2,5]],"case":[[0,1]],"after":[[5,2]],"swap":[]}
```

Result: “Let's meet Wednesday.”

**2. Preserve the carrier phrase**

```text
0:"send" 1:"it" 2:"to" 3:"Mark," 4:"sorry," 5:"to" 6:"Mike"
```

```json
{"drop":[[3,6]],"case":[[0,1]],"after":[[6,2]],"swap":[]}
```

Result: “Send it to Mike.”

**3. Cue-less restart with different phrasing**

```text
0:"I" 1:"wanted" 2:"to" 3:"ask" 4:"if" 5:"could" 6:"you" 7:"send" 8:"the" 9:"draft"
```

```json
{"drop":[[0,5]],"case":[[5,1]],"after":[[9,3]],"swap":[]}
```

Result: “Could you send the draft?”

**4. Repeated unfinished construction**

```text
0:"please" 1:"open" 2:"the" 3:"please" 4:"open" 5:"the" 6:"latest" 7:"report"
```

```json
{"drop":[[0,3]],"case":[[3,1]],"after":[[7,2]],"swap":[]}
```

Result: “Please open the latest report.”

**5. Preserve independent content before the restart**

```text
0:"Keep" 1:"the" 2:"attachment." 3:"Um" 4:"I" 5:"wanted" 6:"to" 7:"could" 8:"you" 9:"resend" 10:"the" 11:"email"
```

```json
{"drop":[[3,7]],"case":[[7,1]],"after":[[11,3]],"swap":[]}
```

Result: “Keep the attachment. Could you resend the email?”

**6. Intentional emphasis**

```text
0:"This" 1:"is" 2:"really," 3:"really" 4:"useful."
```

```json
{"drop":[],"case":[],"after":[],"swap":[]}
```

**7. Distinct parallel requests**

```text
0:"Send" 1:"it" 2:"to" 3:"Mark." 4:"Send" 5:"it" 6:"to" 7:"Mike" 8:"too."
```

```json
{"drop":[],"case":[],"after":[],"swap":[]}
```

**8. Meaningful approximation and hedge**

```text
0:"We" 1:"need" 2:"like" 3:"eight" 4:"chairs," 5:"and" 6:"I" 7:"kind" 8:"of" 9:"like" 10:"this."
```

```json
{"drop":[],"case":[],"after":[],"swap":[]}
```

These last examples directly counter the broad deletion behavior currently taught at `bin/dictation-cleanup:66`.

### 5. Codebase grounding

The revised architecture replaces three existing mechanisms:

- Free-text generation and length guards: `bin/dictation-cleanup:226-302`.
- Independently cleaned pieces and append-only merging: `bin/dictation-cleanup:332-352`, `bin/dictation-cleanup:402-443`.
- Substring and word-count acceptance: `tests/run-cleanup-tests.py:55-60`, `tests/live-replay.py:90-93`.

The final paste path can remain unchanged. This is an editing-contract change before delivery.

## Revised ranked implementation plan

Effort estimates are focused engineering time, excluding GPU evaluation runs. All changes below are proposed only.

**0. Establish where wording changes originate. Effort: 1 day, plus an upstream dependency if raw capture is incomplete.**

- **Files:** new `bin/dictation-trace`, `bin/dictation-record`, `bin/dictation-cleanup`, `README.md`; extend log parsing from `bin/dictation-live`.
- **Change:** bounded, opt-in RAM capture of raw ASR, post-replacement input, and final output.
- **Proof:** synthetic sessions verify stage attribution, exactly N captures, private permissions, expiry, no persistent transcript writes, and explicit missing-stage reporting. Manually review ten real dictations before changing policy.

**1. Implement the structured edit boundary. Effort: 2 to 3 days.**

- **Files:** new `lib/dictation_edits.py`, `bin/dictation-cleanup`, new `tests/edit-contract-test.py`.
- **Change:** numbered source tokens, JSON Schema, independent validator, deterministic renderer, approved spelling candidates, untouched-input failure policy. Replace `bin/dictation-cleanup:261-302`.
- **Proof:** generated edit sets cannot insert unrestricted words or reorder source words. Tests cover malformed JSON, out-of-range indices, conflicting edits, invalid swaps, truncation, identifiers, and legitimate empty output.

**2. Train the prompt through examples and exact-output regressions. Effort: 1 day.**

- **Files:** `bin/dictation-cleanup`, `config/app-styles.toml`, `tests/cleanup-cases.json`, `tests/run-cleanup-tests.py`.
- **Change:** use the restart rules above; restrict app styles to formatting; add exact expected transcripts and protected spans.
- **Proof:** zero lexical errors on curated cases across every app style. Separately score held-out cue-less repair accuracy and intentional-repetition deletion rate. Include harmful-but-schema-valid deletion tests.

**3. Evaluate one whole-session pass. Effort: 1 to 2 days.**

- **Files:** `bin/dictation-cleanup`, `bin/dictation-record`, `bin/dictation-live`, `tests/live-replay.py`.
- **Change:** replace piecewise text merging with one final edit plan; retain eager ASR and model warming. Keep live LLM work disabled in the evaluation arm.
- **Proof:** cross-sentence corrections produce identical results across chunk partitions. Benchmark 30, 300, and 1,500 words with E4B, Qwen3 4B, and Qwen3 8B, one cleanup model resident at a time alongside Voxtype. Measure prefill, decode, peak VRAM, and context overflow.

**4. Decide whether speculative live work earns its complexity. Effort: half a day for the decision; 1 to 2 additional days if caching is needed.**

- **Files:** `bin/dictation-live`, `bin/dictation-cleanup`, `tests/live-replay.py`, `tests/real-dictation-test.py`, `README.md`, `DECISIONS.md`.
- **Change:** remove live LLM cleanup if whole-session processing meets the targets. Otherwise retain reversible edit proposals and demonstrated prefix-cache reuse.
- **Proof:** warm short-dictation p95 below one second from stop request to complete application receipt; proposed long targets of three seconds at 300 words and five seconds at 1,500 words. Measure immediately on receipt, excluding the verification sleep at `tests/real-dictation-test.py:89-96`. A cache is accepted only if it improves those measurements without changing exact output.


---

# Appendix: round 1 diagnosis (Codex)

# 1. Diagnosis

Scope: planning only for /home/kapusta/Projects/omavoice. Runtime configuration and installed model weights were not inspected; repository defaults and the user's deployment description are the basis of this plan. Performance figures below are targets or existing documented results, not new measurements.

**Prompt conflicts explain both requested failure modes.**

- The prompt preserves intended facts and vocabulary, but also permits grammar fixes with word changes. That allows grammatical rewriting beyond punctuation and ASR repair. See `bin/dictation-cleanup:39-45`.
- Cue-less repairs are explicitly blocked: the prompt retains repeated words unless an explicit spoken correction marker replaces them. Its correction examples cover cue words, not abandoned clauses without cues. See `bin/dictation-cleanup:44`, `bin/dictation-cleanup:53-67`.
- The example containing “kind of need to” produces “need to”, teaching deletion of a possible hedge. “Like eight chairs” also loses a possible approximation. Those are ambiguous deletions, not reliably true fillers. See `bin/dictation-cleanup:66`. The test requiring removal of “like eight” reinforces this policy (`tests/cleanup-cases.json:30-40`).
- Chat style requests contractions and short sentences, which can change phrasing or sentence structure. Email style adds paragraph organization. Styles are supplied to the model without a precise lexical-preservation priority. See `config/app-styles.toml:13-19`, `bin/dictation-cleanup:244-245`.
- Dictionary correction permits shortened forms to become full dictionary entries, potentially expanding an intentionally short name. The dynamically generated name example only supports explicit correction. See `bin/dictation-cleanup:45`, `bin/dictation-cleanup:195-207`.

**Decoding is already conservative; the guard does not establish fidelity.**

- The default is `gemma4:e4b`, with temperature 0, thinking disabled, an 8192-token context, and a character-based output-token limit. Top-p, top-k, seed, and repetition penalty are unspecified by this request. A lower temperature is therefore not the primary fix. See `bin/dictation-cleanup:27`, `bin/dictation-cleanup:261-273`.
- The guard accepts outputs down to 30% of input character length and up to 150% plus 40 characters. It can accept substantial omissions or paraphrases and reject a legitimate correction that discards most of a long false start. It also rejects every empty result, including a potentially valid filler-only result. See `bin/dictation-cleanup:285-302`.
- The response handler retains only text, losing completion and timing metadata. It cannot distinguish a normal completion from token-limit truncation there. See `bin/dictation-cleanup:267-273`.
- One- and two-word inputs bypass cleanup entirely, so “um hello” remains unchanged through this entry point. See `bin/dictation-cleanup:455-465`.
- Existing comments document a long-pass omission; texts over 150 words use approximately 80-word pieces extended to sentence ends. This is evidence of a known issue, not proof that E4B alone causes the current failures. See `bin/dictation-cleanup:332-352`, `bin/dictation-cleanup:477-478`.

**Live processing treats earlier text as final too early.**

- Cohere fp16, resident loading, and 20-second eager chunks are configured in `config/config.toml:25-42`. The helper reconstructs chunk text and uses terminal punctuation to select a prefix for cleanup. It withholds the remaining tail, but provides no semantic correction horizon. See `bin/dictation-live:153-178`.
- Cleaned segments are appended. Later calls receive only the last 400 characters of earlier cleaned text as context. Continuation instructions confine output to the new transcript, so the model has no way to replace earlier segment text. See `bin/dictation-live:176-179`, `bin/dictation-cleanup:249-256`.
- At release, `live_merge()` preserves cached pieces and cleans only the remainder. `join_pieces()` inserts separators; it does not reconcile corrections. Thus “Let's meet Tuesday.” followed later by “Actually no, Wednesday.” cannot reliably remove Tuesday from the earlier piece. See `bin/dictation-cleanup:305-329`, `bin/dictation-cleanup:426-443`. The non-live piece path has the same structural limitation (`bin/dictation-cleanup:348-352`).
- These segments are emitted to RAM state, not pasted into the application. Final output is read after the completion sidecar and pasted once. Therefore this task can revise cached text before delivery without editing the target app. See `bin/dictation-live:94-98`, `bin/dictation-live:178-182`, `bin/omavoice-output:131-175`.
- Two separate seam heuristics exist. The Voxtype-compatible stitcher removes exact case-insensitive suffix/prefix overlap; the additional heuristic ignores punctuation for up to six words and removes those words from LLM input. Neither identifies speaker intent. Intentional repetition at a boundary can therefore be mistaken for overlap. See `bin/dictation-live:61-84`, `bin/dictation-live:155-173`.

**Replacement order and test coverage leave gaps.**

- Repository replacements are unconditional whole-word spelling mappings, including “air table” to “Airtable”. Such mappings can change literal speech before cleanup sees it. See `config/config.toml:69-82`.
- Live cleanup uses chunk-log text before final replacements. At merge time, replacements are applied to the cached raw prefix for matching, not to the cached cleaned output. A name split across pieces can therefore behave differently in live and full cleanup. See `bin/dictation-live:153-178`, `bin/dictation-cleanup:359-365`, `bin/dictation-cleanup:429-440`.
- Prefix matching discards punctuation and word boundaries; it is weaker than exact token correspondence. See `bin/dictation-cleanup:355-382`.
- Cleanup tests check selected substrings, not the complete expected transcript. The correction case could lose the scheduling request while still passing. See `tests/run-cleanup-tests.py:55-60`, `tests/cleanup-cases.json:65-75`. The listed correction cases use explicit cues (`tests/cleanup-cases.json:65-101`).
- Live replay builds its reference transcript with the same deduplication function under test and passes based on retaining over 90% of word count. This neither independently verifies stitching nor detects incorrect wording. See `tests/live-replay.py:31-42`, `tests/live-replay.py:85-93`.
- Replay times only the final cleanup subprocess after supplying an already transcribed string. Its “release” label excludes tail ASR and paste delivery. See `tests/live-replay.py:64-76`, `tests/live-replay.py:89`. Cleanup can also wait four seconds for a busy live worker, exceeding the target by itself (`bin/dictation-cleanup:415-423`).

# 2. Proposed changes, ranked by impact and effort

**Priority 1: define the exact edit contract and strengthen the fixtures. High impact, low effort.**

Make verbatim wording the invariant across every app. Permit only punctuation, capitalization, proven spelling aliases, true filler deletion, and deletion of abandoned correction spans. Preserve grammar, contractions, hedges, negation, numbers, word order, and sentence structure wherever speech supplies them.

Replace the prompt and contradictory examples at `bin/dictation-cleanup:39-67`. Use this compact core:

> Goal: Return the speaker's final intended wording as a minimally edited transcript.
>
> Success means preserving the exact surviving words, their order, phrasing, contractions, qualifiers, and grammatical structure.
>
> Stop after returning only the transcript in plain text.
>
> Copy speech directly, applying punctuation, capitalization, and unambiguous ASR or dictionary spelling repairs.
>
> Remove hesitation sounds and phrases functioning solely as fillers. Preserve meaningful uses of like, you know, I mean, basically, kind of, and sort of, including approximations and hedges.
>
> Resolve a self-correction by deleting the abandoned span and its correction cue, then retaining the speaker's final replacement words. Preserve the surrounding request or sentence.
>
> Recognize a cue-less restart when an interrupted construction is immediately replaced by a new construction serving the same local purpose. Keep the replacement exactly as spoken, along with independent content outside the abandoned construction.
>
> Preserve deliberate repetition, emphasis, parallel statements, and distinct requests. Preserve both passages when the text does not establish abandonment.
>
> Use dictionary and screen context for supported spellings. Keep intentional short names and the transcript's own content.
>
> Apply app formatting through punctuation and whitespace. Preserve dictated layout commands according to the existing layout rules and examples.

Keep transcript-as-data handling, spelling context protections, and spoken-layout examples from `bin/dictation-cleanup:43-48`, `bin/dictation-cleanup:231-242`. Change chat guidance to preserve spoken contractions exactly. Keep email layout only where it changes whitespace or punctuation, with explicit spoken layout taking precedence.

Replace broad filler examples with contrastive few-shots:

- “um I kinda want to leave it alone” → “I kinda want to leave it alone.”
- “I like this and you know the reason” → “I like this, and you know the reason.”
- “we need like eight chairs” → “We need like eight chairs.”
- “let's meet Tuesday actually no Wednesday” → “Let's meet Wednesday.”
- “send it to Mark sorry to Mike” → “Send it to Mike.”
- “I was going to ask if can you send the file tonight” → “Can you send the file tonight?”
- “the thing I wanted to can you open the draft” → “Can you open the draft?”
- “please send the please send the revised file” → “Please send the revised file.”
- “this is really really useful” → “This is really, really useful.”
- “send it to Mark send it to Mike too” → “Send it to Mark. Send it to Mike too.”

These examples distinguish abandoned syntax from intact parallel content. Keep evaluation paraphrases separate from the prompt examples.

**Priority 2: add revisable live segments. High impact, medium effort.**

Replace append-only behavior around `bin/dictation-live:164-182` and `bin/dictation-cleanup:426-443` with a shared revision path:

1. Retain immutable raw tokens with source offsets, chunk IDs, and a session generation. Cache each cleaned segment against its covered raw interval.
2. Keep the last two clauses or sentences as a revisable suffix, initially targeting about 60 to 100 raw words. Treat this size as a tuning hypothesis, not a correctness guarantee.
3. When new speech arrives, clean the raw revisable suffix plus the new text together. Supply earlier text as read-only context. Replace the cached outputs covering that interval; append-only merging would duplicate the correction.
4. At release, reconcile the retained raw suffix with the final tail in one call. For “Let's meet Tuesday.” plus “Actually no, Wednesday.”, replace both contributions with “Let's meet Wednesday.”
5. Invalidate from an earlier raw interval if a clear correction refers farther back. Retain all session raw text until final paste so this remains possible. Long-distance repair may exceed the normal latency budget and needs an explicit product policy.
6. Serialize live and final cleanup ownership. Use an acknowledged stop or generation check so a stale worker cannot publish over final state. Budget waiting explicitly instead of retaining the unconditional four-second allowance.
7. Use the same revision mechanism in `clean_in_pieces()`, so crossing the 150-word threshold does not change correction semantics.

Sentence segmentation must handle abbreviations, decimals, and quoted punctuation. An unfinished clause should remain revisable across an ASR-inserted period. For very long punctuation-free speech, allow bounded provisional windows with retained raw context; do not assume punctuation will arrive promptly.

Keep the final single-paste design. If “already emitted” means text pasted during an earlier recording, automatic repair would require target-app range ownership and focus verification. Recommend limiting this change to the current recording.

**Priority 3: use deterministic logic for evidence and validation. High impact, medium effort.**

Add a shared preprocessing/alignment function near `guarded_clean()` and call it from both full and live paths.

- Apply curated unambiguous spelling aliases consistently in both paths while retaining original-to-normalized token mappings. Match aliases across chunk boundaries. Treat Voxtype's final replacement output as an input that may already be normalized.
- Review collision-prone replacements such as “air table”. Recommend keeping only unambiguous aliases in Voxtype and using contextual dictionary hints for ambiguous names. The live helper and final path must consume the same replacement contract, not independently evolving rules.
- Use repeated n-grams and cue words to propose repair spans. Do not globally delete repeated n-grams: “very very”, repeated instructions, and parallel requests are real content.
- A narrowly tested template such as “meet Tuesday, actually no, Wednesday” may be deterministic. General cue scope, cue-less restarts, and the distinction between “sorry” as apology or repair should remain contextual decisions.
- Keep Voxtype-compatible stitching separate from speech repair. Disable unconditional punctuation-insensitive seam deletion unless overlap provenance supports it. If Voxtype itself already removed intentional words, downstream cleanup cannot recover them reliably; upstream audio or timing evidence is required.

After LLM cleanup, align source and output tokens. Reject unsupported lexical insertions, substitutions, and reorderings; allow explicit spelling mappings and layout rendering. Track deletions by filler or proposed repair span, rather than accepting every shorter string.

Replace the blanket 30% floor with edit-aware validation. A justified full-clause abandonment can remove over 70% of input; unexplained deletion cannot. Preserve independent qualifiers and requests outside the repair.

Token alignment alone cannot prove intent. If plain-text output cannot support trustworthy deletion decisions, evaluate one-call structured edits containing source ranges and reason categories. Validate ranges mechanically and reconstruct output from source words plus approved spelling and punctuation changes. This adds implementation and token cost, so benchmark it as a separate variant rather than adding a second inference call.

Distinguish valid empty output from failure, including filler-only input. Keep a fast short-input path for unchanged words and unambiguous dictionary aliases, but handle “um hello” correctly. Never report an unedited error return as successful cleanup.

**Priority 4: pin decoding and measure before changing models. Medium impact, low effort.**

At `bin/dictation-cleanup:261-273`, retain temperature 0 and thinking disabled. Explicitly benchmark:

- `temperature=0`, `top_k=1`, `top_p=1`, `min_p=0`.
- `repeat_penalty=1.0`, `repeat_last_n=0`, fixed seed for reproducibility.
- Initially retain `num_ctx=8192`. Try 4096 only after measuring prompt, dictionary, context, revision-window, and output token requirements.
- Keep an output allowance sufficient for near-verbatim copying. Check completion reason and token usage so truncation cannot silently pass a length guard.
- Retain model warming, but use one model selection across the recorder, live helper, and cleanup. Current warmup selects its own default at `bin/dictation-record:8-18`.

These settings make a reproducible greedy baseline. They do not solve an incorrect edit policy. In a greedy configuration, top-p is not a useful creativity dial. Disabling repetition penalties protects spoken repetition. Ollama documents these controls in its [parameter reference](https://docs.ollama.com/modelfile).

For each alternative model, verify its supported thinking control and template before comparison. Ollama exposes thinking capability and response timing/completion fields through its APIs. See [chat API](https://docs.ollama.com/api/chat). Treat model-specific recommended sampling as a separate experimental arm if greedy decoding fails, not an automatic production change.

**Priority 5: compare local models under the shared GPU budget. Potentially useful, medium evaluation effort.**

The repository reports a 4.4GB resident transcription footprint and an approximately 9GB cleanup download (`README.md:20`, `README.md:67`). On a 16GB GPU, 11.6GB is only a rough remaining capacity before desktop use, KV cache, temporary buffers, and ASR peaks. Reserve at least 1.5 to 2GB initially, then replace that estimate with measured peak usage. Download size is not VRAM consumption.

Candidate order:

1. **Installed Gemma 4 E4B:** baseline after prompt and live fixes. Record its exact digest and quantization. Current Ollama listings span approximately 6.6 to 9.5GB across implementations, so the installed tag cannot be inferred from today's registry. See [Gemma 4](https://ollama.com/library/gemma4).
2. **Qwen3 4B and 8B, quantized, with thinking disabled:** approximately 2.5GB and 5.2GB downloads. Both are plausible candidates with more memory headroom; 8B is the first capacity challenger. This is a fit estimate, not a claim of better cleanup. See [Qwen3 models](https://ollama.com/library/qwen3).
3. **Gemma 4 E2B:** approximately 4.6 to 7.5GB listed downloads across implementations. Test as a speed candidate; expect any accuracy tradeoff to be determined by restart fixtures. See [Gemma 4 models](https://ollama.com/library/gemma4).
4. **Llama 3.2 3B Instruct:** approximately 2GB download, useful as a small-model control. Its task accuracy remains unmeasured. See [Llama 3.2](https://ollama.com/library/llama3.2).
5. **Gemma 4 12B:** approximately 7.7 to 8GB listed downloads; a conditional larger-model challenger if measured residency fits. Gemma 4 26B and 31B listed downloads start around 16GB and 19GB, so exclude them from the fully GPU-resident shared setup. See [Gemma 4 models](https://ollama.com/library/gemma4).

Pin exact artifacts and Ollama version; test one cleanup model resident alongside Voxtype. Require full GPU residency without paging and stable ASR latency.

Recommendation: a larger model is worthwhile only if it improves held-out cue-less repair substantially, preserves all fidelity guard cases, and keeps release-to-text below the budget. As an initial selection rule, require at least a five-percentage-point increase in cue-less exact-match accuracy with no new content corruption. Treat that threshold as a proposed decision criterion. Neither parameter count nor general reasoning benchmarks establish dictation quality.

# 3. Evaluation plan

**Extend the cleanup cases and scoring harness first.**

Add `expected`, `category`, and optional `protected_spans` and `repair_spans` to `tests/cleanup-cases.json`. Extend `failures()` at `tests/run-cleanup-tests.py:55-60` to compare complete transcripts and print token edit scripts. Keep existing targeted assertions for layout and injection protection.

Concrete held-out cases:

1. Verbatim grammar: “I kinda think we should leave the weird bit alone because it works” → “I kinda think we should leave the weird bit alone because it works.”
2. Hedge and approximation: “we sort of need like eight chairs” → “We sort of need like eight chairs.”
3. Meaningful words: “you know the answer and I mean every word” → “You know the answer, and I mean every word.”
4. True fillers: “um could you uh send the draft you know” → “Could you send the draft?”
5. Cue correction: “let's meet Tuesday actually no Wednesday at three” → “Let's meet Wednesday at three.”
6. Recipient correction: “send it to Mark sorry to Mike before lunch” → “Send it to Mike before lunch.”
7. Cue-less abandoned clause: “I wanted to see whether could you check the invoice today” → “Could you check the invoice today?”
8. Cue-less different phrasing: “the update I was going to can we publish the note tomorrow” → “Can we publish the note tomorrow?”
9. Repeated false start: “please open the please open the latest report” → “Please open the latest report.”
10. Intentional emphasis: “this is very very useful and I really really mean that” → “This is very, very useful, and I really, really mean that.”
11. Parallel content: “send it to Mark send it to Mike as well” → “Send it to Mark. Send it to Mike as well.”
12. Independent context plus repair: “keep the attachment I was going to ask could you send the email tomorrow” → “Keep the attachment. Could you send the email tomorrow?”
13. Meaningful cue word: “I'm sorry Mark missed the call” → “I'm sorry Mark missed the call.”
14. Short input: “um hello” → “Hello.”
15. Proper noun: “please send the north wind proposal to Weslee” → “Please send the Northwind proposal to Weslee.”
16. Protected negation: “I don't want you to simplify this I just want the typo fixed” → “I don't want you to simplify this. I just want the typo fixed.”

Run lexical-preservation cases under default, chat, email, code, and notes styles. Approve punctuation alternatives explicitly; keep the expected lexical sequence fixed. Add a long abandoned passage ending with “scratch that send it tomorrow” to verify valid heavy deletion, and a matched long passage containing an independent preceding request that must survive.

Revise the existing ambiguous “like eight” test only after adopting the conservative hedge policy (`tests/cleanup-cases.json:30-40`). Retain layout, literal-phrase, screen-context, and instruction-as-speech regressions (`tests/cleanup-cases.json:151-198`, `tests/cleanup-cases.json:262-298`).

**Extend live replay with independent expected transcripts.**

Add scenario fixtures and readiness acknowledgements to `tests/live-replay.py`; preserve the existing recorded passage as a separate long-form case.

- Cleaned-boundary cue: chunk “Let's meet Tuesday. Actually”, tail “no, Wednesday.” Expected “Let's meet Wednesday.”
- Cleaned-boundary cue-less restart: chunk “I wanted to see whether. Could”, tail “you check the invoice today?” Expected “Could you check the invoice today?”
- Rephrased restart crossing an 80-word offline piece boundary and the 150-word dispatcher threshold.
- Intentional seam repetition: chunk “This matters. This”, tail “matters.” Expected “This matters. This matters.” This exposes the extra punctuation-insensitive seam deletion.
- A true acoustic-overlap fixture paired with intentional repetition. Supply expected stitching independently instead of deriving both sides through `deduplicate_boundary()`.
- An alias split across chunks: “please open air” followed by “table”. Compare live and full output after the configured replacement policy.
- Correction arriving during an in-flight cleanup; release while busy; stale-session state; and a replacement-prefix mismatch.
- The same transcript partitioned at every relevant correction boundary, with live/full lexical equivalence required.

Use a fake cleaner for deterministic state, overlap, and worker-race tests. Use the actual local model later for semantic repair. Assert exact output and exit status; replace the word-count-only acceptance at `tests/live-replay.py:90-93`. Use accelerated scheduling for functional tests and realistic chunk timing plus burst timing for performance tests; the current fixed two-second sleep is only one schedule (`tests/live-replay.py:64-67`).

**Metrics and acceptance.**

Compute word error rate against the expected repaired transcript:

`WER = (substitutions + deletions + insertions) / expected_word_count`

Use Unicode-aware tokenization, case-folding, and punctuation separation while retaining apostrophes and exact technical identifier tokens. Preserve number spelling in lexical comparison. For an empty reference, require empty output and score any output as failure.

Report:

- Lexical exact-match rate, per category, and macro-average WER.
- Protected-content deletion/substitution rate.
- Required-repair span removal rate and intentional-repetition false-positive rate.
- Exact punctuation, capitalization, dictionary spelling, and layout checks separately.
- Raw-return, rejection, timeout, truncation, and live-mismatch rates.

Require zero lexical errors on curated must-pass fixtures, zero deletion of protected content, and correct repairs for every unambiguous restart fixture. Use a separate held-out set of at least 50 cue-less examples with matched intentional-repetition negatives to select models. Require at least 95% cue-less exact match there as an initial target. Preserve ambiguous cases and report their repair recall separately.

Use manually reviewed audio/transcript pairs later to distinguish ASR loss from cleanup loss. Score raw ASR, post-replacement text, and cleaned output separately. Text-only expected cases cannot prove recovery of words that ASR omitted.

**Latency budget and measurement.**

Define short dictations as at most 30 spoken words and 10 seconds of audio. Target warm p95 release-to-complete-text below 1.0 second, with every curated short latency fixture also below 1.0 second. Report p50, p95, and maximum; treat cold starts and GPU contention as separate named conditions.

Initial engineering allocation, not a measurement:

- Final ASR and handoff: 550ms.
- Cleanup, including any live wait and revision: 300ms.
- Output handling and application receipt: 100ms.
- Scheduling margin: 50ms.

The sum is 1000ms; aim below each allocation. If ASR consumes more, cleanup tuning alone cannot meet the target.

Extend the existing per-case timing at `tests/run-cleanup-tests.py:71-80` to record repeated warm runs and model metadata. Capture Ollama load, prompt-evaluation, generation, and completion fields without logging personal text. The [chat API](https://docs.ollama.com/api/chat) exposes these measurements.

Rename replay timing to “final cleanup latency”. Measure final ASR and delivery independently, then add a real end-to-end test on the GPU host. Adapt `tests/real-dictation-test.py:84-97` to:

- Record a monotonic timestamp immediately before issuing stop.
- Record complete text arrival in the test terminal immediately when it occurs.
- Exclude the later 1.5-second verification sleep from latency.
- Exercise the normal recorder wrapper so warming and live cleanup are included.
- Check exact received text, not set-membership overlap.

Run at least 30 repetitions per short fixture, model, and warm/cold condition, with Voxtype resident and representative desktop load. Include recordings shorter than the documented roughly 2.5-second warmup (`bin/dictation-record:2-4`). Verify actual release-to-app timing, not just subprocess completion.

All execution is deferred to the GPU host. No evaluation, model loading, or GPU benchmark is part of this planning session.

# 4. Risks and open questions

1. **Ambiguous restarts:** text alone may not distinguish a correction from intentional repetition. Recommendation: delete clear abandoned constructions and preserve ambiguous complete statements. More aggressive deletion improves repair recall at the cost of verbatim fidelity. Audio pause and prosody information would be a separate upstream enhancement.
2. **Correction distance:** recommend a two-clause or two-sentence revisable suffix, with earlier raw text retained for explicit wider invalidation. Arbitrary long-distance cue-less repairs require more context and can exceed the latency budget.
3. **Meaningful hedges:** recommend preserving “kind of”, “sort of”, and approximate “like eight” when ambiguous. This intentionally changes the current broad filler policy and one existing fixture.
4. **ASR spelling versus grammar:** recommend preserving informal grammar and short names. Correct only unambiguous spelling errors and dictionary aliases. A language model cannot establish the original audio wording from an ambiguous transcript alone.
5. **Literal replacement collisions:** decide whether “air table” always means Airtable in this user's vocabulary. Recommendation: move ambiguous mappings into contextual dictionary hints and retain deterministic mappings only where ambiguity is negligible.
6. **One-second scope:** decide whether cold starts and competing GPU workloads must also meet the target. Recommendation: require the target for the normal resident-model setup and measure cold/contended failures openly. Persistent residency may improve short cold dictations but uses GPU memory continuously.
7. **Failure policy:** recommend preserving raw speech on infrastructure failure and marking the evaluation as failed cleanup. This is an explicit data-preservation policy already represented at `bin/dictation-cleanup:285-302`; it does not satisfy the cleaned-output quality target.
8. **Layout scope:** recommend retaining current spoken layout commands and whitespace-only app styling, because those features are already exercised by `tests/cleanup-cases.json:164-209`. Confirm whether strict verbatim mode should instead treat spoken layout words literally.
9. **Already pasted text:** recommend correcting only the current recording before its single paste. Editing a previous paste or streaming into the application would require a separate interaction design and ownership of the inserted range.
10. **Rollout order:** establish exact-output fixtures, fix the prompt, implement revisable live merging and edit validation, then compare models. Record implementation decisions in project `DECISIONS.md` during a later authorized coding task. This plan makes no repository changes.

