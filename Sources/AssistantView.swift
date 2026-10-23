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

struct AssistantView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                (model.pointing && model.pointingStyle == .radar ? Color(red:0.025,green:0.03,blue:0.04) : Color.black).ignoresSafeArea()
                if !model.pointing || model.pointingStyle == .earth {
                    EarthView(active: !model.orbitPresented && !model.scannerPresented,latitude: model.observer?.latitude ?? 35, longitude: model.observer?.longitude ?? 35).ignoresSafeArea()
                    LinearGradient(colors: [.black.opacity(0.2),.clear,.black.opacity(0.12),.black.opacity(0.65)], startPoint: .top,endPoint: .bottom).ignoresSafeArea()
                }
                if model.pointing { PointingView() } else {
                    ScrollView {
                    VStack(spacing: 0) {
                        AssistantHeader { model.homePanel = .settings }
                        Spacer(minLength: 40)
                        Circle().fill(.white.opacity(0.45)).frame(width: 12,height: 12)
                            .overlay(Circle().stroke(.white,lineWidth: 3).frame(width: 19,height: 19))
                            .shadow(color: .white.opacity(0.5),radius: 12).accessibilityLabel("Ваше местоположение на иллюстрации Земли")
                        Spacer(minLength: 34)
                        SatelliteGlassGroup {
                        VStack(spacing: 12) {
                            status
                            Button { model.enterPointing() } label: {
                                GlassPanel(interactive: true) {
                                    HStack(spacing: 12) {
                                        SatelliteGlyph().foregroundStyle(.white).frame(width:25,height:25).frame(width:44,height:44).background(.black.opacity(0.5),in:RoundedRectangle(cornerRadius:13))
                                        VStack(alignment: .leading,spacing: 3) {
                                            Text("Наведение на спутник").font(.system(size: 17,weight: .medium))
                                            Text(model.satellite?.name ?? "Выберите спутник").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 14,weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                                    }
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("startPointing")
                            HStack(spacing: 12) {
                                smallButton("Спутники",icon:"globe.europe.africa.fill") { model.homePanel = .satellites }
                                smallButton("Пролёты",icon:"clock.arrow.circlepath") { model.homePanel = .passes }
                                smallButton("Орбиты",icon:"globe") { model.openOrbits() }
                            }
                            Button { model.scannerPresented = true } label: {
                                Label("Проверить место",systemImage:"camera.viewfinder")
                                    .font(.system(size:13,weight:.medium)).frame(maxWidth:.infinity).frame(height:42)
                                    .satelliteGlass(in:Capsule(),clear:true,interactive:true)
                            }.buttonStyle(.plain).accessibilityIdentifier("openSiteScan")
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
                    }.frame(minHeight:geometry.size.height)
                    }.scrollIndicators(.hidden)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35),value: model.pointing)
        }
        .sheet(item: $model.homePanel, onDismiss: model.presentPreparedOrbit) { item in
            switch item {
            case .satellites: SatellitePicker().environmentObject(model)
            case .passes: PassesView().environmentObject(model)
            case .settings: SettingsView().environmentObject(model)
            }
        }
        .fullScreenCover(isPresented:$model.orbitPresented) {
            OrbitExplorerView(isPresented:$model.orbitPresented,
                              initialDate:model.orbitInitialDate,
                              initialSatelliteID:model.orbitInitialSatelliteID).environmentObject(model)
        }
        .fullScreenCover(isPresented:$model.scannerPresented) { SiteScanView().environmentObject(model) }
    }
    private var status: some View {
        GlassPanel {
            VStack(alignment: .leading,spacing: 6) {
                HStack {
                    Text(statusTitle).font(.system(size: 21,weight: .semibold))
                    Spacer()
                    if model.updating { ProgressView().tint(.white) }
                }
                SessionSummaryView(model:model)
                Divider().overlay(.white.opacity(0.12)).padding(.vertical,3)
                SessionRecommendationView()
            }
        }
    }
    private var statusTitle: String {
        if model.observer == nil { return "Нужно ваше положение" }
        if model.elements == nil { return "Нужны данные орбиты" }
        if !model.usable { return "Обновите орбиту" }
        if model.look == nil { return "Рассчитываем положение" }
        if model.aboveMask { return "В окне видимости" }
        return model.aboveHorizon ? "Ниже угла обзора" : "Спутник за горизонтом"
    }
    private func smallButton(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action:action) {
            HStack(spacing: 6) { Image(systemName:icon); Text(text) }.font(.system(size: 13,weight: .medium)).frame(maxWidth:.infinity).frame(height:52).satelliteGlass(in:Capsule(),clear:true,interactive:true)
        }.buttonStyle(.plain).accessibilityIdentifier(text == "Орбиты" ? "openOrbits":text == "Спутники" ? "openSatellites":"openPasses")
    }
}

struct PointingView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { PointingContent(model:model,sensors:model.sensors) }
}


// This control has its own fixed hit area; orbit/location updates do not own presentation.
private struct AssistantHeader: View {
    var openSettings: () -> Void
    var body: some View {
        HStack {
            HStack(spacing:9) {
                SatelliteGlyph().foregroundStyle(.black).padding(4).frame(width:30,height:30)
                    .background(.white.opacity(0.85),in:RoundedRectangle(cornerRadius:8))
                Text("Ploit Space").font(.system(size:22,weight:.semibold))
            }
            Spacer(minLength:6)
            Button(action:openSettings) {
                Image(systemName:"ellipsis").font(.system(size:18,weight:.bold))
                    .frame(width:52,height:52).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .background { Circle().fill(.clear).satelliteGlass(in:Circle()).allowsHitTesting(false) }
                .accessibilityLabel("Настройки").accessibilityIdentifier("openSettings")
        }.padding(.horizontal,24).padding(.top,14)
    }
}
