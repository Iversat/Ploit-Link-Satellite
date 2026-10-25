import SwiftUI

struct PointingConversation: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sensors: Sensors
    @StateObject private var chat = DemoChat()
    @State private var draft = ""
    @FocusState private var typing: Bool
    private var available: Bool { model.target != nil && sensors.motionReady }
    private var projection: RearAimProjection? {
        guard let target = model.target,let basis = sensors.lastBasis else { return nil }
        return .init(azimuth:target.az,elevation:target.el,basis:basis)
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing:10) {
                HStack {
                    Button { typing = false; model.pointingMessages = false } label: {
                        Image(systemName:"chevron.left").frame(width:44,height:44)
                    }.accessibilityLabel("Вернуться к наведению").accessibilityIdentifier("closeDemoChat")
                    Spacer()
                    VStack(spacing:2) {
                        Text("Тренировка · сообщения").font(.subheadline.weight(.semibold))
                        Text(model.satellite?.name ?? "Учебный спутник").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { typing = false; model.leavePointing() } label: {
                        Image(systemName:"xmark").frame(width:44,height:44)
                    }.accessibilityLabel("Завершить наведение").accessibilityIdentifier("finishPointing")
                }
                HStack(spacing:18) {
                    Group {
                        if model.axis == .back { RearAimReticle(projection:projection,aligned:model.aligned,available:available) }
                        else { RadarDial(bearingError:model.target.map { AimMath.wrap($0.az-sensors.azimuth) } ?? 0,aligned:model.aligned,available:available) }
                    }.frame(width:min(150,max(86,geometry.size.height*0.25)),height:min(150,max(86,geometry.size.height*0.25)))
                        .accessibilityIdentifier("conversationAim")
                    VStack(alignment:.leading,spacing:6) {
                        Text(model.aligned ? "Держите направление":"Вернитесь к спутнику")
                            .font(.headline).foregroundStyle(model.aligned ? .green:.orange)
                            .accessibilityIdentifier("conversationAimStatus")
                        Text(model.axis == .back ? "Удерживайте спутник в центре прицела":"Направляйте верхнюю грань на спутник")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = model.angularError {
                            Text("Отклонение \(Int(error))°").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.padding(.horizontal,8)
                AimAxisPicker(axis:$model.axis).padding(.horizontal,6)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing:10) {
                            Text("Учебный диалог · отвечает симулятор · без передачи в эфир")
                                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.vertical,8)
                            ForEach(chat.messages) { item in
                                HStack {
                                    if item.outgoing { Spacer(minLength:35) }
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(item.text).font(.subheadline)
                                        Text("\(item.date.formatted(date:.omitted,time:.shortened)) · ТЕСТ")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }.padding(12).background(item.outgoing ? Color.green.opacity(0.16):.white.opacity(0.08),in:RoundedRectangle(cornerRadius:18))
                                    if !item.outgoing { Spacer(minLength:35) }
                                }.id(item.id)
                            }
                            if chat.replying { Text("Симулятор отвечает…").font(.caption).foregroundStyle(.secondary) }
                            Color.clear.frame(height:1).id("conversationBottom")
                        }.padding(.horizontal,8)
                    }.scrollDismissesKeyboard(.interactively)
                        .onChange(of:chat.messages.count) { _,_ in withAnimation { proxy.scrollTo("conversationBottom",anchor:.bottom) } }
                        .onChange(of:typing) { _,_ in proxy.scrollTo("conversationBottom",anchor:.bottom) }
                }
            }.padding(.horizontal,16)
        }
        .safeAreaInset(edge:.bottom,spacing:0) {
            VStack(spacing:5) {
                HStack(alignment:.bottom,spacing:10) {
                    TextField("Сообщение",text:$draft,axis:.vertical).lineLimit(1...3).focused($typing)
                        .padding(12).background(.white.opacity(0.09),in:RoundedRectangle(cornerRadius:20))
                        .accessibilityIdentifier("demoMessageInput")
                    Button {
                        guard model.aligned else { return }
                        chat.send(draft,satellite:model.satellite?.name ?? "Учебный спутник"); draft = ""
                    } label: {
                        Image(systemName:"arrow.up").font(.headline).frame(width:44,height:44)
                            .background(model.aligned ? Color.green:Color.gray,in:Circle()).foregroundStyle(.black)
                    }.disabled(!DemoChat.valid(draft) || chat.replying || !model.aligned)
                        .accessibilityLabel("Отправить тестовое сообщение").accessibilityIdentifier("sendDemoMessage")
                    if typing {
                        Button { typing = false } label: { Image(systemName:"keyboard.chevron.compact.down").frame(width:32,height:44) }
                            .accessibilityLabel("Скрыть клавиатуру")
                    }
                }
                Text(model.aligned ? "\(draft.count)/280 · тестовый режим":"Совместите направление, чтобы отправить · текст сохранён")
                    .font(.caption2).foregroundStyle(model.aligned ? .secondary:Color.orange)
            }.padding(.horizontal,20).padding(.vertical,8).background(.ultraThinMaterial)
        }
        .background(Color(red:0.025,green:0.03,blue:0.04).ignoresSafeArea())
        .onDisappear { chat.stopReply() }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(where:{ $0.hasPrefix("--ui-screenshot-demo-chat") }) {
                try? await Task.sleep(nanoseconds:500_000_000)
                typing = true
            }
            #endif
        }
        .preferredColorScheme(.dark).tint(.white)
    }
}
