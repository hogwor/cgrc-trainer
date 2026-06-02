# CLAUDE.md — CGRC Trainer (iOS)

A native SwiftUI iPhone/iPad app for studying the ISC² **CGRC** (Certified in
Governance, Risk and Compliance) exam: a 750-question bank, flashcards, an
adaptive quiz engine, progress tracking, and an offline text-to-speech "Audio
Study" library that reads the core NIST publications aloud.

This is the operating manual for anyone (human or agent) modifying the project.
**Read the Invariants before touching `QuestionBank.swift`**, and run the
verifier after any edit.

---

## Build & run

- Open `CGRCTrainer.xcodeproj` in **Xcode 15+** (macOS). Target **iOS 16.0+**, ⌘R.
- Physical device: set your team in *Signing & Capabilities* and a unique bundle
  id (default is the placeholder `com.example.CGRCTrainer`). `DEVELOPMENT_TEAM`
  is intentionally **blank in git** — don't commit a signing identity.
- **Background audio** needs *Background Modes → Audio*. The entitlement lives in
  the **manual** `CGRCTrainer/Info.plist` (`GENERATE_INFOPLIST_FILE = NO`), so add
  Info.plist keys there, not via Xcode's auto-generated settings.

### Type-check without Xcode (most agent sessions)
```bash
cd ~/CGRC/CGRCTrainer
swiftc -typecheck CGRCTrainerApp.swift AudioContent.swift AudioPlayerView.swift Views.swift QuestionBank.swift
```
**Expected non-errors:** `navigationBarTitleDisplayMode`, `onChange(of:perform:)`,
`AVAudioSession`, some `symbolEffect`/`presentationDetents` report "unavailable in
macOS" — these are iOS-only APIs that compile fine in Xcode (real iOS-only code is
wrapped in `#if os(iOS)`). Treat only *other* errors as real.

---

## Architecture

Swift files in `CGRCTrainer/`, no external dependencies, all data in-source (no
network, no database):

| File | Responsibility |
|------|----------------|
| `CGRCTrainerApp.swift` | `@main` app, `SplashView`, the `Question` model, `DOMAINS`/`WEIGHTS` maps, `Store` (progress persistence). |
| `QuestionBank.swift` | `BANK: [Question]` — **750 items**. The single source of exam content. |
| `Views.swift` | `RootView` (TabView), quiz setup/runner/results, flashcards, stats, **adaptive pool**. |
| `AudioContent.swift` | `AUDIO_LIBRARY: [AudioTrack]` of NIST publication text (public-domain) + `AUDIO_PUBLICATIONS`. |
| `AudioPlayerView.swift` | `SpeechEngine` (AVSpeechSynthesizer + lock-screen controls) and the audio UI. |
| `Assets.xcassets` | `AppIcon` and `CGRCIcon` (splash + Now Playing artwork). |

Four tabs: **Quiz**, **Flashcards**, **Audio**, **Progress**.

```swift
struct Question: Identifiable {
    let id: Int          // unique, stable; gaps OK, duplicates NOT
    let domain: Int      // 1–7 (see Domains)
    let text: String     // the stem
    let options: [String]// exactly 4
    let answer: Int      // index 0–3 of the correct option
    let explain: String  // rationale, cite NIST/RMF where possible
}
```

**Persistence (UserDefaults, no backend):**
- Progress key `cgrc_trainer_v1` (answered/correct, per-domain `domA`/`domC`, and
  `wrongIDs` powering "drill weak questions").
- Audio resume keys `audio_last_track_id` / `audio_last_paragraph`; the player
  restores position and shows a **Resume** banner — don't auto-restart at 0.

---

## The CGRC domains (official ISC² Exam Outline, effective 2024-06-15)

`WEIGHTS` is tuned to these exact weights; the per-domain bank count should track
the target column (for a 750-item bank):

| # | Domain | Weight | Target | Bank now |
|---|--------|--------|--------|----------|
| 1 | Security & Privacy Governance, Risk Mgmt & Compliance Program | 16% | 120 | 120 |
| 2 | Scope of the System | 10% | 75 | 75 |
| 3 | Selection & Approval of Framework, Security & Privacy Controls | 14% | 105 | 105 |
| 4 | Implementation of Security & Privacy Controls | 17% | 127 | 127 |
| 5 | Assessment/Audit of Security & Privacy Controls | 16% | 120 | 120 |
| 6 | System Compliance | 14% | 105 | 105 |
| 7 | Compliance Maintenance | 13% | 98 | 98 |

