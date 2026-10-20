import SwiftUI
import Combine

@MainActor final class OrbitPlayback: ObservableObject {
    @Published var selectedID = 25544
    @Published var showAll = true
    @Published var showGround = false { didSet { renderFeed.setGround(showGround) } }
    @Published var date = Date()
    @Published var live = true
    @Published var playing = false
    @Published var speed: Double = 60 { didSet { reanchor(); calculate() } }
    @Published var states: [Int:OrbitalState] = [:]
    @Published var paths: [Int:OrbitalTrajectory] = [:]
    @Published var pathDates: [Int:Date] = [:]
    @Published var message: String?
    @Published var focus = 0
    let renderFeed=OrbitRenderFeed()
    private(set) var anchor=Date()
    private(set) var active=false
    private(set) var interacting=false
    private var clock=OrbitClock(date:Date())
    private var elements: [Int:Elements]=[:]
    private var tracks: [Int:OrbitMotion]=[:]
    private let engine=OrbitEngine()
    private var calculation: Task<Void,Never>?
    private var requestID=UUID()
    var offset: Double { date.timeIntervalSince(anchor) }
    var visibleIDs: [Int] { showAll ? elements.keys.sorted() : [selectedID] }
    private var rate: Double { interacting || !active ? 0 : live ? 1 : playing ? speed : 0 }
    private func publishClock() { renderFeed.update(clock:clock,tracks:tracks,pathDates:pathDates) }
    private func reanchor(at value: Date? = nil) {
        date=value ?? clock.value()
        clock=OrbitClock(date:date,rate:rate,limit:anchor.addingTimeInterval(48*3600))
        if active { publishClock() }
    }
    private func cancelCalculation() { requestID=UUID(); calculation?.cancel(); calculation=nil }
    func setInteracting(_ value: Bool) {
        guard active,interacting != value else { return }
        let current=clock.value(); interacting=value
        reanchor(at:live && !value ? Date():current)
        if value { cancelCalculation() } else { calculate() }
    }
    func configure(elements: [Int:Elements], selectedID: Int, initialDate: Date?) {
        cancelCalculation(); active=true; interacting=false; playing=false
        self.selectedID=selectedID; anchor=Date(); live=initialDate == nil
        self.elements=elements; tracks=[:]; states=[:]; paths=[:]; pathDates=[:]; focus+=1
        reanchor(at:initialDate ?? anchor); calculate()
    }
    func updateElements(_ values: [Int:Elements]) {
        guard active,values != elements else { return }
        cancelCalculation(); elements=values; tracks=[:]; paths=[:]; pathDates=[:]
        publishClock(); calculate()
    }
    func scrub(_ offset: Double) {
        guard active else { return }
        live=false; playing=false; cancelCalculation()
        reanchor(at:anchor.addingTimeInterval(min(48*3600,max(-6*3600,offset))))
        states=[:]; calculate()
    }
    func jump(to date: Date) { scrub(date.timeIntervalSince(anchor)) }
    func now() {
        guard active else { return }
        cancelCalculation(); live=true; playing=false; anchor=Date(); reanchor(at:anchor); calculate()
    }
    func togglePlayback() {
        guard active else { return }
        let current=clock.value(); live=false; playing.toggle(); reanchor(at:current); calculate()
    }
    func pulse() {
        guard active,!interacting else { return }
        date=clock.value()
        if offset>=48*3600,playing { playing=false; reanchor(at:date) }
        calculate()
    }
    func calculate() {
        guard active,!interacting else { return }
        let instant=clock.value(),ids=visibleIDs
        let available=Dictionary(uniqueKeysWithValues:ids.compactMap { id in tracks[id]?.state(at:instant).map { (id,$0) } })
        if !available.isEmpty { states=available }
        guard calculation == nil else { return } // Never queue a new job every timer tick.
        let lookAhead=max(30,rate*3),duration=max(120,rate*12)
        let needed=ids.filter { id in
            guard let track=tracks[id] else { return true }
            return track.state(at:instant) == nil || track.end.timeIntervalSince(instant)<lookAhead
        }
        let pathNeeded=ids.filter { pathDates[$0].map { abs($0.timeIntervalSince(instant))>900 } ?? true }
        guard !needed.isEmpty || !pathNeeded.isEmpty else { return }
        let token=UUID(),values=elements; requestID=token
        calculation=Task {
            defer { if requestID==token { calculation=nil } }
            var nextTracks=tracks,nextPaths=paths,nextDates=pathDates,pathsChanged=false
            for id in ids {
                guard !Task.isCancelled,requestID==token,active else { return }
                guard let tle=values[id],tle.ageDays(at:instant)<=14 else { continue }
                if needed.contains(id),let motion=try? await engine.motion(elements:tle,date:instant,seconds:duration) { nextTracks[id]=motion }
                guard !Task.isCancelled,requestID==token,active else { return }
                if pathNeeded.contains(id),let path=try? await engine.trajectory(elements:tle,date:instant) {
                    nextPaths[id]=path; nextDates[id]=instant; pathsChanged=true
                }
            }
            guard !Task.isCancelled,requestID==token,active else { return }
            tracks=nextTracks
            if pathsChanged { paths=nextPaths; pathDates=nextDates }
            let current=clock.value()
            states=Dictionary(uniqueKeysWithValues:ids.compactMap { id in tracks[id]?.state(at:current).map { (id,$0) } })
            message=states.isEmpty ? "Обновите данные орбит для выбранного времени" : nil
            publishClock()
        }
    }
    func stop() {
        active=false; cancelCalculation(); renderFeed.stop(); playing=false
    }
}

