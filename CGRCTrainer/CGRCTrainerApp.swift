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
    3: "Selection & Approval of Controls",
    4: "Implementation of Controls",
    5: "Assessment/Audit of Controls",
    6: "System Compliance",
    7: "Compliance Maintenance"
]
let WEIGHTS: [Int: Int] = [1:16, 2:11, 3:15, 4:16, 5:15, 6:10, 7:17]   // ISC² 2023 blueprint

// MARK: - Persistence
final class Store: ObservableObject {
    @Published var answered = 0
    @Published var correct = 0
    @Published var quizzes = 0
    @Published var domA: [Int:Int] = [:]   // attempts per domain
    @Published var domC: [Int:Int] = [:]   // correct per domain
    @Published var wrongIDs: Set<Int> = []

    private let key = "cgrc_trainer_v1"

    init() { load() }

    func record(domain: Int, id: Int, isCorrect: Bool) {
        answered += 1
        domA[domain, default: 0] += 1
        if isCorrect {
            correct += 1
            domC[domain, default: 0] += 1
            wrongIDs.remove(id)
        } else {
            wrongIDs.insert(id)
        }
        save()
    }

    func finishQuiz() { quizzes += 1; save() }

    func reset() {
        answered = 0; correct = 0; quizzes = 0
        domA = [:]; domC = [:]; wrongIDs = []
        save()
    }

    private func save() {
        let dict: [String: Any] = [
            "answered": answered, "correct": correct, "quizzes": quizzes,
            "domA": domA.mapKeys { String($0) },
            "domC": domC.mapKeys { String($0) },
            "wrong": Array(wrongIDs)
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
    }
}

extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        var out: [T: Value] = [:]
        for (k, v) in self { out[transform(k)] = v }
        return out
    }
}
