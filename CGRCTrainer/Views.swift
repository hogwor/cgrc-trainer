import SwiftUI

// MARK: - Root tabs
struct RootView: View {
    var body: some View {
        TabView {
            QuizSetupView()
                .tabItem { Label("Quiz", systemImage: "checkmark.circle") }
            FlashcardView()
                .tabItem { Label("Flashcards", systemImage: "rectangle.on.rectangle") }
            AudioLibraryView()
                .tabItem { Label("Audio", systemImage: "headphones") }
            StatsView()
                .tabItem { Label("Progress", systemImage: "chart.bar") }
        }
    }
}

// MARK: - Helpers
func questions(forDomain dom: Int?, weak: Set<Int>?) -> [Question] {
    if let w = weak { return BANK.filter { w.contains($0.id) } }
    guard let d = dom else { return BANK }
    return BANK.filter { $0.domain == d }
}

/// Weight for each domain: lower accuracy → higher weight (range 1.0–3.0).
/// Domains with fewer than 5 answers get a neutral-high weight of 2.0.
func domainWeights(store: Store) -> [Int: Double] {
    var w: [Int: Double] = [:]
    for d in 1...7 {
        let answered = store.domA[d] ?? 0
        let correct  = store.domC[d] ?? 0
        if answered < 5 {
            w[d] = 2.0
        } else {
            let accuracy = Double(correct) / Double(answered)
            w[d] = 1.0 + (1.0 - accuracy) * 2.0
        }
    }
    return w
}

/// Builds a shuffled pool of ~300 questions weighted by per-domain struggle.
/// Struggling domains are overrepresented so the quiz naturally drills weak spots.
func adaptivePool(store: Store) -> [Question] {
    let weights   = domainWeights(store: store)
    let totalW    = weights.values.reduce(0, +)
    let target    = 300
    var pool: [Question] = []
    for d in 1...7 {
        let share = max(1, Int((weights[d]! / totalW * Double(target)).rounded()))
        let qs    = BANK.filter { $0.domain == d }.shuffled()
        pool     += Array(qs.prefix(share))
    }
    return pool.shuffled()
}

enum QuizSource { case normal, weak, due }

// MARK: - Quiz setup
struct QuizSetupView: View {
    @EnvironmentObject var store: Store
    @State private var domain: Int = 0      // 0 == all
    @State private var count: Int = 20
    @State private var instant = true
    @State private var active = false
    @State private var quizItems: [Question] = []   // frozen at Start; must NOT depend on store re-renders

    /// Candidate questions for the current setup — used only for enable/disable checks.
    /// The live quiz draws from the frozen `quizItems` snapshot built in `startQuiz`.
    var pool: [Question] {
        if domain == 0 { return adaptivePool(store: store) }
        return questions(forDomain: domain, weak: nil)
    }

    /// Snapshot the question set once, so answering (which mutates `store`) can't
    /// reshuffle the quiz out from under the runner.
    func startQuiz(source: QuizSource) {
        let pool: [Question]
        switch source {
        case .weak:   pool = BANK.filter { store.wrongIDs.contains($0.id) }
        case .due:    pool = BANK.filter { store.dueIDs.contains($0.id) }
        case .normal: pool = (domain == 0 ? adaptivePool(store: store)
                                          : questions(forDomain: domain, weak: nil))
        }
        let shuffled = pool.shuffled()
        let n = (source == .normal) ? min(count, shuffled.count) : shuffled.count
        quizItems = Array(shuffled.prefix(n))
        active = !quizItems.isEmpty
    }

