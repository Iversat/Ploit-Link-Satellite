import SwiftUI

@main struct PloitSatelliteApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            AssistantView().environmentObject(model).preferredColorScheme(.dark)
                .tint(.white)
                .task { model.activate() }
                .onChange(of: phase) { _, value in
                    if value == .active { model.activate() } else if value == .background { model.deactivate() }
                }
        }
    }
}