enum OrbitPalette {
    static func color(_ index: Int) -> Color { [Color.cyan,.orange,.mint,.pink,.purple][index%5] }
}

struct OrbitExplorerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Binding var isPresented: Bool
    @StateObject private var playback=OrbitPlayback()
    @State private var headerHeight: CGFloat=64
    @State private var controlsHeight: CGFloat=350
    var initialDate: Date? = nil
    var initialSatelliteID: Int? = nil
    private let timer=Timer.publish(every:0.5,on:.main,in:.common).autoconnect()
    private var satellite: Satellite? { model.satellites.first{$0.id==playback.selectedID} }
    private var session: PassWindow? { model.session(for:playback.selectedID,at:playback.date) }
    private var labels: [Int:String] {
        Dictionary(uniqueKeysWithValues:model.satellites.map { sat in
            let text=model.session(for:sat.id,at:playback.date).map { SessionText.interval($0) } ?? "нет сеанса за 48 ч"
            return (sat.id,sat.name+"\n"+text)
        })
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                OrbitScene(states:playback.states,paths:playback.paths,pathDates:playback.pathDates,
                           ids:model.satellites.map(\.id),labels:labels,selectedID:playback.selectedID,
                           showAll:playback.showAll,showGround:playback.showGround,
                           observer:model.observer,focus:playback.focus,renderFeed:playback.renderFeed,
                           contentInsets:UIEdgeInsets(top:geometry.safeAreaInsets.top+headerHeight+8,left:0,
                                                      bottom:geometry.safeAreaInsets.bottom+controlsHeight+8,right:0),
                           onInteraction:playback.setInteracting) { id in
                    playback.selectedID=id; playback.calculate()
                }.ignoresSafeArea().accessibilityIdentifier("orbitScene")
                // Only the panels receive touches; empty space still rotates the globe.
                VStack(spacing:0) {
                    header.padding(.top,6).padding(.bottom,8)
                        .background(GeometryReader { size in Color.clear.preference(key:OrbitHeaderHeight.self,value:size.size.height) })
                        .background(alignment:.top) {
                            LinearGradient(colors:[.black.opacity(0.65),.clear],startPoint:.top,endPoint:.bottom)
                                .ignoresSafeArea(edges:.top).allowsHitTesting(false)
                        }
                    Spacer(minLength:0)
                    VStack(spacing:10) {
                        if let message=playback.message {
                            Text(message).font(.footnote).multilineTextAlignment(.center).padding(12)
                                .satelliteGlass(in:Capsule()).padding(.horizontal,20)
                        }
                        controls(compact:geometry.size.height<740)
                    }.padding(.bottom,8)
                        .background(GeometryReader { size in Color.clear.preference(key:OrbitControlsHeight.self,value:size.size.height) })
                    }
            }.background(.black)
                .onPreferenceChange(OrbitHeaderHeight.self) { headerHeight=$0 }
                .onPreferenceChange(OrbitControlsHeight.self) { controlsHeight=$0 }
        }
        .task {
            var date=initialDate
            #if DEBUG
            let arguments=ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-screenshot-orbits-day") { date=ISO8601DateFormatter().date(from:"2026-10-21T12:00:00Z") }
            if arguments.contains("--ui-screenshot-orbits-night") { date=ISO8601DateFormatter().date(from:"2026-10-21T00:00:00Z") }
            if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-orbits-forecast") {
                for _ in 0..<20 {
                    if model.session(for:model.selectedID) != nil { break }
                    try? await Task.sleep(nanoseconds:100_000_000)
                }
                date=model.session(for:model.selectedID)?.riseDate ?? Date().addingTimeInterval(3600)
            }
            #endif
            guard !Task.isCancelled,isPresented else { return }
            playback.configure(elements:model.fleetElements,selectedID:initialSatelliteID ?? model.selectedID,initialDate:date)
            model.refreshSessions()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-orbits-playback") {
                playback.speed=300; playback.togglePlayback()
            }
            #endif
        }
        .onChange(of:model.fleetElements) { _,values in playback.updateElements(values) }
        .onChange(of:playback.showAll) { _,_ in playback.calculate() }
        .onReceive(timer) { _ in if isPresented && scenePhase == .active { playback.pulse() } }
        .onChange(of:scenePhase) { _,phase in playback.setInteracting(phase != .active) }
        .onDisappear { playback.stop() }
        .preferredColorScheme(.dark)
    }
    private var header: some View {
        HStack {
            VStack(alignment:.leading,spacing:3) {
                Text("Орбиты").font(.system(size:27,weight:.bold))
                Text("Ploit Space").font(.system(size:12,weight:.medium)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button { playback.focus+=1 } label: {
                Image(systemName:"viewfinder").font(.system(size:20)).frame(width:44,height:44).satelliteGlass(in:Circle(),interactive:true)
            }.buttonStyle(.plain).accessibilityLabel("Найти выбранный спутник").accessibilityIdentifier("focusOrbit")
            Button { playback.stop(); isPresented=false } label: {
                Image(systemName:"xmark").font(.system(size:17,weight:.medium)).frame(width:44,height:44).satelliteGlass(in:Circle(),interactive:true)
            }.buttonStyle(.plain).accessibilityLabel("Закрыть орбиты").accessibilityIdentifier("closeOrbits")
        }.foregroundStyle(.white).padding(.horizontal,22)
    }
    private func controls(compact: Bool) -> some View {
        VStack(alignment:.leading,spacing:compact ? 10:14) {
            HStack {
                Label(playback.live ? "СЕЙЧАС" : "ПРОГНОЗ",systemImage:playback.live ? "dot.radiowaves.left.and.right":"clock")
                    .font(.system(size:11,weight:.bold)).foregroundStyle(playback.live ? .green:.orange)
                    .accessibilityElement(children:.ignore).accessibilityLabel(playback.live ? "СЕЙЧАС":"ПРОГНОЗ").accessibilityIdentifier("orbitTimeMode")
                Spacer()
                Text(SessionText.timestamp(playback.date))
                    .font(.system(size:14,weight:.medium)).monospacedDigit().accessibilityIdentifier("orbitDate")
            }
            ScrollView(.horizontal) {
                HStack(spacing:8) {
                    ForEach(Array(model.satellites.enumerated()),id:\.element.id) { index,sat in
                        Button {
                            playback.selectedID=sat.id; playback.focus+=1; playback.calculate()
                        } label: {
                            HStack(spacing:6) { Circle().fill(OrbitPalette.color(index)).frame(width:6,height:6); Text(sat.name) }
                                .font(.system(size:12,weight:.semibold)).padding(.horizontal,12).frame(height:34)
                                .background(playback.selectedID==sat.id ? .white.opacity(0.16):.white.opacity(0.04),in:Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("orbitSatellite-\(sat.id)")
                    }
                }
            }.scrollIndicators(.hidden)
            HStack {
                if let state=playback.states[playback.selectedID] {
                    VStack(alignment:.leading,spacing:3) {
                        Text(String(format:"%.1f° %@ · %.1f° %@",abs(state.latitude),state.latitude>=0 ? "с. ш.":"ю. ш.",abs(state.longitude),state.longitude>=0 ? "в. д.":"з. д."))
                        Text("Высота \(Int(state.altitudeKm)) км · виток \(Int(state.periodSeconds/60)) мин").foregroundStyle(.white.opacity(0.55))
                    }.font(.system(size:12)).monospacedDigit().accessibilityElement(children:.combine).accessibilityIdentifier("orbitCoordinates")
                } else { Text("Рассчитываем положение…").font(.footnote).foregroundStyle(.secondary) }
                Spacer(minLength:4)
                Button { playback.showAll.toggle() } label: {
                    Label(playback.showAll ? "Все":"Один",systemImage:playback.showAll ? "circle.grid.2x2.fill":"circle.fill").font(.system(size:12,weight:.medium)).padding(10).background(.white.opacity(0.08),in:Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("toggleAllSatellites")
            }
            if let session {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(SessionText.title(session,at:playback.date)).font(.system(size:13,weight:.semibold)).foregroundStyle(session.contains(playback.date) ? .green:.white)
                        Text("\(session.riseDate.formatted(.dateTime.day().month(.abbreviated))) · \(SessionText.interval(session)) · \(SessionText.countdown(session.duration))")
                            .font(.system(size:11)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength:4)
                    Button { playback.jump(to:session.riseDate); playback.focus+=1 } label: {
                        Text("К сеансу").font(.system(size:12,weight:.semibold)).padding(.horizontal,12).frame(height:36).background(.white.opacity(0.10),in:Capsule())
                    }.accessibilityLabel("К началу сеанса").accessibilityIdentifier("jumpToSession")
                }
            } else {
                Text(model.observer == nil ? "Задайте геопозицию для расчёта сеансов" : "В выбранное время сеансов за 48 ч нет").font(.system(size:12)).foregroundStyle(.secondary)
            }
            VStack(spacing:4) {
                Slider(value:Binding(get:{playback.offset},set:{playback.scrub($0)}),in:-6*3600...48*3600)
                    .tint(.white).accessibilityLabel("Перемотка времени").accessibilityIdentifier("orbitTimeline")
                HStack { Text("−6 ч");Spacer();Text("Перемотка времени");Spacer();Text("+48 ч") }.font(.system(size:10)).foregroundStyle(.white.opacity(0.45))
            }
            HStack(spacing:12) {
                Button { playback.togglePlayback() } label: { Image(systemName:playback.playing ? "pause.fill":"play.fill").frame(width:38,height:34) }
                    .accessibilityLabel(playback.playing ? "Пауза":"Воспроизвести").accessibilityIdentifier("playOrbit")
                Menu {
                    ForEach([1.0,60,300],id:\.self) { speed in Button("×\(Int(speed))") { playback.speed=speed } }
                } label: { Text("×\(Int(playback.speed))").font(.system(size:13,weight:.medium)).monospacedDigit() }.accessibilityIdentifier("orbitSpeed")
                Spacer()
                Button { playback.showGround.toggle() } label: { Text(playback.showGround ? "Трасса":"Орбита").font(.system(size:13,weight:.medium)) }.accessibilityIdentifier("toggleGroundTrack")
                Button { playback.now() } label: { Text("Сейчас").font(.system(size:13,weight:.semibold)).padding(.horizontal,14).frame(height:34).background(.white.opacity(0.12),in:Capsule()) }.accessibilityIdentifier("orbitNow")
            }.buttonStyle(.plain)
            Text("Влево/вправо — вращение вокруг оси. Вверх/вниз — наклон. Двумя пальцами — масштаб.")
                .font(.system(size:10)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal:false,vertical:true)
        }.padding(compact ? 16:20).satelliteGlass(in:RoundedRectangle(cornerRadius:28,style:.continuous),clear:true)
            .padding(.horizontal,16).foregroundStyle(.white)
    }
}

private struct OrbitHeaderHeight: PreferenceKey {
    static var defaultValue: CGFloat=0
    static func reduce(value: inout CGFloat,nextValue:()->CGFloat) { value=max(value,nextValue()) }
}
private struct OrbitControlsHeight: PreferenceKey {
    static var defaultValue: CGFloat=0
    static func reduce(value: inout CGFloat,nextValue:()->CGFloat) { value=max(value,nextValue()) }
}
