import SwiftUI

struct SessionRecommendationView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Toggle(isOn:$model.autoSelectSatellite) {
                Label("Автовыбор спутника",systemImage:"sparkles")
                    .font(.system(size:13,weight:.medium))
            }.tint(.cyan).accessibilityIdentifier("autoSelectSatellite")
            if let recommendation=model.recommendedSession {
                Text(recommendation.headline).font(.system(size:13,weight:.semibold)).foregroundStyle(.cyan)
                    .accessibilityIdentifier("recommendedSession")
                Text(recommendation.detail).font(.system(size:11)).foregroundStyle(.white.opacity(0.65))
            } else {
                Text(model.observer == nil ? "Задайте геопозицию для поиска пролётов" : model.calculatingSessions ? "Ищем ближайшее окно видимости…" : "Нет подходящих окон по актуальным данным")
                    .font(.system(size:12)).foregroundStyle(.white.opacity(0.6)).accessibilityIdentifier("recommendationUnavailable")
            }
            Text("Прогноз видимости · работа ретранслятора не подтверждена")
                .font(.system(size:10)).foregroundStyle(.white.opacity(0.45))
        }.onChange(of:model.autoSelectSatellite) { _,_ in model.applyAutomaticSelectionIfNeeded() }
    }
}
