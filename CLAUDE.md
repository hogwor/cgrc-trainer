# CLAUDE.md — CGRC Trainer (iOS)

A native SwiftUI iPhone/iPad app for studying the ISC² **CGRC** (Certified in
Governance, Risk and Compliance) exam. It ships a 750-question bank, flashcards,
an adaptive quiz engine, progress tracking, and an offline text-to-speech "Audio
Study" library that reads the core NIST publications aloud.

This file is the operating manual for anyone (human or agent) modifying the
project. Read the **Invariants** section before touching `QuestionBank.swift`.

---

## Build & run

- Open `CGRCTrainer.xcodeproj` in **Xcode 15+** on macOS. Target: **iOS 16.0+**.
- Run with ⌘R on a simulator or device. For a physical device, set your team
  under *Signing & Capabilities* and a unique bundle id (default is the
  placeholder `com.example.CGRCTrainer`).
- **Background audio** requires the *Background Modes → Audio* capability. The
  entitlement is declared in `CGRCTrainer/Info.plist` (`UIBackgroundModes:
  audio`); the project uses a **manual Info.plist**
  (`GENERATE_INFOPLIST_FILE = NO`), so add new Info.plist keys there, not via
  Xcode's auto-generated build settings.

### Validating changes without Xcode
There is no Mac GUI in most agent sessions. Sanity-check Swift with:
```bash
cd ~/CGRC/CGRCTrainer
swiftc -typecheck CGRCTrainerApp.swift AudioContent.swift AudioPlayerView.swift Views.swift QuestionBank.swift
```
**Expected non-errors:** `navigationBarTitleDisplayMode`, `onChange(of:perform:)`,
`AVAudioSession`, and a few `symbolEffect`/`presentationDetents` APIs report as
"unavailable in macOS" or deprecated — these are **iOS-only APIs that compile
fine in Xcode**. Treat only *other* errors as real. iOS-only code that the macOS
type-checker chokes on is wrapped in `#if os(iOS)`.

---

## Architecture

Six Swift files in `CGRCTrainer/`, no external dependencies, all data is
in-source (no network, no database):

| File | Responsibility |
|------|----------------|
| `CGRCTrainerApp.swift` | `@main` app, launch `SplashView`, the `Question` model, `DOMAINS`/`WEIGHTS` maps, and `Store` (progress persistence). |
| `QuestionBank.swift` | The `BANK: [Question]` array — **750 items**. The single source of exam content. |
| `Views.swift` | `RootView` (TabView), quiz setup/runner/results, flashcards, stats, and the **adaptive pool** logic. |
| `AudioContent.swift` | `AUDIO_LIBRARY: [AudioTrack]` — **30 tracks** of NIST publication text (public-domain US Government works) plus `AUDIO_PUBLICATIONS`. |
| `AudioPlayerView.swift` | `SpeechEngine` (AVSpeechSynthesizer + lock-screen controls) and the audio library/player UI. |
| `Assets.xcassets` | `AppIcon` (the CGRC shield) and `CGRCIcon` (same art, used by the splash screen and lock-screen Now Playing artwork). |

Four tabs: **Quiz**, **Flashcards**, **Audio**, **Progress**.

### Data model
```swift
struct Question: Identifiable {
    let id: Int          // unique, stable; gaps are fine, duplicates are NOT
    let domain: Int      // 1–7 (see Domains below)
    let text: String     // the stem
    let options: [String]// exactly 4
    let answer: Int      // index 0–3 of the correct option
    let explain: String  // rationale, cite NIST/RMF where possible
}
```

### Persistence (UserDefaults, no backend)
- Progress: key `cgrc_trainer_v1` (answered/correct counts, per-domain tallies in
  `domA`/`domC`, and the `wrongIDs` set that powers "drill weak questions").
- Audio resume: keys `audio_last_track_id` and `audio_last_paragraph`. The player
  restores the last position on launch and shows a **Resume** banner; do not make
  the player auto-restart from paragraph 0 on reopen.

---

## The CGRC domains (official ISC² CGRC Exam Outline, effective 2024-06-15)

`WEIGHTS` is tuned to these exact weights. **The bank count per domain should
track the blueprint** (target counts for a 750-item bank in the last column):

