import SwiftUI
import Combine

@MainActor final class OrbitPlayback: ObservableObject {
    @Published var selectedID = 25544
    @Published var showAll = true
    @Published var showGround = false
    @Published var date = Date()
    @Published var live = true
    @Published var playing = false
    @Published var speed: Double = 60
    @Published var states: [Int:OrbitalState] = [:]
    @Published var paths: [Int:OrbitalTrajectory] = [:]
    @Published var pathDates: [Int:Date] = [:]
    @Published var message: String?
    @Published var focus = 0
    private(set) var anchor = Date()
    private var elements: [Int:Elements] = [:]
    private let engine=OrbitEngine()
    private var calculation: Task<Void,Never>?
    private var requestID=UUID()
    private var previousWall=Date()
    private var revision: [Int:Elements] = [:]
    var offset: Double { date.timeIntervalSince(anchor) }
    var visibleIDs: [Int] { showAll ? elements.keys.sorted() : [selectedID] }
    func configure(elements: [Int:Elements], selectedID: Int, initialDate: Date?) {
        self.selectedID=selectedID; anchor=Date(); date=initialDate ?? anchor
        live=initialDate == nil; previousWall=Date()
        updateElements(elements)
    }
    func updateElements(_ values: [Int:Elements]) {
        guard values != revision else { return }
        revision=values; elements=values
        paths=[:]; pathDates=[:]; calculate()
    }
    func scrub(_ offset: Double) {
        live=false; playing=false
        date=anchor.addingTimeInterval(min(48*3600,max(-6*3600,offset))); calculate()
    }
    func jump(to date: Date) { scrub(date.timeIntervalSince(anchor)) }
    func now() { live=true; playing=false; anchor=Date(); date=anchor; calculate() }
    func togglePlayback() {
        if playing { playing=false } else { live=false; playing=true; previousWall=Date() }
    }
    func pulse() {
        let wall=Date(),elapsed=min(1,max(0,wall.timeIntervalSince(previousWall)))
        previousWall=wall
        if live { date=wall }
        else if playing {
            date=min(anchor.addingTimeInterval(48*3600),date.addingTimeInterval(elapsed*speed))
            if offset>=48*3600 { playing=false }
        } else { return }
        calculate()
    }
    func calculate() {
        calculation?.cancel()
        let token=UUID(),date=self.date,ids=visibleIDs
        requestID=token
        // Do not present a previous instant's marker after a scrub.
        calculation=Task {
            var next: [Int:OrbitalState]=[:]
            for id in ids {
                guard !Task.isCancelled, requestID==token else { return }
                guard let tle=elements[id], tle.ageDays(at:date)<=14 else { continue }
                if let state=try? await engine.state(elements:tle,date:date) { next[id]=state }
                guard !Task.isCancelled, requestID==token else { return }
                if pathDates[id].map({abs($0.timeIntervalSince(date))>30}) ?? true {
                    if let path=try? await engine.trajectory(elements:tle,date:date) {
                        guard !Task.isCancelled, requestID==token else { return }
                        paths[id]=path; pathDates[id]=date
                    }
                }
            }
            guard !Task.isCancelled, requestID==token else { return }
            states=next
            message=next.isEmpty ? "Обновите данные орбит для выбранного времени" : nil
        }
    }
    func stop() { calculation?.cancel() }
}

enum OrbitPalette {
    static func color(_ index: Int) -> Color { [Color.cyan,.orange,.mint,.pink,.purple][index%5] }
}

struct OrbitExplorerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback=OrbitPlayback()
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
                           observer:model.observer,focus:playback.focus,animated:playback.live || playback.playing) { id in
                    playback.selectedID=id; playback.calculate()
                }.padding(.bottom,geometry.size.height*0.22).ignoresSafeArea().accessibilityIdentifier("orbitScene")
                VStack(spacing:12) {
                    header
                    Spacer(minLength:20)
                    if let message=playback.message {
                        Text(message).font(.footnote).multilineTextAlignment(.center).padding(12)
                            .satelliteGlass(in:Capsule()).padding(.horizontal,20)
                    }
                    controls(compact:geometry.size.height<740)
                }.padding(.top,6).padding(.bottom,8)
            }.background(.black)
        }
        .task {
            var date=initialDate
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-orbits-forecast") { date=model.session(for:model.selectedID)?.riseDate ?? Date().addingTimeInterval(3600) }
            #endif
            playback.configure(elements:model.fleetElements,selectedID:initialSatelliteID ?? model.selectedID,initialDate:date)
            model.refreshSessions()
        }
        .onChange(of:model.fleetElements) { _,values in playback.updateElements(values) }
        .onChange(of:playback.showAll) { _,_ in playback.calculate() }
        .onReceive(timer) { _ in playback.pulse() }
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
            Button { dismiss() } label: {
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
                Text(playback.date.formatted(.dateTime.day().month(.abbreviated).hour(.twoDigits(amPM:.omitted)).minute(.twoDigits).second(.twoDigits)))
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
                        Image(systemName:"forward.end.fill").font(.system(size:18)).frame(width:36,height:36)
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
                } label: { Text("×\(Int(playback.speed))").font(.system(size:13,weight:.medium)).monospacedDigit() }
                Spacer()
                Button { playback.showGround.toggle() } label: { Text(playback.showGround ? "Трасса":"Орбита").font(.system(size:13,weight:.medium)) }.accessibilityIdentifier("toggleGroundTrack")
                Button { playback.now() } label: { Text("Сейчас").font(.system(size:13,weight:.semibold)).padding(.horizontal,14).frame(height:34).background(.white.opacity(0.12),in:Capsule()) }.accessibilityIdentifier("orbitNow")
            }.buttonStyle(.plain)
            Text("Вращайте одним пальцем · масштаб двумя. Окно видимости по TLE, время местное.")
                .font(.system(size:10)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal:false,vertical:true)
        }.padding(compact ? 16:20).satelliteGlass(in:RoundedRectangle(cornerRadius:28,style:.continuous),clear:true)
            .padding(.horizontal,16).foregroundStyle(.white)
    }
}
