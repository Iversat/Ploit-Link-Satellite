import SwiftUI

struct SatellitePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var showOrbits = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.satellites.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) }) { satellite in
                        Button {
                            Task { await model.select(id:satellite.id) }; dismiss()
                        } label: {
                            VStack(alignment:.leading,spacing:10) {
                            SatelliteSessionLabel(id:satellite.id)
                            HStack(spacing:13) {
                                SatelliteGlyph().frame(width:26,height:26).foregroundStyle(.white).frame(width:44,height:44).background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
                                VStack(alignment:.leading,spacing:4) {
                                    Text(satellite.name).font(.system(size:17,weight:.semibold)).foregroundStyle(.white)
                                    Text(satellite.subtitle).font(.system(size:12)).foregroundStyle(.secondary)
                                    Text(satellite.kind).font(.system(size:10,weight:.medium)).foregroundStyle(.cyan.opacity(0.8))
                                }
                                Spacer()
                                if model.selectedID == satellite.id { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) }
                            }.padding(.vertical,6)
                            }.padding(.vertical,4)
                        }.accessibilityIdentifier("satellite-\(satellite.id)")
                    }
                } footer: { Text("Спутник в каталоге не означает, что его ретранслятор сейчас включён. Для каждого режима указан источник и дата проверки.") }
                if let satellite=model.satellite {
                    Section("Режим · \(satellite.name)") {
                        Picker("Выберите режим",selection:$model.modeID) { ForEach(satellite.modes) { Text($0.name).tag($0.id) } }
                        if let mode=model.mode {
                            if let up=mode.uplinkMHz { LabeledContent("Земля → спутник",value:String(format:"%.6f МГц",up)) }
                            if let down=mode.downlinkMHz { LabeledContent("Спутник → Земля",value:String(format:"%.6f МГц",down)) }
                            Text(mode.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(satellite.status).font(.footnote).foregroundStyle(.secondary)
                        Link("Страница оператора ↗",destination:URL(string:satellite.source)!)
                        Text("Проверка: \(satellite.checked)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("Спутники").searchable(text:$query,prompt:"Название спутника")
                .toolbar {
                    ToolbarItem(placement:.topBarLeading) { Button { showOrbits=true } label: { Image(systemName:"globe") }.accessibilityLabel("Орбиты спутников") }
                    ToolbarItem(placement:.topBarTrailing) { Button("Готово") { dismiss() } }
                }
        }.tint(.white).presentationDragIndicator(.visible)
            .task { model.refreshSessions() }
            .fullScreenCover(isPresented:$showOrbits) { OrbitExplorerView(isPresented:$showOrbits).environmentObject(model) }
    }
}

struct PassesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var showOrbits = false
    @State private var orbitDate: Date?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack { SatelliteGlyph().frame(width:22,height:22);Text(model.satellite?.name ?? "Спутник").fontWeight(.semibold) }
                    LabeledContent("Маска горизонта",value:"\(Int(model.minElevation))°")
                    Text("Окна рассчитаны для вашего положения на ближайшие 48 часов. Время местное. Препятствия и включение ретранслятора не учитываются.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Ближайшие окна связи") {
                    if model.predicting { HStack { ProgressView();Text("Рассчитываем орбиту…") } }
                    if model.passes.isEmpty && !model.predicting {
                        ContentUnavailableView("Нет прогноза",systemImage:"clock.badge.questionmark",description:Text(model.observer == nil ? "Задайте положение наблюдателя." : "Обновите TLE или измените маску горизонта."))
                    }
                    ForEach(model.passes.filter{$0.setDate>model.clock}) { pass in
                        VStack(alignment:.leading,spacing:8) {
                            HStack { Text(pass.contains(model.clock) ? "Сейчас над горизонтом" : pass.riseDate.formatted(.dateTime.day().month(.abbreviated))).font(.headline);Spacer();Text("↗ \(Int(pass.maxElevation))°").foregroundStyle(.green) }
                            HStack { Text(pass.riseDate.formatted(date:.omitted,time:.shortened));Image(systemName:"arrow.right").font(.caption).foregroundStyle(.secondary);Text(pass.setDate.formatted(date:.omitted,time:.shortened));Spacer();Text("\(Int((pass.set-pass.rise)/60)) мин").foregroundStyle(.secondary) }.font(.system(.body,design:.rounded)).monospacedDigit()
                            Button { orbitDate=pass.riseDate; showOrbits=true } label: { Label("Посмотреть пролёт на орбите",systemImage:"globe") }.font(.system(size:13)).padding(.top,3).accessibilityIdentifier("previewPass-\(pass.id)")
                        }.padding(.vertical,5)
                    }
                }
                if let look=model.look, let mode=model.mode {
                    Section("Доплер сейчас · расчёт") {
                        LabeledContent("Дальность",value:"\(Int(look.rangeKm)) км")
                        LabeledContent("Радиальная скорость",value:String(format:"%+.2f км/с",look.rangeRate))
                        if let up=mode.uplinkMHz { LabeledContent("TX с поправкой",value:String(format:"%.6f МГц",look.uplink(up))) }
                        if let down=mode.downlinkMHz { LabeledContent("RX с поправкой",value:String(format:"%.6f МГц",look.downlink(down))) }
                        Text("Поправки информационные; управление частотой внешнего радио ещё не подключено.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("Пролёты")
                .toolbar {
                    ToolbarItem(placement:.topBarLeading) { Button { orbitDate=nil; showOrbits=true } label: { Image(systemName:"globe") }.accessibilityLabel("Орбиты спутников") }
                    ToolbarItem(placement:.topBarTrailing) { Button("Готово") { dismiss() } }
                }
        }.tint(.white).presentationDragIndicator(.visible)
            .fullScreenCover(isPresented:$showOrbits) { OrbitExplorerView(isPresented:$showOrbits,initialDate:orbitDate,initialSatelliteID:model.selectedID).environmentObject(model) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Положение наблюдателя") {
                    Toggle("Координаты вручную",isOn:$model.manualLocation)
                    if model.manualLocation {
                        TextField("Широта −90…90",text:$model.manualLat).keyboardType(.numbersAndPunctuation)
                        TextField("Долгота −180…180",text:$model.manualLon).keyboardType(.numbersAndPunctuation)
                        if model.observer == nil { Text("Введите корректные широту и долготу.").foregroundStyle(.orange) }
                    } else {
                        if let observer=model.sensors.observer { Text(String(format:"%.4f°, %.4f°",observer.latitude,observer.longitude)).monospaced() }
                        Button("Разрешения iPhone") { if let url=URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    }
                    Text("Координаты используются только на этом iPhone. Гироскоп показывает поворот, компас задаёт север.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Ориентация антенны") {
                    Picker("Ось наведения",selection:$model.axis) { ForEach(AimAxis.allCases) { Text($0.title).tag($0) } }
                    Picker("Вид наведения",selection:$model.pointingStyle) { ForEach(PointingStyle.allCases) { Text($0.title).tag($0) } }
                    Text("Выбирайте ось, соответствующую максимуму диаграммы вашей антенны. Для штыря наведение вдоль штыря может попадать в провал диаграммы.").font(.caption).foregroundStyle(.secondary)
                    Slider(value:$model.minElevation,in:0...30,step:5) { Text("Маска горизонта") }
                    LabeledContent("Минимальный угол места",value:"\(Int(model.minElevation))°")
                }
                Section("Орбитальные данные") {
                    if let elements=model.elements {
                        LabeledContent("Возраст TLE",value:String(format:"%.1f суток",elements.ageDays()))
                        if let epoch=elements.epoch { LabeledContent("Эпоха",value:epoch.formatted(date:.numeric,time:.shortened)) }
                        if model.stale { Text("После 3 суток точность снижается. После 14 суток наведение отключается.").font(.caption).foregroundStyle(.orange) }
                    }
                    Button { Task { await model.refresh() } } label: { HStack { Text("Обновить TLE · CelesTrak");Spacer();if model.updating { ProgressView() } } }.disabled(model.updating)
                    if let error=model.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    Text("Интернет нужен для обновления TLE. Затем орбита и наведение вычисляются офлайн. Сетевые запросы содержат только номер спутника.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Тренировка наведения") { dismiss();model.enterPointing(training:true) }
                    Text("Тренировка использует условную цель 135° / 45°, а не реальный спутник.").font(.caption).foregroundStyle(.secondary)
                }
                Section("О приложении") {
                    Text("Ploit Space · 1.3.1").fontWeight(.medium)
                    Text("Визуальный помощник для внешнего радиоустройства. Не измеряет спутниковый сигнал и не передаёт сообщения встроенным модемом iPhone.").font(.footnote).foregroundStyle(.secondary)
                    Text("Приложение создано независимо от Apple. Иллюстрация Земли: NASA Earth Observatory, Black Marble 2016. Орбиты: satellite.js (MIT), CelesTrak.").font(.caption).foregroundStyle(.secondary)
                    Link("Данные и лицензии",destination:URL(string:"https://github.com/Iversat/Ploit-Satellite-iOS")!)
                }
            }.navigationTitle("Настройки")
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Готово") { model.saveSettings();dismiss() } } }
                .onDisappear { model.saveSettings() }
        }.tint(.white).presentationDragIndicator(.visible)
    }
}

struct SatelliteSessionLabel: View {
    @EnvironmentObject var model: AppModel
    var id: Int
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            if let pass=model.session(for:id) {
                Label(SessionText.title(pass,at:model.clock),systemImage:"clock")
                    .foregroundStyle(pass.contains(model.clock) ? .green:.cyan)
                Text("\(pass.riseDate.formatted(.dateTime.day().month(.abbreviated))) · \(SessionText.interval(pass)) · \(SessionText.countdown(pass.duration))")
                    .foregroundStyle(.secondary)
            } else {
                Label(model.observer == nil ? "Нужна геопозиция для сеансов" : model.calculatingSessions ? "Рассчитываем сеанс…" : model.fleetElements[id] == nil ? "Нужны данные орбиты" : (model.fleetElements[id]?.ageDays() ?? 999)>14 ? "Обновите устаревшую орбиту":"Нет сеансов за 48 часов",systemImage:"clock")
                    .foregroundStyle(.secondary)
            }
        }.font(.system(size:11,weight:.medium)).monospacedDigit().accessibilityElement(children:.combine).accessibilityIdentifier("session-\(id)")
    }
}