    /// Domains where the user is scoring below 70% and has enough data to judge.
    var strugglingDomains: [Int] {
        (1...7).filter { d in
            let a = store.domA[d] ?? 0
            let c = store.domC[d] ?? 0
            guard a >= 5 else { return false }
            return Double(c) / Double(a) < 0.70
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Quiz options") {
                    Picker("Domain", selection: $domain) {
                        Text("All domains").tag(0)
                        ForEach(1...7, id: \.self) { d in
                            Text("D\(d): \(DOMAINS[d]!)").tag(d)
                        }
                    }
                    if domain == 0 {
                        if strugglingDomains.isEmpty {
                            Label("Adaptive mix — no weak domains yet", systemImage: "brain")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Adaptive mix — drilling harder on:", systemImage: "brain")
                                    .font(.footnote).foregroundStyle(.secondary)
                                let weights = domainWeights(store: store)
                                ForEach(strugglingDomains, id: \.self) { d in
                                    let a = store.domA[d] ?? 0
                                    let c = store.domC[d] ?? 0
                                    let pct = a == 0 ? 0 : Int(Double(c) / Double(a) * 100)
                                    let boost = weights[d].map { String(format: "%.1f×", $0) } ?? ""
                                    HStack {
                                        Text("D\(d) \(DOMAINS[d]!)")
                                            .font(.footnote).bold()
                                        Spacer()
                                        Text("\(pct)% · \(boost) weight")
                                            .font(.footnote).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                    Stepper("Questions: \(count)", value: $count, in: 1...60, step: 5)
                    Toggle("Instant feedback", isOn: $instant)
                }
                Section {
                    Button("Start quiz") { startQuiz(source: .normal) }
                        .disabled(pool.isEmpty)
                    Button("Spaced review · \(store.dueIDs.count) due") { startQuiz(source: .due) }
                        .disabled(store.dueIDs.isEmpty)
                    Button("Drill my weak questions") { startQuiz(source: .weak) }
                        .disabled(store.wrongIDs.isEmpty)
                } footer: {
                    Text("Spaced review resurfaces items as their Leitner interval elapses (1 → 3 → 7 → 14 → 30 days); answer correctly to advance a box, miss to reset. Mastered: \(store.masteredCount)/\(BANK.count).")
                }
                Section("Exam blueprint") {
                    Text("125 items · 3 hours · pass at 700/1000. Domain weights:")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(1...7, id: \.self) { d in
                        HStack {
                            Text("D\(d)").frame(width: 34, alignment: .leading)
                            ProgressView(value: Double(WEIGHTS[d]!), total: 17)
                            Text("\(WEIGHTS[d]!)%").frame(width: 40, alignment: .trailing)
                                .font(.footnote)
                        }
                    }
                }
                Section { Text("Question bank: \(BANK.count) items across all 7 domains.")
                    .font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("CGRC Trainer")
            .navigationDestination(isPresented: $active) {
                QuizView(items: quizItems, instant: instant)
            }
        }
    }
}

// MARK: - Quiz runner
struct QuizView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let items: [Question]
    let instant: Bool

    @State private var idx = 0
    @State private var chosen: Int? = nil
    @State private var order: [Int] = []
    @State private var answers: [(id: Int, correct: Bool, chosen: Int)] = []
    @State private var done = false

    var q: Question { items[idx] }

    var body: some View {
        Group {
            if done {
                ResultsView(items: items, answers: answers) { dismiss() }
            } else {
                quizBody
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear { if order.isEmpty { newOrder() } }
    }

    var quizBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ProgressView(value: Double(idx), total: Double(items.count))
                        Text("Question \(idx + 1) of \(items.count) · D\(q.domain)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(q.text).font(.title3).bold()
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(order, id: \.self) { i in
                            Button { pick(i) } label: {
                                HStack {
                                    Text(q.options[i])
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(bg(for: i))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.gray.opacity(0.3)))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(chosen != nil)
                        }

                        if instant, let c = chosen {
                            Text((c == q.answer ? "✓ Correct. " : "✗ Not quite. ") + q.explain)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.gray.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .id("feedback")
                        }
                    }
                    .padding()
                }
                .onChange(of: chosen) { c in
                    guard instant, c != nil else { return }
                    withAnimation { proxy.scrollTo("feedback", anchor: .bottom) }
                }
            }

            Divider()
            HStack {
                Button("Quit") { dismiss() }.foregroundStyle(.secondary)
                Spacer()
                if chosen != nil {
                    Button(idx + 1 >= items.count ? "Finish" : "Next →") { next() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    func bg(for i: Int) -> Color {
        guard let c = chosen else { return Color.gray.opacity(0.08) }
        guard instant else {        // exam mode: mark the picked cell only, never reveal the key
            return i == c ? Color.blue.opacity(0.18) : Color.gray.opacity(0.08)
        }
        if i == q.answer { return Color.green.opacity(0.25) }
        if i == c { return Color.red.opacity(0.25) }
        return Color.gray.opacity(0.08)
    }

    func newOrder() { order = Array(0..<q.options.count).shuffled() }

    func pick(_ i: Int) {
        guard chosen == nil else { return }
        chosen = i
        let ok = (i == q.answer)
        answers.append((q.id, ok, i))
        store.record(domain: q.domain, id: q.id, isCorrect: ok)
    }

    func next() {
        if idx + 1 >= items.count {
            store.finishQuiz(); done = true
        } else {
            idx += 1; chosen = nil; newOrder()
        }
    }
}

// MARK: - Results
struct ResultsView: View {
    let items: [Question]
    let answers: [(id: Int, correct: Bool, chosen: Int)]
    let onDone: () -> Void

    var right: Int { answers.filter { $0.correct }.count }
    var pct: Int { answers.isEmpty ? 0 : Int(Double(right) / Double(answers.count) * 100) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("\(pct)%").font(.system(size: 54, weight: .bold))
                    .foregroundStyle(pct >= 70 ? .green : .orange)
                Text("\(right) of \(answers.count) correct" + (pct >= 70 ? " — passing range 👍" : " — keep drilling"))
                    .foregroundStyle(.secondary)

                ForEach(Array(answers.enumerated()), id: \.offset) { n, a in
                    if let q = BANK.first(where: { $0.id == a.id }) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Q\(n + 1) · D\(q.domain) · \(a.correct ? "Correct" : "Wrong")")
                                .font(.caption).foregroundStyle(a.correct ? .green : .red)
                            Text(q.text).bold()
                            Text("Your answer: \(q.options[a.chosen])").font(.callout).foregroundStyle(.secondary)
                            Text("Correct: \(q.options[q.answer])").font(.callout).foregroundStyle(.green)
                            Text(q.explain).font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                Button("Done") { onDone() }.buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Flashcards
struct FlashcardView: View {
    @EnvironmentObject var store: Store
    @State private var domain = 0
    @State private var deck: [Question] = []
    @State private var idx = 0
    @State private var flipped = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Domain", selection: $domain) {
                    Text("All").tag(0)
                    ForEach(1...7, id: \.self) { Text("D\($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: domain) { _ in build() }

                if deck.isEmpty {
                    Text("No cards").foregroundStyle(.secondary)
                } else {
                    let q = deck[idx]
                    Text("Card \(idx + 1) of \(deck.count) · D\(q.domain)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { flipped.toggle() } label: {
                        VStack(spacing: 10) {
                            if flipped {
                                Text(q.options[q.answer]).font(.title3).bold().foregroundStyle(.green)
                                Text(q.explain).font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text(q.text).font(.title3)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    if flipped {
                        // Self-rating feeds the spaced-repetition schedule.
                        HStack(spacing: 12) {
                            Button { rate(false) } label: {
                                Label("Review again", systemImage: "arrow.counterclockwise")
                                    .frame(maxWidth: .infinity)
                            }.tint(.orange)
                            Button { rate(true) } label: {
                                Label("Got it", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }.tint(.green)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        HStack {
                            Button("← Prev") { move(-1) }
                            Spacer()
                            Button("Flip") { flipped.toggle() }.buttonStyle(.borderedProminent)
                            Spacer()
                            Button("Next →") { move(1) }
                        }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Flashcards")
            .onAppear { if deck.isEmpty { build() } }
        }
    }

    func build() {
        deck = (domain == 0 ? BANK : BANK.filter { $0.domain == domain }).shuffled()
        idx = 0; flipped = false
    }
    func move(_ d: Int) {
        guard !deck.isEmpty else { return }
        idx = (idx + d + deck.count) % deck.count
        flipped = false
    }
    /// Record a self-rating into the SR model, then advance to the next card.
    func rate(_ ok: Bool) {
        guard !deck.isEmpty else { return }
        store.reviewCard(id: deck[idx].id, isCorrect: ok)
        move(1)
    }
}

// MARK: - Stats
struct StatsView: View {
    @EnvironmentObject var store: Store
    var acc: String { store.answered == 0 ? "—" : "\(Int(Double(store.correct)/Double(store.answered)*100))%" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Questions answered", value: "\(store.answered)")
                    LabeledContent("Overall accuracy", value: acc)
                    LabeledContent("Quizzes taken", value: "\(store.quizzes)")
                    LabeledContent("Weak questions", value: "\(store.wrongIDs.count)")
                }
                Section("Mastery") {
                    let mastered = store.masteredCount
                    LabeledContent("Mastered", value: "\(mastered) / \(BANK.count)  (\(BANK.isEmpty ? 0 : mastered * 100 / BANK.count)%)")
                    LabeledContent("Questions seen", value: "\(store.seenCount) / \(BANK.count)")
                    LabeledContent("Due for review", value: "\(store.dueIDs.count)")
                    let boxes = store.boxCounts()
                    let denom = max(1, store.seenCount)
                    ForEach(0...MASTERY_BOX, id: \.self) { b in
                        HStack {
                            Text(b == 0 ? "New/lapsed" : b == MASTERY_BOX ? "Mastered" : "Box \(b)")
                                .frame(width: 96, alignment: .leading).font(.footnote)
                            ProgressView(value: Double(boxes[b]), total: Double(denom))
                                .tint(b == MASTERY_BOX ? .green : (b == 0 ? .orange : .blue))
                            Text("\(boxes[b])").frame(width: 40, alignment: .trailing).font(.footnote)
                        }
                    }
                }
                Section("Accuracy by domain") {
                    ForEach(1...7, id: \.self) { d in
                        let a = store.domA[d] ?? 0
                        let c = store.domC[d] ?? 0
                        HStack {
                            Text("D\(d)").frame(width: 34, alignment: .leading)
                            ProgressView(value: a == 0 ? 0 : Double(c)/Double(a))
                            Text(a == 0 ? "—" : "\(c)/\(a)").frame(width: 60, alignment: .trailing).font(.footnote)
                        }
                    }
                }
                Section {
                    Button("Reset all progress", role: .destructive) { store.reset() }
                }
            }
            .navigationTitle("Progress")
        }
    }
}
