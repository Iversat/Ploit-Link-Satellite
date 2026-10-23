import SwiftUI

enum SkyScanPathRefresh {
    static func timeSlice(for pass: PassWindow?, at date: Date) -> Int {
        guard let pass, pass.contains(date) else { return 0 }
        return Int(floor(date.timeIntervalSince1970 / 30))
    }
}

struct SiteScanView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var scan = SkyScanController()
    @State private var path: [SkyDirection] = []
    @State private var pathMessage = "Рассчитываем путь пролёта…"
    @State private var captureTask: Task<Void,Never>?
    @State private var engine = OrbitEngine()
    private var pass: PassWindow? { model.session(for:model.selectedID) }
    private var assessment: SkyAssessment { scan.survey.assessment(path:path) }
    private var pathKey: String {
        let location = String(format:"%.3f/%.3f",model.observer?.latitude ?? 0,model.observer?.longitude ?? 0)
        let slice = SkyScanPathRefresh.timeSlice(for:pass,at:model.clock)
        return "\(model.selectedID)|\(pass?.rise ?? 0)|\(model.elements?.line1 ?? "")|\(location)|\(model.minElevation)|\(slice)"
    }
    private var preview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--ui-screenshot-site-scan")
        #else
        return false
        #endif
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:18) {
                    Text("Проверка обзора неба").font(.title2.bold()).frame(maxWidth:.infinity,alignment:.leading)
                    Text("Останьтесь у антенны. Обведите камерой небо, затем отметьте открытые участки и препятствия вдоль жёлтого пути спутника.")
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                    if model.manualLocation { Text("Путь рассчитан для координат из настроек. Они должны совпадать с местом сканирования.").font(.caption).foregroundStyle(.orange) }
                    if preview { Label("Пример карты · не результат измерения",systemImage:"play.rectangle").font(.caption).foregroundStyle(.orange) }
                    cameraPanel
                    GlassPanel {
                        VStack(alignment:.leading,spacing:12) {
                            HStack { Text("Карта обзора").font(.headline); Spacer(); Text(model.satellite?.name ?? "Спутник").font(.caption).foregroundStyle(.secondary) }
                            SkyDomeView(survey:scan.survey,path:path,direction:scan.direction).frame(height:270)
                            Text("Вращайте купол пальцем. Вверх и вниз — наклон.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing:12) {
                                legend("Открыто",color:.cyan)
                                legend("Препятствие",color:.red)
                                legend("Неизвестно",color:.gray)
                            }.font(.system(size:10))
                            Text(pathMessage).font(.caption).foregroundStyle(.secondary)
                            if scan.isSnapshot {
                                Label("Снимок точки сканирования",systemImage:"pin.fill").font(.caption.bold()).foregroundStyle(.orange)
                                Text("Результат относится к месту, где выполнена проверка. Движение после остановки камеры точно не отслеживается: после перемещения сканируйте заново.")
                                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("scanSnapshotNotice")
                            }
                            Text(assessment.title).font(.headline).foregroundStyle(assessment.blocked > 0 ? .orange:.white).accessibilityIdentifier("siteAssessment")
                            Text(assessment.detail).font(.caption).foregroundStyle(.secondary)
                            Text("Это оценка обзора по отмеченным направлениям. Камера не измеряет радиосигнал; связь зависит от антенны, модуля и включения ретранслятора.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GlassPanel { SiteWeatherView(observer:model.observer) }
                    DisclosureGroup("Как оценивается место") {
                        VStack(alignment:.leading,spacing:10) {
                            Text("На iPhone с LiDAR близкие стены, потолок и другие поверхности до 6 м отмечаются красным. Отсутствие измерения глубины не означает открытое небо.")
                            Text("Дальние здания, деревья, стекло и небо отмечайте по изображению вручную. Без LiDAR карта заполняется только вручную. В темноте и при неточном компасе оценка ограничена.")
                            Text("В помещении крыша и стены могут закрывать направление. Не отмечайте их как открытое небо. После перемещения к другой точке сканирование нужно повторить.")
                            Text("Кадры камеры обрабатываются на iPhone, не записываются и не отправляются. Карта хранится только до закрытия этого экрана.")
                        }.font(.caption).foregroundStyle(.secondary).padding(.top,8)
                    }.tint(.white)
                }.padding(20)
            }.background(Color.black)
                .navigationTitle("Проверка места").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) {
                    Button { captureTask?.cancel(); scan.stop(); model.scannerPresented = false; dismiss() } label: {
                        Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle())
                    }.accessibilityLabel("Закрыть проверку места").accessibilityIdentifier("closeSiteScan")
                } }
        }.task(id:pathKey) { await loadPath() }
            .onAppear {
                #if DEBUG
                if preview { scan.preview() }
                #endif
            }
            .task {
                while !Task.isCancelled {
                    scan.checkLocation(model.observer)
                    scan.headingReady = model.sensors.northIsTrue && model.sensors.headingAccuracy >= 0 && model.sensors.headingAccuracy <= 20
                    do { try await Task.sleep(nanoseconds:500_000_000) } catch { return }
                }
            }
            .onChange(of:phase) { _, value in
                if value == .background {
                    captureTask?.cancel()
                    scan.invalidate("Проверка сброшена после сворачивания приложения. Начните заново у антенны.")
                }
            }
            .onDisappear { captureTask?.cancel(); scan.stop() }
    }
    private var cameraPanel: some View {
        VStack(spacing:12) {
            ZStack {
                if scan.running { SkyScanCamera(controller:scan) }
                else {
                    LinearGradient(colors:[Color(red:0.06,green:0.15,blue:0.22),.black],startPoint:.top,endPoint:.bottom)
                    VStack(spacing:12) {
                        Image(systemName:"viewfinder").font(.system(size:45,weight:.ultraLight))
                        Text("Камера и карта препятствий").font(.subheadline)
                        Text(scan.supportsDepth ? "LiDAR доступен" : "Ручная разметка по камере").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if scan.running {
                    Image(systemName:"plus").font(.system(size:30,weight:.ultraLight)).shadow(radius:3)
                    VStack { Spacer(); Text("В прицеле открытое небо? Отметьте участок кнопкой ниже.").font(.caption).padding(10).background(.black.opacity(0.6),in:Capsule()) }.padding(12)
                }
            }.frame(height:245).clipShape(RoundedRectangle(cornerRadius:24))
            Text(scan.message).font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("scanStatus")
            if scan.running {
                HStack {
                    Button { scan.mark(.clear) } label: { Label("Небо открыто",systemImage:"checkmark").frame(maxWidth:.infinity) }.tint(.cyan)
                    Button { scan.mark(.blocked) } label: { Label("Препятствие",systemImage:"xmark").frame(maxWidth:.infinity) }.tint(.red)
                }.buttonStyle(.bordered).disabled(scan.direction == nil)
                Button("Завершить сканирование") { captureTask?.cancel(); scan.finish() }.font(.subheadline)
            } else {
                Button {
                    captureTask?.cancel()
                    captureTask = Task { await scan.start(observer:model.observer) }
                } label: { Label("Начать сканирование",systemImage:"camera.viewfinder").frame(maxWidth:.infinity).padding(.vertical,8) }
                    .buttonStyle(.borderedProminent).tint(.blue).accessibilityIdentifier("startSiteScan")
            }
        }
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing:4) { Circle().fill(color).frame(width:6,height:6); Text(title) }
    }
    private func loadPath() async {
        path = []
        if preview {
            path = (0...60).map { .init(azimuth:Double($0)*3 + 90, elevation:20 + 55*sin(Double($0)/60 * .pi)) }
            pathMessage = "Пример будущего пролёта"
            return
        }
        guard let observer = model.observer, let elements = model.elements, let pass, elements.ageDays() <= 14 else {
            pathMessage = "Нужны геопозиция, свежие данные орбиты и ближайший сеанс."
            return
        }
        let start = max(Date(),pass.riseDate), end = pass.setDate
        guard start < end, elements.ageDays(at:end) <= 14 else { pathMessage = "Обновите прогноз пролёта."; return }
        do {
            var values: [SkyDirection] = []
            for index in 0...72 {
                try Task.checkCancellation()
                let date = start.addingTimeInterval(end.timeIntervalSince(start)*Double(index)/72)
                let look = try await engine.look(elements:elements,observer:observer,date:date)
                values.append(.init(azimuth:look.azimuth,elevation:look.elevation))
            }
            try Task.checkCancellation()
            path = values
            pathMessage = "\(pass.riseDate.formatted(date:.abbreviated,time:.omitted)) · \(SessionText.interval(pass)) · оставшийся путь пролёта"
        } catch is CancellationError {} catch { pathMessage = "Путь не рассчитан. Обновите орбитальные данные." }
    }
}
