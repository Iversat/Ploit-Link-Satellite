import SwiftUI

@main struct PloitSatelliteApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            AssistantView().environmentObject(model).preferredColorScheme(.dark)
                .tint(.white)
                .task { model.activate() }
                .task {
                    guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-") }) else { return }
                    try? await SkySceneClassifier.shared.prepare()
                }
                .onChange(of: phase) { _, value in
                    if value == .active { model.activate() } else if value == .background { model.deactivate() }
                }
        }
    }
}