| # | Domain | Weight | Target count |
|---|--------|--------|--------------|
| 1 | Security and Privacy Governance, Risk Management, and Compliance Program | 16% | 120 |
| 2 | Scope of the System | 10% | 75 |
| 3 | Selection and Approval of Framework, Security, and Privacy Controls | 14% | 105 |
| 4 | Implementation of Security and Privacy Controls | 17% | 127 |
| 5 | Assessment/Audit of Security and Privacy Controls | 16% | 120 |
| 6 | System Compliance | 14% | 105 |
| 7 | Compliance Maintenance | 13% | 98 |

> Note: the `DOMAINS` display strings in `CGRCTrainerApp.swift` use slightly
> shorter labels; the canonical names are above. **D4 (Implementation, 17%) is
> now the single heaviest domain.**
>
> ⚠️ **Outline changed on 2024-06-15 (this is the current 2024–2026 version).**
> Versus the prior (2023) outline, **D6 rose 10%→14% and D7 fell 17%→13%** (plus
> D2 −1, D3 −1, D4 +1, D5 +1). `WEIGHTS` and the blueprint bar are updated, but
> the **bank's per-domain question counts still reflect the old 2023 split** — so
> D6 is currently under-stocked and D7 over-stocked relative to the new blueprint.
> Rebalancing the per-domain counts is pending (see *Outstanding 2024-outline
> work* below).

---

## Question bank invariants (DO NOT BREAK)

These were established through a full SME audit. Any script that edits
`QuestionBank.swift` must preserve all of them, and you must re-verify after
editing (see the verification snippet below).

1. **Each `Question(...)` is on its own single line** ending in `),`. Line-based
   tooling depends on this. Do not wrap question literals across lines.
2. **Exactly 4 options; `answer` in 0–3.**
3. **No duplicate `id`s.** Gaps are fine. New items currently use ids ≥ 1100.
4. **Answer position must stay ~balanced** (~25% each A/B/C/D). The bank was
   de-biased from 87% "B". When adding items, vary the correct position; when
   bulk-editing, re-check the distribution.
5. **No joke / non-functioning distractors.** Every distractor must be plausible
   to a knowledgeable candidate. Banned patterns (a scan target): "marketing",
   "lunch", "WiFi password", "CEO's travel", "raises", "aesthetics", "family
   members". The bank currently has **zero**.
6. **No dependence on unofficial study guides.** Questions must be answerable
   from NIST/FISMA/FedRAMP/ISC² CBK sources only. Never reference "the Mango
   Guide" (or any third-party aid) in a stem or explanation.
7. **Current references only.** Use SP 800-37 **Rev 2**, SP 800-53 **Rev 5**, SP
   800-30 **Rev 1**, SP 800-39, SP 800-137, FIPS 199/200. Privacy controls live
   in the **PT family** (not Appendix J). Avoid withdrawn docs (e.g. SP 800-64 →
   use SP 800-160 Vol 1) and DIACAP. Cite the authoritative source in `explain`,
   not Mango "Domain x.y" task numbers.
