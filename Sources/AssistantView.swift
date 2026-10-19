import SwiftUI

struct SatelliteGlyph: View {
    var body: some View {
        GeometryReader { g in
            let u = g.size.width / 24
            ZStack {
                RoundedRectangle(cornerRadius: 2*u).frame(width:6*u,height:10*u)
                HStack(spacing:8*u) {
                    RoundedRectangle(cornerRadius:u).frame(width:6*u,height:8*u)
                    RoundedRectangle(cornerRadius:u).frame(width:6*u,height:8*u)
                }
                Rectangle().frame(width:16*u,height:u)
                Rectangle().frame(width:u,height:5*u).offset(y:-7*u)
                Circle().frame(width:3*u,height:3*u).offset(y:-10*u)
            }.rotationEffect(.degrees(38)).frame(width:g.size.width,height:g.size.height)
        }.aspectRatio(1,contentMode:.fit)
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12),lineWidth: 0.5))
    }
}

struct AssistantView: View {
    @EnvironmentObject var model: AppModel
    @State private var sheet: Sheet?
    enum Sheet: String, Identifiable { case satellites, passes, settings; var id: String { rawValue } }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                EarthView(latitude: model.observer?.latitude ?? 35, longitude: model.observer?.longitude ?? 35)
                    .ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.2),.clear,.black.opacity(0.12),.black.opacity(0.65)], startPoint: .top,endPoint: .bottom).ignoresSafeArea()
                if model.pointing { PointingView() } else {
                    VStack(spacing: 0) {
                        header
                        Spacer(minLength: 40)
                        Circle().fill(.white.opacity(0.45)).frame(width: 12,height: 12)
                            .overlay(Circle().stroke(.white,lineWidth: 3).frame(width: 19,height: 19))
                            .shadow(color: .white.opacity(0.5),radius: 12).accessibilityLabel("Ваше местоположение на иллюстрации Земли")
                        Spacer(minLength: 34)
                        VStack(spacing: 12) {
                            status
                            Button { model.enterPointing() } label: {
                                GlassPanel {
                                    HStack(spacing: 12) {
                                        Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 22,weight: .medium)).frame(width: 42,height: 42).background(.black.opacity(0.7),in: RoundedRectangle(cornerRadius: 12))
                                        VStack(alignment: .leading,spacing: 3) {
                                            Text("Наведение на спутник").font(.system(size: 16,weight: .medium))
                                            Text(model.satellite?.name ?? "Выберите спутник").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 14,weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                                    }
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("startPointing")
                            HStack(spacing: 12) {
                                smallButton("Спутники",icon:"globe.europe.africa.fill") { sheet = .satellites }
                                smallButton("Пролёты",icon:"clock.arrow.circlepath") { sheet = .passes }
                            }
                        }
                        .padding(.horizontal,22)
                        Spacer().frame(height: max(30,geometry.size.height * 0.09))
                        HStack(spacing: 6) {
                            Image(systemName: "location.fill").font(.system(size: 9))
                            Text(model.manualLocation ? "Координаты заданы вручную" : model.observer == nil ? "Ожидание геопозиции" : "Геопозиция на устройстве")
                            Text("·").padding(.horizontal,3)
                            Text("PLOIT SPACE").tracking(1.5)
                        }.font(.system(size: 10,weight: .medium)).foregroundStyle(.white.opacity(0.45)).padding(.bottom,18)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.35),value: model.pointing)
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .satellites: SatellitePicker().environmentObject(model)
            case .passes: PassesView().environmentObject(model)
            case .settings: SettingsView().environmentObject(model)
            }
        }
    }
    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                SatelliteGlyph().foregroundStyle(.black).padding(4).frame(width:30,height:30).background(.white.opacity(0.85),in:RoundedRectangle(cornerRadius:8))
                Text("Connection Assistant").font(.system(size: 19,weight: .semibold))
            }
            Spacer(minLength: 6)
            Button { sheet = .settings } label: { Image(systemName: "ellipsis").font(.system(size: 18,weight: .bold)).frame(width: 36,height: 36).background(.white.opacity(0.1),in: Circle()) }.accessibilityLabel("Настройки")
        }.padding(.horizontal,24).padding(.top,14)
    }
    private var status: some View {
        GlassPanel {
            VStack(alignment: .leading,spacing: 6) {
                HStack {
                    Text(statusTitle).font(.system(size: 21,weight: .semibold))
                    Spacer()
                    if model.updating { ProgressView().tint(.white) }
                }
                Text(statusDetail).font(.system(size: 14)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private var statusTitle: String {
        if model.observer == nil { return "Нужно ваше положение" }
        if model.elements == nil { return "Нужны данные орбиты" }
        if !model.usable { return "Обновите орбиту" }
        return model.aboveHorizon ? "Спутник над горизонтом" : "Спутник вне видимости"
    }
    private var statusDetail: String {
        if model.observer == nil { return "Разрешите геопозицию или укажите координаты в настройках." }
        if model.elements == nil { return model.error ?? "Подключитесь к интернету один раз для загрузки TLE." }
        if !model.usable { return "Данным больше 14 дней. Наведение приостановлено до обновления." }
        if let look = model.look, model.aboveHorizon { return "\(model.satellite?.name ?? "") · высота \(Int(look.elevation))° · \(Int(look.rangeKm)) км\(model.stale ? "\nTLE старше 3 дней — возможна ошибка." : "")" }
        if let pass = model.passes.first { return "\(model.satellite?.name ?? "") · ближайшее окно \(pass.riseDate.formatted(date:.omitted,time:.shortened))." }
        return model.error ?? (model.predicting ? "Вычисляем ближайшие пролёты…" : "Ожидаем видимый пролёт выбранного спутника.")
    }
    private func smallButton(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action:action) {
            HStack(spacing: 8) { Image(systemName:icon); Text(text) }.font(.system(size: 14,weight: .medium)).frame(maxWidth:.infinity).padding(.vertical,15).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius:20).stroke(.white.opacity(0.1),lineWidth:0.5))
        }.buttonStyle(.plain)
    }
}

