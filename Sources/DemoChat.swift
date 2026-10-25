import SwiftUI

struct DemoMessage: Codable, Identifiable {
    var id = UUID()
    var text: String
    var outgoing: Bool
    var satellite: String
    var date = Date()
}

@MainActor final class DemoChat: ObservableObject {
    @Published private(set) var messages: [DemoMessage] = []
    @Published private(set) var replying = false
    private let defaults: UserDefaults
    private var reply: Task<Void,Never>?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey:"demoChatMessages"),
           let saved = try? JSONDecoder().decode([DemoMessage].self,from:data) { messages = Array(saved.suffix(100)) }
    }
    static func valid(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 280
    }
    func send(_ text: String, satellite: String) {
        guard Self.valid(text), !replying else { return }
        messages.append(.init(text:text.trimmingCharacters(in:.whitespacesAndNewlines),outgoing:true,satellite:satellite))
        save(); replying = true
        reply = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:800_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            messages.append(.init(text:"Сообщение получено в тестовом диалоге. Это ответ симулятора.",outgoing:false,satellite:satellite))
            replying = false; reply = nil; save()
        }
    }
    func stopReply() { reply?.cancel(); reply = nil; replying = false }
    func clear() { stopReply(); messages = []; save() }
    private func save() {
        messages = Array(messages.suffix(100))
        if let data = try? JSONEncoder().encode(messages) { defaults.set(data,forKey:"demoChatMessages") }
    }
}
