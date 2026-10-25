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

struct DemoChatView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var chat = DemoChat()
    @State private var draft = ""
    @State private var chooseSatellite = false
    @State private var clearConfirmation = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing:16) {
                        VStack(spacing:8) {
                            Image(systemName:"antenna.radiowaves.left.and.right").font(.system(size:30)).foregroundStyle(.cyan)
                            Text("Тестовый диалог").font(.title2.bold())
                            Text("Сообщения и ответы остаются на этом iPhone. Радиомодуль не подключён, передача через спутник не выполняется.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(22).frame(maxWidth:.infinity).satelliteGlass(in:RoundedRectangle(cornerRadius:26))
                        Button { chooseSatellite = true } label: {
                            HStack { Image(systemName:"satellite.fill"); Text(model.satellite?.name ?? "Выбрать спутник"); Spacer(); Image(systemName:"chevron.down") }
                                .padding(16).satelliteGlass(in:Capsule(),interactive:true)
                        }.buttonStyle(.plain)
                        ForEach(chat.messages) { item in
                            HStack {
                                if item.outgoing { Spacer(minLength:32) }
                                VStack(alignment:.leading,spacing:7) {
                                    Text(item.text).textSelection(.enabled)
                                    Text("\(item.satellite) · \(item.date.formatted(date:.omitted,time:.shortened)) · ТЕСТ")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }.padding(14).background(item.outgoing ? Color.cyan.opacity(0.18):.white.opacity(0.09),in:RoundedRectangle(cornerRadius:20))
                                if !item.outgoing { Spacer(minLength:32) }
                            }.id(item.id)
                        }
                        if chat.replying { HStack { ProgressView(); Text("Симулятор отвечает…").font(.caption).foregroundStyle(.secondary); Spacer() } }
                        Color.clear.frame(height:1).id("chatBottom")
                    }.padding(20)
                }.scrollDismissesKeyboard(.interactively)
                    .onChange(of:chat.messages.count) { _,_ in withAnimation { proxy.scrollTo("chatBottom",anchor:.bottom) } }
            }
            .safeAreaInset(edge:.bottom) {
                VStack(spacing:5) {
                    HStack(alignment:.bottom,spacing:12) {
                        TextField("Тестовое сообщение",text:$draft,axis:.vertical).lineLimit(1...4).focused($typing)
                            .padding(12).background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:20))
                            .accessibilityIdentifier("demoMessageInput")
                        Button {
                            chat.send(draft,satellite:model.satellite?.name ?? "Спутник"); draft = ""
                        } label: { Image(systemName:"arrow.up").font(.headline).frame(width:44,height:44).background(.cyan,in:Circle()).foregroundStyle(.black) }
                            .disabled(!DemoChat.valid(draft) || chat.replying).opacity(DemoChat.valid(draft) && !chat.replying ? 1:0.4)
                            .accessibilityLabel("Отправить тестовое сообщение").accessibilityIdentifier("sendDemoMessage")
                    }
                    Text("\(draft.count)/280 · Только симуляция").font(.caption2).foregroundStyle(draft.count > 280 ? .red:.secondary)
                }.padding(.horizontal,20).padding(.vertical,10).background(.ultraThinMaterial)
            }
            .background(Color.black).navigationTitle("Сообщения").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button { clearConfirmation = true } label: { Image(systemName:"trash") }.accessibilityLabel("Очистить тестовый диалог") }
                ToolbarItem(placement:.topBarTrailing) { Button("Готово") { typing = false; dismiss() }.accessibilityIdentifier("closeDemoChat") }
            }
            .confirmationDialog("Удалить тестовые сообщения?",isPresented:$clearConfirmation,titleVisibility:.visible) {
                Button("Удалить",role:.destructive) { chat.clear() }
            }
            .sheet(isPresented:$chooseSatellite) { SatellitePicker().environmentObject(model) }
            .onDisappear { chat.stopReply() }
        }.preferredColorScheme(.dark).tint(.white)
    }
}
