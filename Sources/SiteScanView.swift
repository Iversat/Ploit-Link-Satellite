import SwiftUI

enum SkyScanPathRefresh {
    static func timeSlice(for pass: PassWindow?, at date: Date) -> Int {
        guard let pass, pass.contains(date) else { return 0 }
        return Int(floor(date.timeIntervalSince1970 / 30))
    }
}

struct SiteScanView: View {
    private enum Screen { case introduction, scanning, result, inspecting }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var scan = SkyScanController()
    @State private var screen: Screen = .introduction
    @State private var information = false
    @State private var starting = false
    @State private var path: [SkyDirection] = []
    @State private var pathMessage = "Рассчитываем путь пролёта…"
    @State private var captureTask: Task<Void,Never>?
    @State private var engine = OrbitEngine()
    private var pass: PassWindow? { model.session(for:model.selectedID) }
    private var assessment: SkyAssessment { scan.survey.assessment(path:path) }
    private var cameraScreen: Bool { screen == .scanning || screen == .inspecting }
    private var pathKey: String {
        let location = String(format:"%.3f/%.3f",model.observer?.latitude ?? 0,model.observer?.longitude ?? 0)
        return "\(model.selectedID)|\(pass?.rise ?? 0)|\(model.elements?.line1 ?? "")|\(location)|\(model.minElevation)|\(SkyScanPathRefresh.timeSlice(for:pass,at:model.clock))"
    }
    private var preview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-screenshot-site-") })
        #else
        return false
        #endif
    }
    private var capturePreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--ui-screenshot-site-capture")
        #else
        return false
        #endif
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cameraScreen { cameraLayer.ignoresSafeArea(); cameraControls }
            else { VStack(spacing:0) { header; ScrollView { if screen == .result { resultContent } else { introduction } }.scrollIndicators(.hidden) } }
        }.foregroundStyle(.white).preferredColorScheme(.dark)
            .sheet(isPresented:$information) { informationSheet }
            .task(id:pathKey) { await loadPath() }
            .onAppear {
                #if DEBUG
                if preview { scan.preview(capture:capturePreview); screen = capturePreview ? .scanning:.result }
                #endif
            }
            .task {
                while !Task.isCancelled {
                    if !preview {
                        scan.checkLocation(model.observer)
                        scan.headingReady = model.sensors.northIsTrue && model.sensors.headingAccuracy >= 0 && model.sensors.headingAccuracy <= 20
                    }
                    do { try await Task.sleep(nanoseconds:500_000_000) } catch { return }
                }
            }
            .onChange(of:phase) { _,value in
                if value == .background {
                    captureTask?.cancel(); starting = false
                    scan.invalidate("Проверка сброшена после сворачивания. Начните заново у антенны."); screen = .introduction
                }
            }
            .onChange(of:scan.running) { _,running in
                if !running && cameraScreen && !preview { screen = scan.survey.hasRecordedData ? .result:.introduction }
            }
            .onDisappear { captureTask?.cancel(); scan.stop() }
    }
    private var header: some View {
        HStack {
            Button(action:close) { Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle()) }
                .accessibilityLabel("Закрыть проверку места").accessibilityIdentifier("closeSiteScan")
            Spacer()
            Text(cameraScreen ? (screen == .inspecting ? "Осмотр места":"Сканирование") : (screen == .result ? "Обзор неба":"Проверка места"))
                .font(.system(size:17,weight:.semibold))
            Spacer()
            Button {
                if cameraScreen { captureTask?.cancel(); scan.finish(); screen = .result }
                information = true
            } label: { Image(systemName:"info.circle").frame(width:44,height:44) }.accessibilityLabel("О проверке места")
        }.padding(.horizontal,12).padding(.vertical,4).background(cameraScreen ? Color.black.opacity(0.25):.clear)
    }
    private var introduction: some View {
        VStack(alignment:.leading,spacing:28) {
            ZStack {
                Circle().stroke(.white.opacity(0.12),style:StrokeStyle(lineWidth:1,dash:[2,9])).frame(width:230,height:230)
                Circle().stroke(.white.opacity(0.06),lineWidth:1).frame(width:180,height:180)
                Image(systemName:"iphone.gen3.radiowaves.left.and.right").font(.system(size:76,weight:.ultraLight))
                Image(systemName:"arrow.up").font(.system(size:24,weight:.light)).offset(y:-82)
            }.frame(maxWidth:.infinity).frame(height:255)
            VStack(alignment:.leading,spacing:12) {
                Text("Найдите открытое небо").font(.system(size:30,weight:.semibold))
                Text("Проверьте обзор из точки, где будет находиться антенна.").font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
            instruction("1",title:"Поднимите камеру",detail:"Останьтесь на одном месте и направьте заднюю камеру в небо.")
            instruction("2",title:"Соберите точки",detail:"Медленно поворачивайте телефон. Точки фиксируются в центральной области камеры.")
            instruction("3",title:"Отметьте препятствия",detail:"Подтвердите небо и дальние препятствия кнопками. LiDAR дополнит карту близкими поверхностями.")
            Text(scan.message).font(.caption).foregroundStyle(.white.opacity(0.55)).accessibilityIdentifier("scanStatus")
            primary("Начать сканирование",id:"startSiteScan") { start(collecting:true) }
        }.padding(24)
    }
    private var resultContent: some View {
        VStack(spacing:22) {
            if preview { Text("Пример карты · не результат измерения").font(.caption).foregroundStyle(.white.opacity(0.5)) }
            SkyDomeView(survey:scan.survey,path:path,direction:nil).frame(height:330)
            HStack(spacing:18) {
                legend("Неизвестно",color:Color(white:0.25)); legend("Открыто",color:.white); legend("Препятствия",color:Color(red:1,green:0.18,blue:0.25))
            }.font(.system(size:11))
            Text("Вращайте карту пальцем · вверх и вниз — наклон").font(.caption).foregroundStyle(.white.opacity(0.4))
            VStack(alignment:.leading,spacing:10) {
                HStack(alignment:.top,spacing:12) {
                    Image(systemName:assessment.blocked > 0 ? "exclamationmark.circle":"viewfinder")
                    VStack(alignment:.leading,spacing:6) {
                        Text(assessment.title).font(.system(size:15,weight:.semibold)).accessibilityIdentifier("siteAssessment")
                        Text(assessment.detail).font(.caption).foregroundStyle(.white.opacity(0.65))
                    }
                }
                Text(pathMessage).font(.caption).foregroundStyle(.white.opacity(0.5))
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                .background(assessment.blocked > 0 ? Color.yellow.opacity(0.07):Color.white.opacity(0.04))
                .overlay(Rectangle().stroke(assessment.blocked > 0 ? Color.yellow.opacity(0.5):Color.white.opacity(0.15),lineWidth:0.7))
            HStack { Text("Просмотрено неба").foregroundStyle(.white.opacity(0.55)); Spacer(); Text("\(Int(scan.coverageFraction*100))%").monospacedDigit() }.font(.system(size:13))
            VStack(spacing:10) {
                primary("Осмотреть камерой",id:"inspectSiteScan",inverted:false) { start(collecting:false) }
                primary("Новое сканирование",id:"startSiteScan") { start(collecting:true) }
            }
            Text("Карта относится к этой точке. После перемещения выполните новое сканирование.").font(.caption).foregroundStyle(.white.opacity(0.5)).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("scanSnapshotNotice")
            if model.manualLocation { Text("Координаты в настройках должны совпадать с местом проверки.").font(.caption).foregroundStyle(.orange) }
            Text(scan.message).font(.caption).foregroundStyle(.white.opacity(0.45)).accessibilityIdentifier("scanStatus")
            Divider().overlay(.white.opacity(0.12))
            SiteWeatherView(observer:model.observer)
            Text("Обзор неба не подтверждает радиосвязь. Для связи нужны антенна, внешний модуль и работающий ретранслятор.").font(.caption).foregroundStyle(.white.opacity(0.45)).frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.horizontal,24).padding(.top,16).padding(.bottom,30)
    }
    private var cameraLayer: some View {
        GeometryReader { geometry in
            ZStack {
                if scan.running { SkyScanCamera(controller:scan) }
                else { LinearGradient(colors:[Color(red:0.12,green:0.23,blue:0.36),Color(red:0.02,green:0.06,blue:0.1)],startPoint:.top,endPoint:.bottom) }
                Canvas { context,size in
                    for target in scan.projectedTargets {
                        if screen == .scanning && target.collected { continue }
                        let point = CGPoint(x:target.x*size.width,y:target.y*size.height)
                        let radius: CGFloat = screen == .inspecting ? 5:4
                        let color: Color
                        switch target.state {
                        case .blocked: color = Color(red:1,green:0.2,blue:0.26)
                        case .clear: color = .white
                        case .observed: color = .gray
                        case .unknown: color = screen == .scanning ? Color(red:0.7,green:1,blue:0.73):Color(white:0.3)
                        }
                        context.fill(Path(ellipseIn:CGRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2)),with:.color(color))
                        if screen == .scanning && target.dwellFraction > 0 {
                            context.stroke(Path(ellipseIn:CGRect(x:point.x-8,y:point.y-8,width:16,height:16)),with:.color(.white.opacity(target.dwellFraction)),lineWidth:1)
                        }
                    }
                }.allowsHitTesting(false).accessibilityElement(children:.ignore)
                    .accessibilityLabel("Точки обзора камеры").accessibilityValue("\(scan.projectedTargets.count)")
                    .accessibilityIdentifier("skyCaptureDots")
                LinearGradient(colors:[.black.opacity(0.15),.clear,.black.opacity(0.65)],startPoint:.top,endPoint:.bottom).allowsHitTesting(false)
                cameraAim(size:geometry.size)
            }.frame(width:geometry.size.width,height:geometry.size.height)
        }
    }
    private var cameraControls: some View {
        VStack(spacing:0) {
            header
            if preview { Text("Демонстрация · камера не используется").font(.caption2).padding(8).background(.black.opacity(0.4),in:Capsule()) }
            Spacer(minLength:20)
            VStack(spacing:8) {
                HStack(alignment:.bottom) { Text(scan.message).font(.caption).foregroundStyle(.white.opacity(0.8)).accessibilityIdentifier("scanStatus"); Spacer(minLength:12); cameraCompass }
                if screen == .scanning {
                    HStack(spacing:10) {
                        Button { scan.mark(.clear) } label: { Label("Небо",systemImage:"checkmark").frame(maxWidth:.infinity).frame(height:44) }.background(.black.opacity(0.6)).accessibilityIdentifier("markSkyClear")
                        Button { scan.mark(.blocked) } label: { Label("Препятствие",systemImage:"xmark").frame(maxWidth:.infinity).frame(height:44) }.background(.black.opacity(0.6)).accessibilityIdentifier("markSkyBlocked")
                    }.font(.system(size:13,weight:.medium)).disabled(scan.direction == nil || !scan.running)
                }
                primary(screen == .inspecting ? "К карте":"Показать результат",id:"finishSiteScan") { captureTask?.cancel(); scan.finish(); screen = .result }
            }.padding(.horizontal,20).padding(.vertical,12)
        }
    }
    private func cameraAim(size: CGSize) -> some View {
        let diameter: CGFloat = size.height < 700 ? 120:160
        return ZStack {
            ZStack {
                Circle().stroke(.black.opacity(0.35),lineWidth:3)
                Circle().trim(from:0,to:screen == .inspecting ? 1:scan.coverageFraction).stroke(.white,style:StrokeStyle(lineWidth:3,lineCap:.round)).rotationEffect(.degrees(-90))
                if screen == .inspecting { Image(systemName:"plus").font(.system(size:32,weight:.ultraLight)) }
                else if let direction = scan.direction, direction.elevation >= 0 { Text("\(Int(scan.coverageFraction*100))%").font(.system(size:32,weight:.semibold)).monospacedDigit().accessibilityIdentifier("scanCoverage") }
                else { Image(systemName:"arrow.up").font(.system(size:52,weight:.light)) }
            }.frame(width:diameter,height:diameter).position(x:size.width/2,y:size.height/2)
            VStack(spacing:10) {
                Text(screen == .inspecting ? "ПОВОРАЧИВАЙТЕ ТЕЛЕФОН" : scan.direction == nil ? "НАПРАВЬТЕ КАМЕРУ В НЕБО" : "СОБЕРИТЕ ТОЧКИ ВОКРУГ СЕБЯ").font(.system(size:12,weight:.semibold)).tracking(1)
                if size.height >= 700 { Text(screen == .inspecting ? "Белое — открыто · красное — препятствие" : "Процент — охват камеры, не качество сигнала").font(.caption).foregroundStyle(.white.opacity(0.75)) }
            }.multilineTextAlignment(.center).frame(width:size.width-48)
                .position(x:size.width/2,y:size.height/2 + (size.height < 700 ? -diameter/2-38:diameter/2+50))
        }.allowsHitTesting(false)
    }
    private var cameraCompass: some View {
        ZStack {
            Circle().fill(.black.opacity(0.65)).frame(width:48,height:48)
            ForEach(0..<4) { index in
                Text(["С","В","Ю","З"][index]).font(.system(size:8,weight:.semibold)).offset(y:-17).rotationEffect(.degrees(Double(index)*90-(scan.direction?.azimuth ?? 0)))
            }
            Image(systemName:"location.north.fill").font(.system(size:10))
        }.frame(width:48,height:48).accessibilityLabel("Азимут \(Int(scan.direction?.azimuth ?? 0)) градусов")
    }
    private func instruction(_ number: String,title: String,detail: String) -> some View {
        HStack(alignment:.top,spacing:16) {
            Text(number).font(.system(size:14,weight:.medium)).frame(width:26,height:26).overlay(Circle().stroke(.white.opacity(0.45),lineWidth:1))
            VStack(alignment:.leading,spacing:5) { Text(title).font(.system(size:16,weight:.medium)); Text(detail).font(.system(size:13)).foregroundStyle(.white.opacity(0.55)) }
        }
    }
    private func primary(_ title: String,id: String,inverted: Bool = true,action: @escaping () -> Void) -> some View {
        Button(action:action) {
            HStack { if starting { ProgressView().tint(inverted ? .black:.white) }; Text(title).font(.system(size:15,weight:.semibold)) }
                .frame(maxWidth:.infinity).frame(height:52).foregroundStyle(inverted ? .black:.white).background(inverted ? Color.white:Color(white:0.1))
        }.buttonStyle(.plain).disabled(starting).accessibilityIdentifier(id)
    }
    private func legend(_ title: String,color: Color) -> some View { HStack(spacing:5) { Circle().fill(color).frame(width:7,height:7); Text(title) } }
    private func start(collecting: Bool) {
        captureTask?.cancel()
        #if DEBUG
        if preview { scan.preview(capture:true,collecting:collecting); screen = collecting ? .scanning:.inspecting; return }
        #endif
        starting = true
        captureTask = Task {
            await scan.start(observer:model.observer,collecting:collecting)
            guard !Task.isCancelled else { return }
            starting = false
            if scan.running { screen = collecting ? .scanning:.inspecting }
        }
    }
    private func close() { captureTask?.cancel(); scan.stop(); model.scannerPresented = false; dismiss() }
    private var informationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text("Процент — просмотренная площадь неба. Собранная точка ещё не означает, что в этом направлении нет препятствий.")
                    Text("Небо, дальние здания и деревья отмечаются по камере вручную. LiDAR отмечает близкие поверхности до 6 м; отсутствие глубины не означает открытое небо.")
                    Text("Белые точки — открытое небо, красные — препятствия. Тёмные и серые точки требуют проверки. Жёлтая линия — путь выбранного спутника.")
                    Text("В режиме осмотра поворачивайте телефон на том же месте. Отметки показаны в своих направлениях, карта при этом не дополняется.")
                    Text("Карта относится к одной точке. После перемещения начните новое сканирование. Стены и потолок следует отмечать как препятствия.")
                    Text("Кадры камеры обрабатываются на iPhone, не записываются и не отправляются. Карта хранится до закрытия проверки места. Компас и плохое освещение могут ограничивать точность.")
                }.font(.subheadline).foregroundStyle(.secondary).padding(24)
            }.navigationTitle("Проверка места").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Готово") { information = false } } }
        }.preferredColorScheme(.dark)
    }
    private func loadPath() async {
        path = []
        if preview { path = (0...60).map { .init(azimuth:Double($0)*3 + 90,elevation:20 + 55*sin(Double($0)/60 * .pi)) }; pathMessage = "Пример будущего пролёта"; return }
        guard let observer = model.observer, let elements = model.elements, let pass, elements.ageDays() <= 14 else { pathMessage = "Нужны геопозиция, свежая орбита и ближайший сеанс."; return }
        let start = max(Date(),pass.riseDate),end = pass.setDate
        guard start < end, elements.ageDays(at:end) <= 14 else { pathMessage = "Обновите прогноз пролёта."; return }
        do {
            var values: [SkyDirection] = []
            for index in 0...72 {
                try Task.checkCancellation()
                let date = start.addingTimeInterval(end.timeIntervalSince(start)*Double(index)/72)
                let look = try await engine.look(elements:elements,observer:observer,date:date)
                values.append(.init(azimuth:look.azimuth,elevation:look.elevation))
            }
            try Task.checkCancellation(); path = values
            pathMessage = "\(model.satellite?.name ?? "Спутник") · \(SessionText.interval(pass))"
        } catch is CancellationError {} catch { pathMessage = "Путь не рассчитан. Обновите орбитальные данные." }
    }
}
