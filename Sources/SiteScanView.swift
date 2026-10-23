import SwiftUI

private struct SkyCameraControlsPreference: PreferenceKey {
    static let defaultValue: [String:CGRect] = [:]
    static func reduce(value: inout [String:CGRect], nextValue: () -> [String:CGRect]) {
        value.merge(nextValue(),uniquingKeysWith:{ _,new in new })
    }
}

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
    @State private var followsPhone = false
    @State private var showPassPath = false
    @State private var starting = false
    @State private var cameraControlBounds: [String:CGRect] = [:]
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
    private var demoViewingDirection: SkyDirection? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-site-gyro") {
            return .init(azimuth:220,elevation:40)
        }
        #endif
        return nil
    }
    private var scanOriginLabel: String {
        guard let azimuth = scan.startAzimuth else { return "Направление ещё не записано" }
        let bearing = (azimuth.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360)
        let compass = ["С","СВ","В","ЮВ","Ю","ЮЗ","З","СЗ"][Int((bearing+22.5)/45)%8]
        return "Начало · \(compass) · \(Int(bearing.rounded())%360)°"
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cameraScreen { cameraLayer.ignoresSafeArea(); cameraControls }
            else { VStack(spacing:0) { header; ScrollView { if screen == .result { resultContent } else { introduction } }.scrollIndicators(.hidden) } }
        }.coordinateSpace(name:"siteCamera")
            .onPreferenceChange(SkyCameraControlsPreference.self) { cameraControlBounds = $0 }
            .foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
            .sheet(isPresented:$information) { informationSheet }
            .task(id:pathKey) { await loadPath() }
            .onAppear {
                #if DEBUG
                if preview {
                    scan.preview(capture:capturePreview)
                    screen = capturePreview ? .scanning:.result
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("--ui-screenshot-site-intro") { screen = .introduction }
                    if arguments.contains("--ui-screenshot-site-info") { information = true }
                    if arguments.contains("--ui-screenshot-site-gyro") { followsPhone = true }
                }
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
            Button(action:close) { Image(systemName:"xmark").frame(width:44,height:44).contentShape(Circle()).satelliteGlass(in:Circle(),interactive:true) }
                .accessibilityLabel("Закрыть проверку места").accessibilityIdentifier("closeSiteScan")
            Spacer()
            Text(cameraScreen ? (screen == .inspecting ? "Осмотр места":"Сканирование") : (screen == .result ? "Обзор неба":"Проверка места"))
                .font(.system(size:17,weight:.semibold))
            Spacer()
            Button {
                if cameraScreen { captureTask?.cancel(); scan.finish(); screen = .result }
                information = true
            } label: { Image(systemName:"info.circle").frame(width:44,height:44).satelliteGlass(in:Circle(),interactive:true) }.accessibilityLabel("О проверке места").accessibilityIdentifier("siteScanInformation")
        }.buttonStyle(.plain).padding(.horizontal,20).padding(.vertical,8)
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
            SkyDomeView(survey:scan.survey,path:path,direction:nil,
                        viewingDirection:demoViewingDirection,
                        startAzimuth:scan.startAzimuth,followsPhone:followsPhone,
                        showPassPath:showPassPath,sensors:model.sensors).frame(height:310)
            HStack(spacing:18) {
                legend("Неизвестно",color:Color(white:0.25)); legend("Открыто",color:.white); legend("Препятствия",color:Color(red:1,green:0.18,blue:0.25))
            }.font(.system(size:11))
            Picker("Режим обзора",selection:$followsPhone) {
                Text("От точки старта").tag(false)
                Text("Гироскоп").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("skyViewMode")
            Text(followsPhone ? "Поворачивайте iPhone на месте — карта следует за направлением задней камеры." : "Человек с телефоном смотрит к началу сканирования. Вращайте карту пальцем, чтобы осмотреть другие стороны.")
                .font(.caption).foregroundStyle(.white.opacity(0.6)).frame(maxWidth:.infinity,alignment:.leading)
            HStack {
                Label(scanOriginLabel,systemImage:"location.north")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                Spacer(minLength:8)
                Button { showPassPath.toggle() } label: {
                    Label("Путь спутника",systemImage:showPassPath ? "eye":"eye.slash")
                        .font(.system(size:11,weight:.medium)).padding(.horizontal,12).padding(.vertical,10)
                        .satelliteGlass(in:Capsule(),interactive:true)
                }.buttonStyle(.plain).accessibilityIdentifier("toggleSkyPassPath")
                    .accessibilityValue(showPassPath ? "Показан":"Скрыт")
            }
            if showPassPath {
                Label("Жёлтая линия — прогноз пути выбранного спутника",systemImage:"point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption).foregroundStyle(.yellow.opacity(0.85)).frame(maxWidth:.infinity,alignment:.leading)
            }
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
                .satelliteGlass(in:RoundedRectangle(cornerRadius:24,style:.continuous))
            HStack { Text("Просмотрено неба").foregroundStyle(.white.opacity(0.55)); Spacer(); Text("\(Int(scan.coverageFraction*100))%").monospacedDigit() }.font(.system(size:13))
            VStack(spacing:10) {
                primary("Осмотреть камерой",id:"inspectSiteScan",inverted:false) { start(collecting:false) }
                primary("Новое сканирование",id:"startSiteScan") { start(collecting:true) }
            }
            Text("Карта относится к этой точке. После перемещения выполните новое сканирование.").font(.caption).foregroundStyle(.white.opacity(0.5)).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("scanSnapshotNotice")
            if model.manualLocation { Text("Координаты в настройках должны совпадать с местом проверки.").font(.caption).foregroundStyle(.orange) }
            Text(scan.message).font(.caption).foregroundStyle(.white.opacity(0.45)).accessibilityIdentifier("scanStatus")
            if let error = scan.torchError { Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.leading) }
            Divider().overlay(.white.opacity(0.12))
            SiteWeatherView(observer:model.observer,service:model.weatherService)
            Text("Обзор неба не подтверждает радиосвязь. Для связи нужны антенна, внешний модуль и работающий ретранслятор.").font(.caption).foregroundStyle(.white.opacity(0.45)).frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.horizontal,24).padding(.top,16).padding(.bottom,30)
    }
    private var cameraLayer: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let origin = geometry.frame(in:.named("siteCamera")).origin
            let area = cameraDotArea(size:size,origin:origin)
            let viewport = CGRect(x:area.minX/max(1,size.width),y:area.minY/max(1,size.height),
                                  width:area.width/max(1,size.width),height:area.height/max(1,size.height))
            ZStack {
                if scan.running { SkyScanCamera(controller:scan) }
                else { LinearGradient(colors:[Color(white:0.12),Color(white:0.025)],startPoint:.top,endPoint:.bottom) }
                Canvas { context,size in
                    context.clip(to:Path(area))
                    for target in scan.projectedTargets {
                        if screen == .scanning && target.collected && target.collectionProgress == nil { continue }
                        let point = CGPoint(x:target.x*size.width,y:target.y*size.height)
                        if screen == .scanning, let progress = target.collectionProgress {
                            let size = CGFloat(4*(1-progress))
                            let ring = CGFloat(5+9*progress)
                            context.fill(Path(ellipseIn:CGRect(x:point.x-size,y:point.y-size,width:size*2,height:size*2)),with:.color(.white.opacity(1-progress)))
                            context.stroke(Path(ellipseIn:CGRect(x:point.x-ring,y:point.y-ring,width:ring*2,height:ring*2)),with:.color(.white.opacity(0.7*(1-progress))),lineWidth:1.2)
                            continue
                        }
                        let radius: CGFloat = screen == .inspecting ? 5:CGFloat(4 * (1-0.25*target.dwellFraction))
                        let color: Color
                        switch screen == .scanning ? .unknown : target.state {
                        case .blocked: color = Color(red:1,green:0.2,blue:0.26)
                        case .clear: color = .white
                        case .observed: color = .gray
                        case .unknown: color = screen == .scanning ? Color(red:0.7,green:1,blue:0.73):Color(white:0.3)
                        }
                        context.fill(Path(ellipseIn:CGRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2)),with:.color(color))
                        if screen == .scanning && target.dwellFraction > 0 {
                            let ring = Path(ellipseIn:CGRect(x:point.x-8,y:point.y-8,width:16,height:16))
                                .trimmedPath(from:0,to:target.dwellFraction)
                            context.stroke(ring,with:.color(.white.opacity(0.8)),lineWidth:1.2)
                        }
                    }
                }.allowsHitTesting(false).accessibilityElement(children:.ignore)
                    .accessibilityLabel("Точки обзора камеры").accessibilityValue("\(scan.projectedTargets.count)")
                    .accessibilityIdentifier("skyCaptureDots")
                LinearGradient(colors:[.black.opacity(0.15),.clear,.black.opacity(0.65)],startPoint:.top,endPoint:.bottom).allowsHitTesting(false)
                cameraAim(size:geometry.size)
            }.frame(width:size.width,height:size.height)
                .onChange(of:viewport,initial:true) { _,value in scan.collectionViewport = value }
                .onChange(of:size,initial:true) { _,value in if preview { scan.setViewport(value) } }
        }
    }
    private func cameraDotArea(size: CGSize,origin: CGPoint) -> CGRect {
        // Use the same visible rectangle for drawing and collecting: covered
        // directions must not disappear or vibrate underneath the controls.
        guard let topControls = cameraControlBounds["top"], let bottomControls = cameraControlBounds["bottom"] else { return .zero }
        let top = min(size.height,max(0,topControls.maxY-origin.y+12))
        let bottom = min(size.height,max(top,bottomControls.minY-origin.y-12))
        return CGRect(x:12,y:top,width:max(0,size.width-24),height:max(0,bottom-top))
    }
    private var cameraControls: some View {
        VStack(spacing:0) {
            VStack(spacing:0) {
                header
                HStack {
                    if preview { Text("Демонстрация · камера не используется").font(.caption2).padding(8).background(.black.opacity(0.4),in:Capsule()) }
                    Spacer(minLength:8)
                    Button { scan.toggleTorch() } label: {
                        Image(systemName:scan.isTorchOn ? "flashlight.on.fill":"flashlight.off.fill")
                            .font(.system(size:18)).frame(width:46,height:46)
                            .satelliteGlass(in:Circle(),interactive:true)
                    }.buttonStyle(.plain).disabled(!scan.torchAvailable)
                        .accessibilityLabel(scan.isTorchOn ? "Выключить фонарик":"Включить фонарик")
                        .accessibilityValue(scan.torchAvailable ? (scan.isTorchOn ? "Включён":"Выключен"):"Недоступен")
                        .accessibilityIdentifier("scanTorch")
                }.padding(.horizontal,20).padding(.top,10)
            }.background(cameraControlMeasurement("top"))
            Spacer(minLength:20)
            VStack(spacing:8) {
                if let error = scan.torchError { Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.leading) }
                HStack(alignment:.bottom) { Text(preview ? (screen == .inspecting ? "Сохранённые отметки в поле зрения":"Удерживайте точки в центральной области кадра") : scan.message).font(.caption).foregroundStyle(.white.opacity(0.8)).accessibilityIdentifier("scanStatus"); Spacer(minLength:12); cameraCompass }
                if screen == .scanning {
                    HStack(spacing:10) {
                        Button { scan.mark(.clear) } label: { Label("Небо",systemImage:"checkmark").frame(maxWidth:.infinity).frame(height:44).satelliteGlass(in:Capsule(),interactive:true) }.accessibilityIdentifier("markSkyClear")
                        Button { scan.mark(.blocked) } label: { Label("Препятствие",systemImage:"xmark").frame(maxWidth:.infinity).frame(height:44).satelliteGlass(in:Capsule(),interactive:true) }.accessibilityIdentifier("markSkyBlocked")
                    }.font(.system(size:13,weight:.medium)).disabled(scan.direction == nil || !scan.running)
                }
                primary(screen == .inspecting ? "К карте":"Показать результат",id:"finishSiteScan") { captureTask?.cancel(); scan.finish(); screen = .result }
            }.padding(.horizontal,20).padding(.vertical,12).background(cameraControlMeasurement("bottom"))
        }
    }
    private func cameraControlMeasurement(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key:SkyCameraControlsPreference.self,value:[key:geometry.frame(in:.named("siteCamera"))])
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
                .frame(maxWidth:.infinity).frame(height:52).foregroundStyle(inverted ? .black:.white)
                .background(inverted ? Color.white:Color.clear,in:RoundedRectangle(cornerRadius:22,style:.continuous))
                .satelliteGlass(in:RoundedRectangle(cornerRadius:22,style:.continuous),interactive:true)
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
                    VStack(alignment:.leading,spacing:10) {
                        Label("Что означает процент",systemImage:"viewfinder").font(.headline).foregroundStyle(.white)
                        Text("Процент — просмотренная площадь неба. Собранная точка ещё не означает, что в этом направлении нет препятствий.")
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
                        .satelliteGlass(in:RoundedRectangle(cornerRadius:24,style:.continuous))
                    Text("Небо, дальние здания и деревья отмечаются по камере вручную. LiDAR отмечает близкие поверхности до 6 м; отсутствие глубины не означает открытое небо.")
                    Text("Белые точки — открытое небо, красные — препятствия. Тёмные и серые точки требуют проверки. Путь выбранного спутника можно включить отдельно: он показан жёлтой линией.")
                    Text("«От точки старта» возвращает карту к направлению начала сканирования. В режиме «Гироскоп» поворачивайте телефон на том же месте: задняя камера задаёт направление обзора. Эти режимы не добавляют новые измерения.")
                    Text("Мягкий отклик отмечает сбор новых точек. Фонарик освещает близкие предметы; дальние препятствия в темноте могут оставаться неразличимыми.")
                    Text("Карта относится к одной точке. После перемещения начните новое сканирование. Стены и потолок следует отмечать как препятствия.")
                    Text("Кадры камеры обрабатываются на iPhone, не записываются и не отправляются. Карта хранится до закрытия проверки места. Компас и плохое освещение могут ограничивать точность.")
                }.font(.subheadline).foregroundStyle(.white.opacity(0.72)).padding(24)
            }.background(Color.black).navigationTitle("Проверка места").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Готово") { information = false } } }
        }.tint(.white).preferredColorScheme(.dark)
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
