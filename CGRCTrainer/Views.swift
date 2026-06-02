import SwiftUI

// MARK: - Root tabs
struct RootView: View {
    var body: some View {
        TabView {
            QuizSetupView()
                .tabItem { Label("Quiz", systemImage: "checkmark.circle") }
            FlashcardView()
                .tabItem { Label("Flashcards", systemImage: "rectangle.on.rectangle") }
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

// MARK: - Quiz setup
struct QuizSetupView: View {
    @EnvironmentObject var store: Store
    @State private var domain: Int = 0      // 0 == all
    @State private var count: Int = 20
    @State private var instant = true
    @State private var active = false
    @State private var weakMode = false

    var pool: [Question] {
        weakMode ? questions(forDomain: nil, weak: store.wrongIDs)
                 : questions(forDomain: domain == 0 ? nil : domain, weak: nil)
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
                    Stepper("Questions: \(count)", value: $count, in: 1...60, step: 5)
                    Toggle("Instant feedback", isOn: $instant)
                }
                Section {
                    Button("Start quiz") { weakMode = false; active = true }
                        .disabled(pool.isEmpty)
                    Button("Drill my weak questions") { weakMode = true; active = true }
                        .disabled(store.wrongIDs.isEmpty)
                }
                Section("Exam blueprint") {
                    Text("125 items · 3 hours · pass at 700/1000. Domain weights:")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(1...7, id: \.self) { d in
                        HStack {
                            Text("D\(d)").frame(width: 34, alignment: .leading)
                            ProgressView(value: Double(WEIGHTS[d]!), total: 22)
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
                let n = weakMode ? pool.count : min(count, pool.count)
                QuizView(items: Array(pool.shuffled().prefix(n)), instant: instant)
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
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: Double(idx), total: Double(items.count))
            Text("Question \(idx + 1) of \(items.count) · D\(q.domain)")
                .font(.caption).foregroundStyle(.secondary)
            Text(q.text).font(.title3).bold()

            ForEach(order, id: \.self) { i in
                Button { pick(i) } label: {
                    HStack {
                        Text(q.options[i]).multilineTextAlignment(.leading)
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
                    .font(.callout).padding()
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
            HStack {
                Button("Quit") { dismiss() }.foregroundStyle(.secondary)
                Spacer()
                if chosen != nil {
                    Button(idx + 1 >= items.count ? "Finish" : "Next →") { next() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }

    func bg(for i: Int) -> Color {
        guard let c = chosen else { return Color.gray.opacity(0.08) }
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
                .onChange(of: domain) { _, _ in build() }

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

                    HStack {
                        Button("← Prev") { move(-1) }
                        Spacer()
                        Button("Flip") { flipped.toggle() }.buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Next →") { move(1) }
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