struct PointingView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { PointingContent(model:model,sensors:model.sensors) }
}

struct PointingContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sensors: Sensors
    @State private var lastAligned = false
    private var dx: Double { guard let t = model.target else { return 0 }; return AimMath.wrap(t.az - sensors.azimuth) }
    private var dy: Double { guard let t = model.target else { return 0 }; return t.el - sensors.elevation }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.leavePointing() } label: { Image(systemName:"chevron.left").font(.system(size:18,weight:.semibold)).frame(width:44,height:44).background(.ultraThinMaterial,in:Circle()) }.accessibilityLabel("Назад")
                Spacer()
                VStack(spacing:3) { Text(model.training ? "Тренировка наведения" : model.satellite?.name ?? "Спутник").font(.system(size:17,weight:.semibold)); Text(model.training ? "УСЛОВНАЯ ЦЕЛЬ · 135° / 45°" : model.mode?.name ?? "").font(.system(size:10,weight:.medium)).tracking(1.2).foregroundStyle(.white.opacity(0.5)) }
                Spacer()
                SatelliteGlyph().frame(width:24,height:24).frame(width:44,height:44).foregroundStyle(.white.opacity(0.7))
            }.padding(.horizontal,22).padding(.top,12)
            Spacer(minLength:20)
            VStack(spacing:10) {
                Text(instruction).font(.system(size:30,weight:.semibold)).multilineTextAlignment(.center).contentTransition(.numericText())
                Text(subtitle).font(.system(size:15)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
            }.padding(.horizontal,28)
            Spacer(minLength:20)
            ZStack {
                Circle().stroke(.white.opacity(0.1),lineWidth:1).frame(width:262,height:262)
                Circle().trim(from:0.06,to:0.44).stroke(.white.opacity(0.35),style:StrokeStyle(lineWidth:5,lineCap:.round)).frame(width:262,height:262).rotationEffect(.degrees(180))
                Circle().trim(from:0.06,to:0.44).stroke(.white.opacity(0.35),style:StrokeStyle(lineWidth:5,lineCap:.round)).frame(width:262,height:262)
                Circle().stroke(.white.opacity(0.15),style:StrokeStyle(lineWidth:1,dash:[2,7])).frame(width:205,height:205)
                Path { p in p.move(to:CGPoint(x:137,y:102));p.addLine(to:CGPoint(x:137,y:172));p.move(to:CGPoint(x:102,y:137));p.addLine(to:CGPoint(x:172,y:137)) }.stroke(.white.opacity(0.2),lineWidth:1)
                Image(systemName:"iphone").font(.system(size:62,weight:.ultraLight)).rotationEffect(.degrees(-12)).foregroundStyle(.white.opacity(0.65))
                if model.target != nil && sensors.motionReady {
                    Circle().fill(model.aligned ? Color.green : .white).frame(width:24,height:24).overlay(Circle().stroke(.white.opacity(0.45),lineWidth:1).frame(width:40,height:40))
                        .shadow(color:model.aligned ? .green.opacity(0.6) : .white.opacity(0.25),radius:16)
                        .offset(x:max(-115,min(115,dx*2.3)),y:max(-115,min(115,-dy*2.3)))
                }
                Image(systemName:dx>=0 ? "arrow.turn.up.right" : "arrow.turn.up.left").font(.system(size:20,weight:.medium)).offset(x:dx>=0 ? 118 : -118,y:-104).opacity(abs(dx)>8 && model.target != nil ? 1 : 0)
            }.frame(width:274,height:274).animation(.linear(duration:0.1),value:dx).animation(.linear(duration:0.1),value:dy)
            Spacer(minLength:20)
            VStack(spacing:12) {
                GlassPanel {
                    HStack {
                        metric("АЗИМУТ",value:model.target.map { "\(Int($0.az))°" } ?? "—")
                        Spacer(); Rectangle().fill(.white.opacity(0.15)).frame(width:1,height:35); Spacer()
                        metric("УГОЛ МЕСТА",value:model.target.map { "\(Int($0.el))°" } ?? "—")
                        Spacer(); Rectangle().fill(.white.opacity(0.15)).frame(width:1,height:35); Spacer()
                        metric("ОШИБКА",value:model.angularError.map { "\(Int($0))°" } ?? "—")
                    }
                }
                GlassPanel {
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:model.aligned ? "checkmark.circle.fill" : "info.circle").foregroundStyle(model.aligned ? .green : .white.opacity(0.6))
                        Text(footer).font(.system(size:12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }.padding(.horizontal,22)
            Spacer().frame(height:24)
        }
        .background(.black.opacity(0.38))
        .onChange(of:model.aligned) { _, aligned in if aligned && !lastAligned { UINotificationFeedbackGenerator().notificationOccurred(.success) };lastAligned=aligned }
    }
    private var instruction: String {
        if !sensors.motionReady { return "Подготовьте телефон" }
        if model.target == nil { return "Нужны данные орбиты" }
        if !model.training && !model.aboveHorizon { return "Спутник за горизонтом" }
        if model.aligned { return "Держите направление" }
        if abs(dx)>10 { return dx>0 ? "Поверните вправо" : "Поверните влево" }
        return dy>0 ? "Поднимите телефон" : "Опустите телефон"
    }
    private var subtitle: String {
        if !sensors.motionReady { return sensors.message }
        if !model.training && !model.aboveHorizon { return "Дождитесь следующего пролёта" }
        return model.axis == .top ? "Направьте верхний торец на спутник" : "Направьте заднюю сторону на спутник"
    }
    private var footer: String {
        if model.training { return "Учебная цель. Совпадение направления не означает спутниковое соединение." }
        if model.observer == nil { return "Нет положения наблюдателя. Разрешите геопозицию или задайте координаты." }
        if !sensors.northIsTrue { return "Используется магнитный север. Для точного наведения нужен истинный север и калибровка компаса." }
        if sensors.headingAccuracy < 0 || sensors.headingAccuracy>20 { return "Компас неточен. Уберите магниты и металлические предметы, откалибруйте телефон движением восьмёркой." }
        return "Это направление по орбите. Для связи нужен внешний радиомодуль; наличие сигнала здесь не измеряется."
    }
    private func metric(_ title:String,value:String)->some View { VStack(alignment:.leading,spacing:5) { Text(title).font(.system(size:8,weight:.semibold)).tracking(1).foregroundStyle(.white.opacity(0.4));Text(value).font(.system(size:23,weight:.medium,design:.rounded)).monospacedDigit() } }
}
