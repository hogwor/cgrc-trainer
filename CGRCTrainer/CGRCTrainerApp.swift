import SwiftUI

// MARK: - App entry
@main
struct CGRCTrainerApp: App {
    @StateObject private var store = Store()
    @State private var splashDone = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView().environmentObject(store)
                if !splashDone {
                    SplashView { splashDone = true }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.5), value: splashDone)
        }
    }
}

// MARK: - Splash screen
struct SplashView: View {
    let onFinished: () -> Void
    @State private var scale: CGFloat = 0.6
    @State private var iconOpacity: Double = 0
    @State private var textOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Image("CGRCIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 130, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .blue.opacity(0.6), radius: 24, x: 0, y: 8)
                    .scaleEffect(scale)
                    .opacity(iconOpacity)

                VStack(spacing: 6) {
                    Text("CGRC Trainer")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                    Text("ISC2 Exam Prep")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .opacity(textOpacity)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                scale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) {
                textOpacity = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                onFinished()
            }
        }
    }
}

// MARK: - Model
struct Question: Identifiable {
    let id: Int
    let domain: Int
    let text: String
    let options: [String]
    let answer: Int          // index of correct option
    let explain: String
}

let DOMAINS: [Int: String] = [
    1: "Governance, Risk Mgmt & Compliance Program",
    2: "Scope of the System",
    3: "Selection & Approval of Framework & Controls",
    4: "Implementation of Controls",
    5: "Assessment/Audit of Controls",
    6: "System Compliance",
    7: "Compliance Maintenance"
]
let WEIGHTS: [Int: Int] = [1:16, 2:10, 3:14, 4:17, 5:16, 6:14, 7:13]   // ISC² CGRC exam outline, effective 2024-06-15

// MARK: - Spaced-repetition mastery (Leitner)
/// Per-question learning state. `box` is the Leitner level: 0 = new/lapsed …
/// MASTERY_BOX = mastered. A correct answer promotes one box; a wrong answer
/// drops to box 0. `due` is when the item should next be reviewed.
struct ItemStat {
    var box: Int = 0
    var seen: Int = 0
    var correct: Int = 0
    var due: Date = .distantPast   // distantPast = due now
    var last: Date? = nil
}

let MASTERY_BOX = 5
/// Review interval per box, in days (index == box). Mastered items wait 30 days.
let BOX_INTERVALS_DAYS: [Double] = [0, 1, 3, 7, 14, 30]

// MARK: - Persistence
final class Store: ObservableObject {
    @Published var answered = 0
    @Published var correct = 0
    @Published var quizzes = 0
    @Published var domA: [Int:Int] = [:]   // attempts per domain
    @Published var domC: [Int:Int] = [:]   // correct per domain
    @Published var wrongIDs: Set<Int> = []
    @Published var items: [Int: ItemStat] = [:]   // per-question mastery state

    private let key = "cgrc_trainer_v1"

    init() { load() }

    // MARK: Derived mastery metrics
    var seenCount: Int { items.count }
    var masteredCount: Int { items.values.filter { $0.box >= MASTERY_BOX }.count }
    /// Seen, not-yet-mastered items whose review interval has elapsed.
    var dueIDs: Set<Int> {
        let now = Date()
        return Set(items.filter { $0.value.seen > 0 && $0.value.box < MASTERY_BOX && $0.value.due <= now }.keys)
    }
    /// Counts per Leitner box, index 0…MASTERY_BOX.
    func boxCounts() -> [Int] {
        var b = [Int](repeating: 0, count: MASTERY_BOX + 1)
        for s in items.values { b[min(MASTERY_BOX, max(0, s.box))] += 1 }
        return b
    }

    /// Apply a Leitner promotion/demotion and reschedule the next review.
    private func bump(_ id: Int, isCorrect: Bool) {
        var st = items[id] ?? ItemStat()
        st.seen += 1
        st.last = Date()
        if isCorrect {
            st.correct += 1
            st.box = min(MASTERY_BOX, st.box + 1)
            wrongIDs.remove(id)
        } else {
            st.box = 0
            wrongIDs.insert(id)
        }
        let days = BOX_INTERVALS_DAYS[min(st.box, BOX_INTERVALS_DAYS.count - 1)]
        st.due = Date().addingTimeInterval(days * 86_400)
        items[id] = st
    }

    /// A graded quiz answer: updates accuracy stats AND mastery scheduling.
    func record(domain: Int, id: Int, isCorrect: Bool) {
        answered += 1
        domA[domain, default: 0] += 1
        if isCorrect { correct += 1; domC[domain, default: 0] += 1 }
        bump(id, isCorrect: isCorrect)
        save()
    }

    /// A flashcard self-rating: feeds mastery scheduling only, so it doesn't
    /// pollute quiz accuracy metrics.
    func reviewCard(id: Int, isCorrect: Bool) {
        bump(id, isCorrect: isCorrect)
        save()
    }

    func finishQuiz() { quizzes += 1; save() }

    func reset() {
        answered = 0; correct = 0; quizzes = 0
        domA = [:]; domC = [:]; wrongIDs = []; items = [:]
        save()
    }

    private func save() {
        var itemDict: [String: [Double]] = [:]
        for (id, s) in items {
            itemDict[String(id)] = [Double(s.box), Double(s.seen), Double(s.correct),
                                    s.due.timeIntervalSince1970,
                                    s.last?.timeIntervalSince1970 ?? -1]
        }
        let dict: [String: Any] = [
            "answered": answered, "correct": correct, "quizzes": quizzes,
            "domA": domA.mapKeys { String($0) },
            "domC": domC.mapKeys { String($0) },
            "wrong": Array(wrongIDs),
            "items": itemDict
        ]
        UserDefaults.standard.set(dict, forKey: key)
    }

    private func load() {
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return }
        answered = d["answered"] as? Int ?? 0
        correct = d["correct"] as? Int ?? 0
        quizzes = d["quizzes"] as? Int ?? 0
        if let a = d["domA"] as? [String:Int] { domA = a.mapKeys { Int($0) ?? 0 } }
        if let c = d["domC"] as? [String:Int] { domC = c.mapKeys { Int($0) ?? 0 } }
        if let w = d["wrong"] as? [Int] { wrongIDs = Set(w) }
        if let it = d["items"] as? [String: [Double]] {
            var m: [Int: ItemStat] = [:]
            for (k, v) in it where v.count >= 4 {
                guard let id = Int(k) else { continue }
                var s = ItemStat()
                s.box = Int(v[0]); s.seen = Int(v[1]); s.correct = Int(v[2])
                s.due = Date(timeIntervalSince1970: v[3])
                if v.count >= 5, v[4] >= 0 { s.last = Date(timeIntervalSince1970: v[4]) }
                m[id] = s
            }
            items = m
        }
    }
}

extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        var out: [T: Value] = [:]
        for (k, v) in self { out[transform(k)] = v }
        return out
    }
}