`DOMAINS` display strings use shorter labels; canonical names are above. **D4
(Implementation, 17%) is the heaviest domain.** The per-domain bank counts now hit
the 2024 targets exactly — keep them there: any new item must go into a domain and
replace a redundant item in the same domain (or rebalance with a matching swap).

---

## Question bank invariants (DO NOT BREAK)

Established through a full SME audit. Any script editing `QuestionBank.swift` must
preserve all of these; re-verify after editing.

1. **Each `Question(...)` on its own single line** ending `),`. Line tooling
   depends on it — never wrap a literal across lines.
2. **Exactly 4 options; `answer` in 0–3.**
3. **No duplicate `id`s.** Gaps fine. New items use ids ≥ 1200 (AI set is 1200–1248; next free ≥ 1249).
4. **Answer position ~balanced** (~25% each A/B/C/D). The bank was de-biased from
   87% "B"; vary the correct position when adding, re-check when bulk-editing.
5. **No joke / non-functioning distractors.** Every distractor must be plausible to
   a knowledgeable candidate (banned: "marketing", "lunch", "WiFi password",
   "aesthetics", etc.). Currently **zero**.
6. **No unofficial study guides.** Answerable from NIST/FISMA/FedRAMP/ISC² CBK
   only. Never reference "the Mango Guide" or any third-party aid.
7. **Current references only.** SP 800-37 **Rev 2**, SP 800-53 **Rev 5**, SP 800-30
   **Rev 1**, SP 800-39, SP 800-137, FIPS 199/200; privacy controls in the **PT
   family** (not Appendix J). FedRAMP: the **JAB/JAB P-ATO are retired** (2024) —
   one "FedRAMP Authorized" designation under the **FedRAMP Board**. NIST CSF is
   **2.0** (six Functions incl. **GOVERN**). AI: **NIST AI RMF 1.0** (Govern/Map/
   Measure/Manage) + **AI 600-1** GenAI Profile. Avoid withdrawn docs (SP 800-64 →
   SP 800-160 v1) and DIACAP. Don't tie items to volatile executive orders / OMB
   memos (they flipped in 2025) — ground AI items in the stable NIST/OWASP/ATLAS
   frameworks instead.
8. **Prefer scenario/application stems** over rote recall (target ≥40% Apply-level):
   "A system owner discovers…", "An AO is reviewing…" — force a judgment.
9. **No "EXCEPT"/negative stems, no "all/none of the above."** Reframe positively.
10. **Length parity (de-biased — keep it).** The correct answer must be **no longer
    than its longest distractor**, and not *systematically shortest* either (a
    reverse tell). Put rationale in `explain`, not the option. Never bulk auto-pad
    distractors. History in Status below.

### RMF quick reference (for accurate items)
- **Seven steps:** Prepare → Categorize → Select → Implement → Assess → Authorize → Monitor.
- **Roles:** AO accepts risk; AODR assists but **cannot sign**; System Owner runs
  the lifecycle; ISSO does day-to-day + assembles the package; SCA/assessor is
  **independent**; CCP owns common controls; Risk Executive = org-wide view;
  SAOP/Privacy Officer = privacy.
- **Authorization package = SSP + SAR + POA&M** (+ exec summary, privacy plan).
  Outcomes: ATO, ATO-with-conditions, DATO, IATT, ATU, ongoing authorization.

---

## Verify the bank after any edit

Confirm **750 total, 0 dup, 0 malformed, ~balanced answers, domains tracking the
table, and length-rank ~uniform**. Then `swiftc -typecheck` (above).

```bash
cd ~/CGRC/CGRCTrainer
python3 - << 'EOF'
import re
from collections import Counter
c=open('QuestionBank.swift').read()
pat=re.compile(r'Question\(id:\s*(\d+),\s*domain:\s*(\d+),.*?options:\s*\[((?:[^\]]|\\.)*)\],\s*answer:\s*(\d+),')
qs=[(int(m[1]),int(m[2]),re.findall(r'"((?:[^"\\]|\\.)*)"',m[3]),int(m[4])) for m in pat.finditer(c)]
n=len(qs); rc=Counter(); sev=0
for _,_,o,a in qs:
    if len(o)!=4: continue
    cl=len(o[a]); other=max(len(o[i]) for i in range(4) if i!=a)
    rc[sum(1 for i in range(4) if len(o[i])>cl)+1]+=1
    sev+=cl>1.5*other
print("total",n,"dup",n-len({q[0] for q in qs}),
      "bad_opts",sum(len(q[2])!=4 for q in qs),"bad_ans",sum(not 0<=q[3]<4 for q in qs))
print("answers",{chr(65+k):round(v/n*100,1) for k,v in sorted(Counter(q[3] for q in qs).items())})
print("domains",dict(sorted(Counter(q[1] for q in qs).items())))
print("len-rank",{k:round(v/n*100,1) for k,v in sorted(rc.items())},"| severe",sev)
EOF
```