8. **Prefer scenario/application stems** over rote recall. Target ≥40% at
   Apply-or-higher Bloom level. A good item reads like a situation ("A system
   owner discovers…", "An AO is reviewing…") and forces a judgment.
9. **Avoid "EXCEPT"/negative stems and "all/none of the above."** Reframe
   positively.
10. **Watch the length tell.** The correct answer should not be dramatically
    longer than the distractors (a test-wise candidate picks the longest). Put
    rationale in `explain`, keep options comparable in length. **This was the
    bank's biggest weakness and has been remediated** (see *Length-tell
    remediation* below) — the correct-answer length rank is now ~uniform across
    the four positions. **Keep it that way for new/edited items:** make the
    correct answer no longer than its longest distractor, and don't let it become
    *systematically shortest* either (that's just a reverse tell). Never bulk
    auto-pad distractors (that risks injecting factual errors).

### RMF quick reference (for writing accurate items)
- **Seven steps, in order:** Prepare → Categorize → Select → Implement → Assess →
  Authorize → Monitor.
- **Roles:** AO accepts risk (management decision); AODR assists but **cannot
  sign** the authorization; System Owner runs the system lifecycle; ISSO handles
  day-to-day security and assembles the package; SCA/assessor is **independent**;
  CCP owns common controls; Risk Executive gives the org-wide view; SAOP/Privacy
  Officer covers privacy.
- **Authorization package = SSP + SAR + POA&M** (+ executive summary, privacy
  plan). Outcomes: ATO, ATO-with-conditions, DATO, IATT, ATU, ongoing
  authorization.

---

## Verifying the bank after any edit

Run this and confirm **750 total, 0 duplicates, 0 malformed, balanced answers,
and domain counts matching the blueprint**:

```bash
cd ~/CGRC/CGRCTrainer
python3 - << 'EOF'
import re
from collections import Counter
c=open('QuestionBank.swift').read()
pat=re.compile(r'Question\(id:\s*(\d+),\s*domain:\s*(\d+),\s*text:\s*"((?:[^"\\]|\\.)*)",\s*options:\s*\[((?:[^\]]|\\.)*)\],\s*answer:\s*(\d+),\s*explain:\s*"((?:[^"\\]|\\.)*)"\)')
qs=[{'id':int(m[1]),'domain':int(m[2]),'opts':re.findall(r'"((?:[^"\\]|\\.)*)"',m[4]),'ans':int(m[5])}
    for m in pat.finditer(c)]
n=len(qs)
print("total",n,"| dup",n-len({q['id'] for q in qs}),
      "| bad_opts",sum(1 for q in qs if len(q['opts'])!=4),
      "| bad_ans",sum(1 for q in qs if not 0<=q['ans']<4))
print("answers",{chr(65+k):round(v/n*100,1) for k,v in sorted(Counter(q['ans'] for q in qs).items())})
print("domains",dict(sorted(Counter(q['domain'] for q in qs).items())))
EOF
```
Then `swiftc -typecheck` (see above) to confirm it still compiles.

---

## Quiz / adaptive engine (Views.swift)

- **"All domains"** quiz uses `adaptivePool(store:)`: it oversamples domains where
  the user is scoring poorly. `domainWeights(store:)` returns 1.0 (100% accuracy)
  → 3.0 (0% accuracy); domains with <5 answered get a neutral 2.0. The setup
  screen surfaces struggling domains and their boost factor.
- A specific-domain quiz draws only that domain; "drill weak questions" pulls from
  `store.wrongIDs`.
- Quiz modes: instant feedback vs. exam-style (feedback at the end). Results show
  per-question review with the `explain` text. In exam-style mode the option
  colors must **not** reveal the key — `bg(for:)` guards on `instant`.
- **Freeze the quiz items at Start — never feed `QuizView` from a
  store-dependent computed property.** `startQuiz(weak:)` snapshots the (shuffled,
  prefixed) question set into the `@State quizItems`, and `navigationDestination`
  passes that snapshot. The trap: `pool`/`adaptivePool(store:)` reshuffle on every
  access, and answering a question calls `store.record(...)`, which re-renders
  `QuizSetupView` and re-runs the destination builder. If the runner is fed from
  that live computed property, each answer hands it a *new* question set while
  `@State idx` stays put, so the feedback screen shows a different question than
  the one asked. `pool` is fine for the Start/Drill enable-disable checks only.

## Audio engine (AudioPlayerView.swift)

- Uses **`AVSpeechSynthesizer`** — offline, no API, no audio files. Prefers the
  **"Zoe"** premium voice if installed on device, else falls back to system
  en-US.
- `AVAudioSession` is `.playback`/`.spokenAudio` so audio plays with the screen
  off and over the silent switch. Lock-screen / Control Center transport
  (play/pause/next/prev) is wired via `MPRemoteCommandCenter`, and Now Playing
  metadata via `MPNowPlayingInfoCenter`.
- Plays **paragraph by paragraph**, auto-advances to the next track at end of a
  track, persists position, and handles audio interruptions (e.g. phone calls).
- Content is verbatim NIST publication text (public-domain). If regenerating,
  keep `AudioTrack.paragraphs` chunked to TTS-friendly lengths (~1–3 sentences).

---

## House style

- Match the surrounding code: terse SwiftUI, no external packages, no force
  unwraps on user data, `#if os(iOS)` around iOS-only APIs.
- Keep everything **offline and self-contained** — no network calls, analytics,
  or third-party SDKs. All content ships in-source.
- When you change behavior a user can see (new tab, control, persistence key),
  update the relevant section here and in `README.md`.
- Don't commit signing identities; `DEVELOPMENT_TEAM` in the project is the
  owner's and may need to be cleared/replaced for other developers.

## Length-tell remediation (completed 2026-06-02)

The answer-length bias that once dominated this bank has been **fixed**. Baseline
audit found the correct answer was the longest (or tied) option in **642 / 750
(85.6%)** items, *severe* (>1.5× the longest distractor) in **536 (71.5%)**.

Remediation ran in nine hand-built batches (485 items rewritten): correct answers
trimmed, joke/non-functioning distractors replaced with plausible-but-wrong ones
of comparable length, length rank deliberately spread across positions, and answer
slots kept ~25% each. Correctness and the keyed answer were preserved throughout;
the bank type-checks clean and still holds all invariants (750 items, 4 options,
no dup ids, ~25% answer balance).

**Final distribution (correct-answer length rank):**

| rank | 1 (longest) | 2 | 3 | 4 (shortest) |
|------|-------------|---|---|--------------|
| share | **20.9%** | 28.1% | 25.7% | 25.2% |

- Longest-or-tied: **85.6% → 20.9%**. "Pick the longest" now scores *below* random
  chance (25%) — the leak is neutralized.
- Severe (>1.5×): **71.5% → 7.2%**.

**Do not keep converting longest-answer items to shortest.** rank-1 is already at
the uniform floor; pushing it lower creates a *reverse* tell ("longest is never
correct"). For new/edited items just keep options length-comparable (invariant
#10). Re-measure anytime with:

  ```bash
  cd ~/CGRC/CGRCTrainer
  python3 - << 'EOF'
  import re
  from collections import Counter
  c=open('QuestionBank.swift').read()
  pat=re.compile(r'Question\(id:\s*(\d+),.*?options:\s*\[((?:[^\]]|\\.)*)\],\s*answer:\s*(\d+),')
  rc=Counter(); sev=tot=0
  for m in pat.finditer(c):
      opts=re.findall(r'"((?:[^"\\]|\\.)*)"',m[2]); a=int(m[3])
      if len(opts)!=4: continue
      tot+=1; cl=len(opts[a]); other=max(len(opts[i]) for i in range(4) if i!=a)
      rc[sum(1 for i in range(4) if len(opts[i])>cl)+1]+=1
      if cl>1.5*other: sev+=1
  share={k:round(v/tot*100,1) for k,v in sorted(rc.items())}
  print("total",tot,"| rank-share",share,"| severe",sev)
  EOF
  ```

## Outstanding 2024-outline work

The bank was validated against the **June 15, 2024 CGRC Exam Outline** (current
2024–2026). Done: `WEIGHTS` + blueprint bar updated to the 2024 split; the CSF
question (id 111) now reflects **CSF 2.0** (six Functions incl. GOVERN); the four
FedRAMP-JAB items (164, 383, 1008, 1074) rewritten for the **2024 FedRAMP Board /
single "FedRAMP Authorized" designation** (JAB and JAB P-ATO are retired).

Still pending:
- **AI security coverage (biggest gap).** The 2024 outline embeds AI/ML security
  across all seven domains (algorithmic transparency / "black-box" risk, ML model
  governance & "machine unlearning", prompt injection, adversarial data poisoning,
  ML-pipeline/MLOps controls, algorithmic-bias detection). The bank currently has
  ~1 AI item. Author a spread of AI-security RMF questions and swap them in for the
  weakest/most-redundant existing items to stay at 750.
- **Per-domain rebalancing.** Question counts still match the 2023 weights; bring
  them to the 2024 target counts in the domain table (mainly: add D6, trim D7).

## Known residual work (not bugs)

- A handful of D1 items lean CISSP-quantitative (ALE/SLE/ARO) — acceptable but
  not CGRC-core; prefer qualitative, RMF-centric framing for new items.
- One near-duplicate item: ids **174** and **1148** are the same
  re-authorization question reworded (both keyed correctly). Differentiate or
  drop one.
