import SwiftUI

// Shared by the home screen and both pointing styles, using one clock and pass cache.
struct SessionSummaryView: View {
    @ObservedObject var model: AppModel
    var compact = false
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            if let look=model.look {
                Text(String(format:"%@ · азимут %.0f° · угол %.0f°",model.satellite?.name ?? "Спутник",look.azimuth,look.elevation))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if model.observer == nil {
                Text("Разрешите геопозицию или задайте координаты в настройках.")
            } else if !model.usable {
                Text("Обновите данные орбиты для расчёта сеансов.")
            } else if let pass=model.session(for:model.selectedID) {
                Text(SessionText.title(pass,at:model.clock)).fontWeight(.semibold).foregroundStyle(.cyan)
                Text("\(pass.riseDate.formatted(.dateTime.day().month(.abbreviated))) · \(SessionText.interval(pass)) · \(SessionText.countdown(pass.duration))")
                Text("Окно выше \(Int(model.minElevation))° · время местное")
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Text(model.calculatingSessions || model.predicting ? "Рассчитываем ближайший сеанс…":"За ближайшие 48 часов окон выше \(Int(model.minElevation))° нет.")
            }
        }.font(.system(size:compact ? 11:13)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal:false,vertical:true)
            .accessibilityElement(children:.combine).accessibilityIdentifier("sessionSummary")
    }
}