---

## Quiz / adaptive engine (Views.swift)

- **"All domains"** uses `adaptivePool(store:)`: oversamples weak domains.
  `domainWeights(store:)` → 1.0 (100% acc) to 3.0 (0% acc); <5 answered = neutral
  2.0. Setup screen surfaces struggling domains + boost factor.
- Specific-domain quiz draws that domain; "drill weak questions" pulls
  `store.wrongIDs`. Modes: instant feedback vs. exam-style (feedback at end).
- Exam-style mode must **not** reveal the key via option color — `bg(for:)` guards
  on `instant`.
- **Freeze quiz items at Start — never feed `QuizView` from a store-dependent
  computed property.** `startQuiz(weak:)` snapshots the shuffled/prefixed set into
  `@State quizItems`; `navigationDestination` passes that snapshot. Trap:
  `pool`/`adaptivePool(store:)` reshuffle on every access, and answering calls
  `store.record(...)`, which re-renders `QuizSetupView` and re-runs the destination
  builder — so a live computed property hands the runner a *new* set each answer
  while `@State idx` persists, showing the wrong question on the feedback screen.
  `pool` is fine only for Start/Drill enable-disable checks.

## Audio engine (AudioPlayerView.swift)

- **`AVSpeechSynthesizer`** — offline, no API, no audio files. Prefers the **"Zoe"**
  premium voice if installed, else system en-US.
- `AVAudioSession` `.playback`/`.spokenAudio` (plays with screen off / over the
  silent switch). Lock-screen transport via `MPRemoteCommandCenter`, Now Playing
  metadata via `MPNowPlayingInfoCenter`.
- Plays **paragraph by paragraph**, auto-advances tracks, persists position,
  handles interruptions. Content is verbatim public-domain NIST text — keep
  `AudioTrack.paragraphs` chunked to ~1–3 sentences.

## House style

- Terse SwiftUI, no external packages, no force-unwraps on user data, `#if os(iOS)`
  around iOS-only APIs. **Offline & self-contained** — no network/analytics/SDKs.
- When you change user-visible behavior (tab, control, persistence key), update
  this file and `README.md`.

---

## Status & outstanding work

**Aligned to the June 15, 2024 CGRC Exam Outline (current 2024–2026).** `WEIGHTS` +
blueprint bar on the 2024 split; CSF question (id 111) on **CSF 2.0**; FedRAMP
items (164, 383, 1008, 1074) on the **2024 FedRAMP Board / single authorization**
model.

**Length-tell: remediated.** Baseline correct-answer-was-longest **85.6%** (severe
>1.5× = 71.5%); after 9 hand-built batches (485 items rewritten) the length rank is
~uniform (rank-1 **20.9%**, severe **7.2%**) — "pick the longest" now scores *below*
chance. Don't push rank-1 lower (reverse tell); just keep options length-comparable
per invariant #10. The verifier above reports `len-rank`/`severe`.

**AI security — complete.** The 2024 outline embeds AI/ML across all domains
(algorithmic transparency / black-box risk, model governance, prompt injection,
data poisoning, ML-pipeline/MLOps controls, bias detection). **49 AI items (ids
1200–1248)** now span all 7 domains, grounded in NIST AI RMF 1.0 / AI 600-1 GenAI
Profile / OWASP LLM Top 10 / MITRE ATLAS — and deliberately *not* tied to volatile
EO/OMB citations. Each was swapped in for a redundant near-duplicate, so the bank
stayed at 750. New AI ids continue at ≥ 1249.

**Per-domain rebalance — done.** All seven domains now match the 2024 targets
exactly (see table). The AI scale-up doubled as the rebalance: ~39 items added to
under-target D4/D5/D6, ~39 redundant near-duplicates removed from over-target
D2/D3/D7. Keep counts on-target with same-domain (or matched) swaps going forward.
