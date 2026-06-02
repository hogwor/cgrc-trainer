# CGRC Trainer — iOS (SwiftUI)

A native iOS study app for the ISC2 CGRC exam (outline effective June 15, 2024). 59 practice
questions across all 7 domains, weighted to the official blueprint.

## Features
- **Quiz** — pick a domain (or all), choose length, instant or end-of-exam feedback, scored results with per-domain breakdown and full answer review.
- **Drill weak questions** — re-quiz only the questions you've missed.
- **Flashcards** — flip term ↔ answer + explanation, by domain.
- **Progress** — overall accuracy, accuracy per domain, persisted on-device (UserDefaults).

## Requirements
- A Mac with **Xcode 15+** (iOS 16.0 deployment target).

## Run it
1. Unzip and open `CGRCTrainer.xcodeproj` in Xcode.
2. Select a simulator (e.g. iPhone 15) or your own device.
3. Press **Run** (⌘R).

To run on a physical iPhone: select the **CGRCTrainer** target → **Signing & Capabilities**,
pick your Apple ID team, and change the Bundle Identifier to something unique
(e.g. `com.yourname.CGRCTrainer`). A free Apple ID works for personal on-device installs.

## Project layout
```
CGRCTrainer/
  CGRCTrainer.xcodeproj
  CGRCTrainer/
    CGRCTrainerApp.swift   app entry, model, persistence store
    QuestionBank.swift     59 questions (auto-generated)
    Views.swift            quiz, flashcards, stats, results UI
```

## Editing the question bank
Add `Question(...)` entries to `QuestionBank.swift`. Give each a unique `id`, a `domain` 1–7,
the `answer` index into `options`, and an `explain` string. The app picks up new questions
automatically.

Content is based on the public ISC2 CGRC Certification Exam Outline and NIST RMF references.
Practice questions are original study aids, not actual exam items.
