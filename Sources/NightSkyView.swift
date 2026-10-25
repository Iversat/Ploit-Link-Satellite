import SwiftUI

struct NightSkyView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { NightSkyContent(sensors:model.sensors).environmentObject(model) }
}

private struct NightSkyContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let sensors: Sensors
    @StateObject private var camera = NightCamera()
    @State private var catalog: NightSkyCatalog?
    @State private var snapshot = NightSkySnapshot()
    @State private var mode = NightSkyMode.explore
    @State private var yaw = 250.0
    @State private var pitch = 50.0
    @State private var fov = 72.0
    @State private var dragStart: (Double,Double)?
    @State private var zoomStart: Double?
    @State private var now = Date()
    @State private var offset = 0.0
    @State private var showLines = true
    @State private var showNames = true
    @State private var showMilkyWay = true
    @State private var finder = false
    @State private var information = false
    @State private var selected: NightTarget?
    @State private var loadError: String?
    @State private var panoramaError: String?
    private var date: Date { now.addingTimeInterval(offset*3600) }
    private var observer: Observer? { model.observer }
    private var headingReliable: Bool { sensors.scanHeadingReady && sensors.motionReady && sensors.northIsTrue }
    private var skyKey: String { "\(catalog?.stars.count ?? 0)|\(observer?.latitude ?? 999)|\(observer?.longitude ?? 999)|\(Int(date.timeIntervalSince1970/10))" }
    private var currentBasis: DeviceBasis {
        mode.basis(manual:NightSkyMath.basis(azimuth:yaw,elevation:pitch),
                   measured:sensors.lastBasis,motionReady:sensors.motionReady)
    }
    private var targetVector: DirectionVector? {
        guard let selected, let observer else { return nil }
        return NightSkyMath.vector(ra:selected.ra,dec:selected.dec,observer:observer,date:date)
    }
    private var sunElevation: Double? { observer.map { NightSkyMath.sunElevation(observer:$0,date:date) } }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red:0.004,green:0.009,blue:0.022).ignoresSafeArea()
                if mode.usesCamera {
                    NightCameraPreview(camera:camera)
                    Color.black.opacity(0.15).ignoresSafeArea().allowsHitTesting(false)
                } else {
                    LinearGradient(colors:[.black,Color(red:0.015,green:0.03,blue:0.06)],startPoint:.top,endPoint:.bottom).ignoresSafeArea()
                }
                TimelineView(.animation(minimumInterval:1.0/30,paused:mode == .explore || phase != .active)) { _ in
                    GeometryReader { skyGeometry in
                        let size = skyGeometry.size
                        let focal = mode.usesCamera && camera.running ? camera.focalLength(size:size) : Double(size.width)/(2*tan(fov * .pi/360))
                        ZStack {
                            if let observer, showMilkyWay {
                                NightSkyPanorama(basis:currentBasis,observer:observer,date:date,focal:focal,
                                    augmented:mode.usesCamera,enabled:showMilkyWay) { panoramaError = $0 }
                                    .allowsHitTesting(false)
                            }
                            Canvas { context,size in
                                draw(context:context,size:size,projection:.init(basis:currentBasis,size:size,focal:focal,minimumElevation:mode.minimumElevation))
                            }
                        }
                    }
                }.contentShape(Rectangle()).gesture(drag(width:geometry.size.width),including:mode == .explore ? .all:.none)
                    .simultaneousGesture(MagnificationGesture().onChanged { scale in
                        guard !mode.usesCamera else { return }
                        if zoomStart == nil { zoomStart = fov }; fov = min(110,max(25,(zoomStart ?? 72)/scale))
                    }.onEnded { _ in zoomStart = nil })
                    .accessibilityLabel("Карта звёзд над вашим местоположением")
                    .accessibilityValue("az \(Int(yaw)) el \(Int(pitch)) camera \(camera.running ? "on":"off")")
                    .accessibilityIdentifier("nightSkyCanvas")
                VStack(spacing:12) {
                    header
                    Picker("Режим неба",selection:$mode) {
                        ForEach(NightSkyMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("nightSkyMode")
                    if observer == nil {
                        notice("Нужно ваше местоположение. Разрешите геопозицию или задайте координаты в настройках PLS.")
                    } else if let loadError { notice(loadError) }
                    else if let panoramaError { notice(panoramaError) }
                    else if mode.usesCamera, let message = camera.message { notice(message) }
                    else if mode.followsPhone && !sensors.motionReady { notice("Датчики движения недоступны. Можно открыть свободный обзор.") }
                    else if mode.followsPhone && !headingReliable { notice("Направление приблизительное: компас уточняется. Отойдите от металла и магнитных аксессуаров.") }
                    if let sunElevation, sunElevation > -18 {
                        notice(sunElevation > -6 ? "Сейчас светло: карта показывает расчётное небо. Звёзды лучше видны ночью." : "Сумерки: слабые звёзды и Млечный Путь могут быть не видны.")
                    }
                    Spacer(minLength:8)
                    if let selected {
                        TimelineView(.animation(minimumInterval:1.0/15,paused:mode == .explore || phase != .active)) { _ in targetCard(selected) }
                    }
                    if mode == .explore && pitch < 0 {
                        Text("ПОД ГОРИЗОНТОМ · обзор сквозь Землю")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            .padding(8).background(.black.opacity(0.7),in:Capsule()).accessibilityIdentifier("belowSkyHorizon")
                    }
                    controls
                }.padding(.horizontal,20).padding(.top,8).padding(.bottom,8)
            }.clipped()
        }
        .preferredColorScheme(.dark).tint(.white)
        .task {
            do { catalog = try await Task.detached(priority:.userInitiated) { try NightSkyCatalog.load() }.value }
            catch { loadError = "Не удалось прочитать встроенный каталог звёзд." }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(where:{ $0.hasPrefix("--ui-screenshot-night-sky") }) {
                now = Date(timeIntervalSince1970:1792951200)
                selected = .milkyWay
                focus(.milkyWay)
                if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-night-sky-gyro") {
                    sensors.preview(azimuth:yaw,elevation:pitch,axis:.back)
                    mode = .gyroscope
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-night-sky-detail") { fov = 35; selected = nil }
                if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-night-sky-below") { pitch = -35; selected = .galacticCenter }
            }
            #endif
        }
        .task(id:skyKey) {
            guard let catalog, let observer else { snapshot = NightSkySnapshot(); return }
            let date = date
            do { try await Task.sleep(nanoseconds:80_000_000) } catch { return }
            let calculated = await Task.detached(priority:.userInitiated) {
                NightSkySnapshot.make(catalog:catalog,observer:observer,date:date)
            }.value
            guard !Task.isCancelled else { return }; snapshot = calculated
        }
        .onChange(of:mode) { _,value in if value.followsPhone { offset = 0 } }
        .task(id:mode.usesCamera && phase == .active) {
            if mode.usesCamera && phase == .active { await camera.start() } else { camera.stop() }
        }
        .onReceive(Timer.publish(every:5,on:.main,in:.common).autoconnect()) { tick in
            guard phase == .active else { return }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(where:{ $0.hasPrefix("--ui-screenshot-night-sky") }) { return }
            #endif
            now = tick
        }
        .onChange(of:phase) { _,value in if value != .active { camera.stop() } }
        .onDisappear { camera.stop() }
        .sheet(isPresented:$finder) {
            if let catalog {
                NightObjectPicker(catalog:catalog) { target in selected = target; finder = false; if mode == .explore { focus(target) } }
            }
        }
        .sheet(isPresented:$information) { informationView }
    }

    private var header: some View {
        HStack {
            VStack(alignment:.leading,spacing:3) { Text("Ночное небо").font(.title2.bold()); Text("PLS · вид с Земли").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button { information = true } label: { Image(systemName:"info.circle").frame(width:44,height:44) }.accessibilityLabel("О карте звёзд")
            Button { dismiss() } label: { Image(systemName:"xmark").frame(width:44,height:44).satelliteGlass(in:Circle(),interactive:true) }
                .accessibilityLabel("Закрыть ночное небо").accessibilityIdentifier("closeNightSky")
        }
    }
    private func notice(_ text: String) -> some View {
        Text(text).font(.caption).multilineTextAlignment(.center).padding(10).frame(maxWidth:.infinity)
            .background(.black.opacity(0.6),in:RoundedRectangle(cornerRadius:14))
    }
    private var controls: some View {
        VStack(spacing:12) {
            HStack {
                Button { finder = true } label: { Label("Найти",systemImage:"magnifyingglass") }.accessibilityIdentifier("findSkyObject")
                Spacer()
                Button { showLines.toggle() } label: { Image(systemName:"point.3.connected.trianglepath.dotted").foregroundStyle(showLines ? .cyan:.gray) }.accessibilityLabel("Линии созвездий")
                Button { showNames.toggle() } label: { Image(systemName:"textformat").foregroundStyle(showNames ? .cyan:.gray) }.accessibilityLabel("Названия объектов")
                Button { showMilkyWay.toggle() } label: { Image(systemName:"sparkles").foregroundStyle(showMilkyWay ? .cyan:.gray) }.accessibilityLabel("Детальная панорама неба")
                Button { mode = .explore; yaw = 0; pitch = 75; fov = 90; selected = nil } label: { Image(systemName:"arrow.up.to.line") }.accessibilityLabel("Посмотреть над собой")
            }.buttonStyle(.plain).font(.system(size:17)).controlSize(.large)
            HStack {
                Text(date.formatted(date:.abbreviated,time:.shortened)).font(.caption).monospacedDigit()
                Spacer()
                Button("Сейчас") { offset = 0; now = Date() }.font(.caption.weight(.semibold))
            }
            if mode == .explore {
                Slider(value:$offset,in:-12...12,step:0.05).accessibilityLabel("Время неба").accessibilityIdentifier("nightTimeSlider")
                Text("Полная сфера · вращайте пальцем · масштаб двумя").font(.caption2).foregroundStyle(.secondary)
            } else if mode == .gyroscope {
                Text("Камера выключена · направьте заднее стекло к звёздам. Масштаб — двумя пальцами.").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("gyroSkyHint")
            } else {
                Text("Наведите заднюю камеру на небо. Расчётное направление зависит от точности компаса.").font(.caption2).foregroundStyle(.secondary)
            }
            if showMilkyWay {
                Link("Карта 16K · NASA / Gaia",destination:URL(string:"https://svs.gsfc.nasa.gov/4851/")!)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(16).satelliteGlass(in:RoundedRectangle(cornerRadius:24))
    }
    private func targetCard(_ target: NightTarget) -> some View {
        VStack(alignment:.leading,spacing:6) {
            HStack { Text(target.name).font(.headline); Spacer(); Button { selected = nil } label: { Image(systemName:"xmark.circle.fill") }.accessibilityLabel("Снять выбор объекта") }
            if let vector = targetVector {
                let angles = NightSkyMath.angles(vector)
                Text(String(format:"Азимут %.0f° · высота %.0f°",angles.azimuth,angles.elevation)).font(.caption).foregroundStyle(.secondary)
                if angles.elevation < 0 { Text("Под горизонтом · с этой точки сейчас не видно").font(.subheadline).foregroundStyle(.orange) }
                Group {
                    let error = acos(max(-1,min(1,vector.dot(currentBasis.z.negative))))*180 / .pi
                    Text(error < 5 ? "Объект в центре" : "\(mode == .explore ? "Поверните карту к метке":"Поверните телефон к метке") · \(Int(error))°")
                        .font(.subheadline).foregroundStyle(error < 5 && (mode == .explore || headingReliable) ? .green:.white)
                    if mode == .explore { Button("Навести на объект") { focus(target) }.font(.caption.weight(.semibold)).accessibilityIdentifier("centerSkyTarget") }
                }
            }
            Text(target.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }.padding(16).satelliteGlass(in:RoundedRectangle(cornerRadius:22))
    }
    private func focus(_ target: NightTarget) {
        guard let observer else { return }
        let v = NightSkyMath.vector(ra:target.ra,dec:target.dec,observer:observer,date:date)
        let a = NightSkyMath.angles(v); yaw = a.azimuth; pitch = min(89,max(-89,a.elevation)); fov = 72
    }
    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance:3).onChanged { value in
            if dragStart == nil { dragStart = (yaw,pitch) }
            guard let start = dragStart else { return }
            yaw = AimMath.wrap(start.0-Double(value.translation.width)/Double(max(1,width))*fov)
            pitch = min(89,max(-89,start.1+Double(value.translation.height)/Double(max(1,width))*fov))
        }.onEnded { _ in dragStart = nil }
    }
    private var informationView: some View {
        NavigationStack {
            List {
                Section("Небо над выбранной точкой") {
                    Text("5070 звёзд до шестой звёздной величины. Положение рассчитано по координатам, времени и вращению Земли с поправкой на прецессию. Камера не распознаёт звёзды на изображении.")
                    Text("Гироскоп поворачивает карту вслед за iPhone без камеры; направляйте заднее стекло к объекту и следуйте метке в центре. AR дополнительно включает заднюю камеру. Компас рядом с металлом, в помещении и возле магнитных аксессуаров может ошибаться. Свободный обзор работает без камеры.")
                    Text("Карта 16 384 × 8 192 — NASA/Goddard SVS; данные Gaia DR2: ESA/Gaia/DPAC. Она построена по каталогам звёзд, а не по текущему изображению камеры. Высокое разрешение встроено в приложение и работает без интернета. В свободном обзоре и режиме гироскопа доступна вся сфера, включая звёзды под Землёй; ниже горизонта изображение затемнено. В AR видны ещё 18° ниже горизонта, но звёзды не сдвигаются относительно камеры. Облака, засветка и Луна влияют на реальную видимость. Планеты и Луна не рассчитываются.")
                }
                Section("Каталоги") {
                    Text("Звёзды: HYG v4.1 · David Nash / Astronexus · CC BY-SA 4.0. Созвездия: d3-celestial · Olaf Frohn · BSD-3-Clause.")
                    Link("Источники и лицензии",destination:URL(string:"https://github.com/Iversat/Ploit-Link-Satellite/blob/main/LICENSES/NightSky-NOTICE.md")!)
                }
            }.navigationTitle("О ночном небе").toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Готово") { information = false } } }
        }.preferredColorScheme(.dark)
    }

    private func draw(context: GraphicsContext, size: CGSize, projection: NightProjection) {
        guard let catalog, snapshot.stars.count == catalog.stars.count else { return }
        var context = context
        context.clip(to:Path(CGRect(origin:.zero,size:size)))
        if showLines {
            var path = Path()
            for line in snapshot.lines {
                for (a,b) in zip(line,line.dropFirst()) {
                    guard let pa = projection.point(a), let pb = projection.point(b),
                          hypot(pa.x-pb.x,pa.y-pb.y) < max(size.width,size.height)*1.5 else { continue }
                    path.move(to:pa); path.addLine(to:pb)
                }
            }
            context.stroke(path,with:.color(.cyan.opacity(0.26)),lineWidth:0.65)
        }
        var occupied: [CGPoint] = []
        for (index,v) in snapshot.stars.enumerated() {
            guard let p = projection.point(v), projection.visible(p,margin:5) else { continue }
            let star = catalog.stars[index]
            let radius = max(0.45,2.2-star.magnitude*0.28)
            let tint = star.color > 0.9 ? Color(red:1,green:0.84,blue:0.63) : star.color < 0.1 ? Color(red:0.76,green:0.86,blue:1):.white
            if star.magnitude < 1.5 {
                context.fill(Path(ellipseIn:CGRect(x:p.x-6,y:p.y-6,width:12,height:12)),with:.radialGradient(Gradient(colors:[tint.opacity(0.26),.clear]),center:p,startRadius:0,endRadius:6))
            }
            context.fill(Path(ellipseIn:CGRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2)),with:.color(tint.opacity(max(0.35,1-star.magnitude*0.07)*(v.up < 0 ? 0.5:1))))
            if showNames && star.magnitude < 2 && !occupied.contains(where:{ hypot($0.x-p.x,$0.y-p.y)<65 }) {
                occupied.append(p)
                context.draw(Text(star.name).font(.system(size:11,weight:.medium)).foregroundStyle(.white.opacity(0.85)),at:CGPoint(x:p.x+7,y:p.y+7),anchor:.topLeading)
            }
        }
        if showNames {
            for (index,v) in snapshot.labels.enumerated() {
                guard let p = projection.point(v), projection.visible(p,margin:-20), !occupied.contains(where:{ hypot($0.x-p.x,$0.y-p.y)<55 }) else { continue }
                occupied.append(p)
                context.draw(Text(catalog.constellations[index].name.uppercased()).font(.system(size:10,weight:.medium)).foregroundStyle(.cyan.opacity(0.65)),at:p)
            }
        }
        var horizon = Path()
        for az in stride(from:0.0,to:360,by:2) {
            let a = NightSkyMath.basis(azimuth:az,elevation:0).z.negative
            let b = NightSkyMath.basis(azimuth:az+2,elevation:0).z.negative
            if let pa = projection.point(a), let pb = projection.point(b) { horizon.move(to:pa); horizon.addLine(to:pb) }
        }
        context.stroke(horizon,with:.color(.white.opacity(0.25)),style:.init(lineWidth:0.8,dash:[3,5]))
        for (name,az) in [("С",0.0),("В",90.0),("Ю",180.0),("З",270.0)] {
            if let p = projection.point(NightSkyMath.basis(azimuth:az,elevation:3).z.negative), projection.visible(p) {
                context.draw(Text(name).font(.system(size:16,weight:.semibold)).foregroundStyle(.white.opacity(0.65)),at:p)
            }
        }
        if let target = targetVector, !mode.usesCamera || target.up >= sin(-18 * .pi/180) {
            let p = projection.point(target)
            if let p, projection.visible(p,margin:-30) {
                context.stroke(Path(ellipseIn:CGRect(x:p.x-15,y:p.y-15,width:30,height:30)),with:.color(.white),lineWidth:1)
            } else {
                let rawX = target.dot(projection.basis.x), rawY = -target.dot(projection.basis.y)
                let x = hypot(rawX,rawY) < 0.001 ? 1:rawX, y = rawY
                let length = max(0.001,hypot(x,y)), r = min(size.width,size.height)*0.32
                let point = CGPoint(x:size.width/2+x/length*r,y:size.height/2+y/length*r)
                var arrow = context; arrow.translateBy(x:point.x,y:point.y); arrow.rotate(by:.radians(atan2(y,x)+Double.pi/2))
                arrow.draw(Text("↑").font(.system(size:32,weight:.light)).foregroundStyle(.white),at:.zero)
            }
        }
        if mode.followsPhone || selected != nil {
            let center = CGPoint(x:size.width/2,y:size.height/2)
            context.stroke(Path(ellipseIn:CGRect(x:center.x-3,y:center.y-3,width:6,height:6)),with:.color(.white.opacity(0.7)),lineWidth:1)
        }
    }
}

private struct NightObjectPicker: View {
    let catalog: NightSkyCatalog
    let select: (NightTarget)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Галактика") {
                    ForEach([NightTarget.milkyWay,.galacticCenter].filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { target in
                        Button(target.name) { select(target) }
                    }
                }
                Section("Созвездия") {
                    ForEach(catalog.constellations.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }.sorted { $0.name < $1.name }) { c in
                        Button(c.name) { select(.init(id:c.id,name:c.name,ra:c.ra,dec:c.dec,detail:"Созвездие · \(c.id). Метка указывает область фигуры; линии соединяют звёзды на карте.")) }
                    }
                }
                Section("Звёзды") {
                    ForEach(catalog.stars.filter { search.isEmpty ? $0.magnitude < 2.5 : $0.name.localizedCaseInsensitiveContains(search) }.prefix(150)) { star in
                        Button(star.name) { select(.init(id:"star-\(star.id)",name:star.name,ra:star.ra,dec:star.dec,detail:String(format:"Звезда · видимая величина %.2f. Чем меньше значение, тем ярче звезда.",star.magnitude))) }
                    }
                }
            }.searchable(text:$search,prompt:"Звезда или созвездие").navigationTitle("Найти в небе")
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Готово") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
