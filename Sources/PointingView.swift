import SwiftUI

private let pointingGreen = Color(red:0.20,green:0.95,blue:0.35)

struct RadarSector: Shape {
    var halfWidth: Double = 44
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x:rect.midX,y:rect.midY),r = min(rect.width,rect.height)*0.48
        var p = Path();p.move(to:c)
        p.addArc(center:c,radius:r,startAngle:.degrees(-90-halfWidth),endAngle:.degrees(-90+halfWidth),clockwise:false)
        p.closeSubpath();return p
    }
}

struct RadarArc: Shape {
    var scale: CGFloat = 0.48
    var halfWidth: Double = 44
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center:CGPoint(x:rect.midX,y:rect.midY),radius:min(rect.width,rect.height)*scale,startAngle:.degrees(-90-halfWidth),endAngle:.degrees(-90+halfWidth),clockwise:false)
        return p
    }
}

struct RadarDial: View {
    var bearingError: Double
    var aligned: Bool
    var available: Bool
    var body: some View {
        GeometryReader { geometry in
            let d = min(geometry.size.width,geometry.size.height)
            let r = d*0.48
            let a = bearingError * .pi / 180
            ZStack {
                Circle().stroke(Color(white:0.12),lineWidth:8).padding(d*0.02)
                    .overlay(Circle().stroke(Color(white:0.28),lineWidth:3).padding(d*0.02))
                if available {
                    RadarSector().fill(LinearGradient(colors:[pointingGreen.opacity(aligned ? 0.46:0.18),pointingGreen.opacity(0.05)],startPoint:.top,endPoint:.center))
                    RadarArc().stroke(pointingGreen.opacity(aligned ? 1:0.45),style:StrokeStyle(lineWidth:6,lineCap:.round))
                        .shadow(color:pointingGreen.opacity(aligned ? 0.45:0.1),radius:6)
                    RadarArc(scale:0.32,halfWidth:42).stroke(pointingGreen.opacity(aligned ? 0.95:0.28),style:StrokeStyle(lineWidth:5,lineCap:.round))
                        .shadow(color:pointingGreen.opacity(0.2),radius:5)
                }
                Circle().fill(aligned ? pointingGreen : Color(white:0.16)).frame(width:d*0.24,height:d*0.24)
                    .overlay(Circle().stroke(aligned ? pointingGreen.opacity(0.9):Color(white:0.26),lineWidth:2).frame(width:d*0.24,height:d*0.24))
                if available {
                    HStack(spacing:5) {
                        Capsule().fill(.white).frame(width:d*0.045,height:4)
                        Circle().fill(.white).frame(width:d*0.105,height:d*0.105).shadow(color:.black.opacity(0.35),radius:3,y:2)
                        Capsule().fill(.white).frame(width:d*0.045,height:4)
                    }.rotationEffect(.degrees(bearingError)).offset(x:r*sin(a),y:-r*cos(a))
                }
            }.frame(width:d,height:d)
        }.aspectRatio(1,contentMode:.fit)
        .animation(.easeOut(duration:0.16),value:bearingError)
        .animation(.easeInOut(duration:0.25),value:aligned)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(aligned ? "Направление совпало" : "Индикатор направления на спутник")
    }
}

struct AimAxisPicker: View {
    @Binding var axis: AimAxis
    var body: some View {
        Picker("Ось наведения",selection:$axis) {
            ForEach(AimAxis.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).accessibilityIdentifier("aimAxis")
    }
}

struct PointingContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sensors: Sensors
    @State private var lastAligned = false
    @State private var sheet: Panel?
    private enum Panel: String, Identifiable { case satellites,passes,radio;var id:String{rawValue} }
    private var dx: Double { model.target.map { AimMath.wrap($0.az-sensors.azimuth) } ?? 0 }
    private var dy: Double { model.target.map { $0.el-sensors.elevation } ?? 0 }
    private var available: Bool { model.target != nil && sensors.motionReady && (model.training || model.aboveHorizon) }
    private var status: String {
        if !sensors.motionReady { return "ПОДГОТОВКА" }
        if model.target == nil { return "НУЖНА ОРБИТА" }
        if !model.training && !model.aboveHorizon { return "ЗА ГОРИЗОНТОМ" }
        if model.aligned { return "НАПРАВЛЕНИЕ СОВПАЛО" }
        if !sensors.northIsTrue || sensors.headingAccuracy < 0 || sensors.headingAccuracy > 20 { return "ПРОВЕРЬТЕ КОМПАС" }
        return "НАВЕДЕНИЕ"
    }
    private var instruction: String {
        if !sensors.motionReady { return "Подготовьте\niPhone" }
        if model.target == nil { return "Обновите\nданные орбиты" }
        if !model.training && !model.aboveHorizon { return "Дождитесь\nпролёта спутника" }
        if model.aligned { return "Держите направление\nна спутник" }
        let horizontal = abs(dx)*cos((model.target?.el ?? 0) * .pi/180)
        if horizontal > abs(dy) && abs(dx)>8 { return dx>0 ? "Поверните iPhone\nвправо" : "Поверните iPhone\nвлево" }
        if model.axis == .top { return dy>0 ? "Поднимите\nверхнюю грань" : "Опустите\nверхнюю грань" }
        return dy>0 ? "Наклоните заднее\nстекло выше" : "Наклоните заднее\nстекло ниже"
    }
    private var hint: String {
        if !sensors.motionReady { return sensors.message }
        if !model.training && !model.aboveHorizon { return "Ближайшее окно указано в пролётах" }
        if !sensors.northIsTrue || sensors.headingAccuracy < 0 || sensors.headingAccuracy > 20 { return "Уберите магниты и откалибруйте компас" }
        return model.axis.instruction
    }
    var body: some View {
        GeometryReader { geometry in
            if model.pointingStyle == .radar { radar(size:geometry.size) } else { earth(size:geometry.size) }
        }
        .sheet(item:$sheet) { panel in
            switch panel {
            case .satellites: SatellitePicker().environmentObject(model)
            case .passes: PassesView().environmentObject(model)
            case .radio: PointingRadioView().environmentObject(model)
            }
        }
        .fullScreenCover(isPresented:$model.pointingIntro) { PointingIntro(model:model) }
        .onChange(of:model.aligned) { _,aligned in
            if aligned && !lastAligned { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            lastAligned = aligned
        }
    }
    private func header(earth: Bool) -> some View {
        HStack {
            Button {
                model.pointingStyle = earth ? .radar : .earth
            } label: {
                Image(systemName:earth ? "scope":"globe.europe.africa").font(.system(size:19,weight:.medium)).frame(width:44,height:36)
            }.accessibilityIdentifier(earth ? "showRadar":"showEarth").accessibilityLabel(earth ? "Показать круг":"Показать Землю")
            Spacer(minLength:5)
            Text(model.training ? "Тренировка" : model.satellite?.name ?? "Спутник").font(.system(size:15,weight:.semibold)).lineLimit(1)
            Spacer(minLength:5)
            if earth {
                Button { model.pointingIntro = true } label: { Image(systemName:"info.circle").font(.system(size:20)).frame(width:44,height:36) }.accessibilityLabel("Как держать iPhone")
            } else {
                Button { model.leavePointing() } label: { Text("Завершить").font(.system(size:13,weight:.semibold)).padding(.horizontal,12).padding(.vertical,8).background(Color(red:1,green:0.23,blue:0.23),in:RoundedRectangle(cornerRadius:10)) }.accessibilityIdentifier("finishPointing")
            }
        }.foregroundStyle(.white).padding(.horizontal,20).frame(height:44)
    }
    private func radar(size: CGSize) -> some View {
        let compact = size.height < 740
        let diameter = min(size.width*0.70,size.height*(compact ? 0.32:0.36))
        return VStack(spacing:0) {
            header(earth:false)
            Spacer().frame(height:size.height*(compact ? 0.06:0.11))
            RadarDial(bearingError:dx,aligned:model.aligned,available:available).frame(width:diameter,height:diameter)
            Spacer().frame(height:size.height*(compact ? 0.045:0.075))
            Text(status).font(.system(size:13,weight:.semibold)).foregroundStyle(model.aligned ? pointingGreen:.white.opacity(0.5)).accessibilityIdentifier("pointingStatus")
            Text(instruction).font(.system(size:compact ? 24:26,weight:.semibold)).lineSpacing(2).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).padding(.top,9).accessibilityIdentifier("pointingInstruction")
            Text(hint).font(.system(size:12)).foregroundStyle(.white.opacity(0.42)).multilineTextAlignment(.center).padding(.horizontal,30).padding(.top,14)
            Spacer(minLength:12)
            HStack {
                Text(model.target.map { "АЗ \(Int($0.az))°  ·  УМ \(Int($0.el))°" } ?? "АЗ —  ·  УМ —")
                if let error = model.angularError { Text("·  ОШИБКА \(Int(error))°") }
            }.font(.system(size:10,weight:.medium)).monospacedDigit().foregroundStyle(.white.opacity(0.3)).padding(.bottom,12)
            AimAxisPicker(axis:$model.axis).padding(.horizontal,26)
            Button { model.pointingIntro = true } label: {
                HStack(spacing:6) { Image(systemName:"iphone");Text("Как держать iPhone") }.font(.system(size:12)).foregroundStyle(.white.opacity(0.5)).frame(height:38)
            }.accessibilityIdentifier("showPointingIntro")
            Text(model.training ? "Учебная цель · радиосвязь не подтверждается" : "Направление по орбите · радиосвязь не подтверждена")
                .font(.system(size:10)).foregroundStyle(.white.opacity(0.3)).multilineTextAlignment(.center).padding(.horizontal,20).padding(.bottom,10)
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(red:0.025,green:0.03,blue:0.04).ignoresSafeArea())
    }
    private func earth(size: CGSize) -> some View {
        let compact = size.height < 740
        return VStack(spacing:0) {
            header(earth:true)
            Spacer(minLength:12)
            EarthAimBeacon(bearing:dx,aligned:model.aligned).frame(height:size.height*(compact ? 0.15:0.23))
            Text(model.aligned ? "Держите направление на спутник" : instruction.replacingOccurrences(of:"\n",with:" "))
                .font(.system(size:20,weight:.semibold)).multilineTextAlignment(.center).padding(.horizontal,18).accessibilityIdentifier("pointingInstruction")
            Text(model.aligned ? "Направление совпало" : status.capitalized).font(.system(size:14)).foregroundStyle(.white.opacity(0.55)).padding(.top,7).accessibilityIdentifier("pointingStatus")
            Spacer().frame(height:compact ? 20:30)
            VStack(spacing:0) {
                earthRow("Спутник",subtitle:model.satellite?.name ?? "Выбрать",icon:"antenna.radiowaves.left.and.right",color:.green,id:"earthSatellites",separator:true) { sheet = .satellites }
                earthRow("Пролёты",subtitle:"Ближайшие окна видимости",icon:"clock.fill",color:.blue,id:"earthPasses",separator:true) { sheet = .passes }
                earthRow("Радиопрофиль",subtitle:model.mode?.name ?? "Частоты и режим",icon:"waveform",color:.gray,id:"earthRadio",separator:true) { sheet = .radio }
                earthRow("Как держать iPhone",subtitle:model.axis.title,icon:"iphone",color:.orange,id:"earthIntro",separator:false) { model.pointingIntro = true }
            }.background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:15)).overlay(RoundedRectangle(cornerRadius:15).stroke(.white.opacity(0.05),lineWidth:0.5)).padding(.horizontal,24)
            Spacer(minLength:14)
            AimAxisPicker(axis:$model.axis).padding(.horizontal,24)
            Text(model.training ? "Учебная цель · радиосвязь не подтверждается" : "Радиосвязь не подтверждена внешним модулем")
                .font(.system(size:10)).foregroundStyle(.white.opacity(0.4)).padding(.top,10).padding(.bottom,14)
            Button { model.leavePointing() } label: {
                Text("Завершить наведение").font(.system(size:17)).foregroundStyle(Color(red:1,green:0.36,blue:0.34)).frame(maxWidth:.infinity).frame(height:50).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12))
            }.accessibilityIdentifier("finishPointing").padding(.horizontal,24).padding(.bottom,12)
        }.background(.black.opacity(0.24))
    }
    private func earthRow(_ title:String,subtitle:String,icon:String,color:Color,id:String,separator:Bool,action:@escaping ()->Void)->some View {
        Button(action:action) {
            VStack(spacing:0) {
                HStack(spacing:14) {
                    Image(systemName:icon).font(.system(size:23,weight:.medium)).foregroundStyle(.white).frame(width:42,height:42).background(LinearGradient(colors:[color.opacity(0.95),color.opacity(0.7)],startPoint:.top,endPoint:.bottom),in:RoundedRectangle(cornerRadius:10))
                    VStack(alignment:.leading,spacing:3) { Text(title).font(.system(size:17));Text(subtitle).font(.system(size:12)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
                    Spacer(minLength:4)
                    Image(systemName:"chevron.right").font(.system(size:15,weight:.medium)).foregroundStyle(.white.opacity(0.4))
                }.padding(.horizontal,16).frame(height:72)
                if separator { Rectangle().fill(.white.opacity(0.12)).frame(height:0.5).padding(.leading,72) }
            }
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

struct EarthAimBeacon: View {
    var bearing: Double
    var aligned: Bool
    var body: some View {
        GeometryReader { geometry in
            let x = max(-70,min(70,bearing*1.2))
            ZStack {
                Ellipse().fill(RadialGradient(colors:[pointingGreen.opacity(aligned ? 0.25:0.07),.clear],center:.center,startRadius:0,endRadius:55)).frame(width:100,height:100).offset(y:10)
                Capsule().fill(LinearGradient(colors:[.cyan.opacity(0.2),pointingGreen.opacity(aligned ? 0.25:0.04),.clear],startPoint:.top,endPoint:.bottom)).frame(width:18,height:geometry.size.height*0.62).blur(radius:10).offset(x:x*0.5,y:-10)
                SatelliteGlyph().frame(width:30,height:30).foregroundStyle(.white).shadow(color:.white.opacity(0.6),radius:9).offset(x:x,y:-geometry.size.height*0.30)
                Circle().fill(aligned ? pointingGreen:.white.opacity(0.65)).frame(width:19,height:19).overlay(Circle().stroke(.white,lineWidth:4).frame(width:27,height:27)).offset(y:geometry.size.height*0.33)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.animation(.easeOut(duration:0.2),value:bearing)
    }
}

struct PointingIntro: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 740
            VStack(spacing:0) {
                HStack {
                    Text(model.training ? "Тренировка":"Наведение на спутник").font(.system(size:14,weight:.semibold)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { model.pointingIntro = false } label: { Image(systemName:"xmark").font(.system(size:14,weight:.semibold)).frame(width:34,height:34).background(.white.opacity(0.1),in:Circle()) }.accessibilityLabel("Закрыть инструкцию")
                }.padding(.horizontal,24).padding(.top,10)
                Spacer(minLength:18)
                HoldingPhoneIllustration(axis:model.axis).frame(width:240,height:compact ? 200:250)
                Spacer().frame(height:compact ? 24:36)
                Text(model.axis == .top ? "Верхняя грань\nв сторону спутника" : "Заднее стекло\nв сторону спутника").font(.system(size:28,weight:.semibold)).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("introTitle")
                VStack(alignment:.leading,spacing:18) {
                    bullet(model.axis == .top ? "Держите экран перед собой и направляйте верхний торец iPhone." : "Ориентир — перпендикуляр к плоскости заднего стекла iPhone.")
                    bullet("Поворачивайте и наклоняйте телефон, пока точка не окажется в зелёном секторе.")
                    bullet("Зелёный круг подтверждает направление. Наличие радиосвязи проверяет внешний модуль.")
                }.padding(.horizontal,30).padding(.top,28)
                Spacer(minLength:20)
                AimAxisPicker(axis:$model.axis).padding(.horizontal,26).padding(.bottom,18)
                Button { model.pointingIntro = false } label: { Text("Продолжить").font(.system(size:17,weight:.semibold)).foregroundStyle(.black).frame(maxWidth:.infinity).frame(height:50).background(pointingGreen,in:RoundedRectangle(cornerRadius:14)) }.accessibilityIdentifier("continuePointing").padding(.horizontal,26).padding(.bottom,16)
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.black.ignoresSafeArea())
        }.preferredColorScheme(.dark)
    }
    private func bullet(_ text:String)->some View { HStack(alignment:.top,spacing:12) { Text("•");Text(text).fixedSize(horizontal:false,vertical:true) }.font(.system(size:15)).foregroundStyle(.white.opacity(0.8)) }
}

struct HoldingPhoneIllustration: View {
    var axis: AimAxis
    var body: some View {
        ZStack {
            RadarArc(scale:0.49,halfWidth:78).stroke(.white.opacity(0.35),style:StrokeStyle(lineWidth:5,lineCap:.round,dash:[0.1,12])).frame(width:220,height:220).offset(y:12)
            SatelliteGlyph().frame(width:33,height:33).foregroundStyle(.white).offset(y:-105)
            Path { p in
                p.move(to:CGPoint(x:78,y:220));p.addCurve(to:CGPoint(x:80,y:114),control1:CGPoint(x:61,y:193),control2:CGPoint(x:75,y:122))
                p.addCurve(to:CGPoint(x:93,y:139),control1:CGPoint(x:87,y:100),control2:CGPoint(x:96,y:122))
                p.move(to:CGPoint(x:148,y:112));p.addCurve(to:CGPoint(x:161,y:140),control1:CGPoint(x:179,y:116),control2:CGPoint(x:183,y:126))
                p.addCurve(to:CGPoint(x:156,y:161),control1:CGPoint(x:180,y:144),control2:CGPoint(x:178,y:153))
                p.addCurve(to:CGPoint(x:155,y:181),control1:CGPoint(x:175,y:164),control2:CGPoint(x:175,y:177))
                p.addCurve(to:CGPoint(x:141,y:209),control1:CGPoint(x:164,y:192),control2:CGPoint(x:154,y:209))
            }.stroke(.white.opacity(0.8),lineWidth:1.3).frame(width:240,height:240)
            RoundedRectangle(cornerRadius:13).fill(LinearGradient(colors:[Color(white:0.28),.black],startPoint:.top,endPoint:.bottom)).frame(width:76,height:148)
                .overlay(RoundedRectangle(cornerRadius:13).stroke(.white.opacity(0.75),lineWidth:1.3))
                .overlay(alignment:.bottom) { Capsule().fill(.white.opacity(0.6)).frame(width:27,height:2).padding(.bottom,7) }
                .overlay(alignment:.topLeading) {
                    if axis == .back { VStack(spacing:4) { HStack(spacing:4) { Circle().frame(width:9,height:9);Circle().frame(width:9,height:9) };Circle().frame(width:9,height:9) }.foregroundStyle(.white.opacity(0.8)).padding(8) }
                }
                .rotation3DEffect(.degrees(axis == .back ? -24:0),axis:(x:0,y:1,z:0))
            if axis == .top {
                Image(systemName:"arrow.up").font(.system(size:24,weight:.light)).foregroundStyle(pointingGreen).offset(y:-89)
            } else {
                Image(systemName:"arrow.up.right").font(.system(size:43,weight:.light)).foregroundStyle(pointingGreen).offset(x:67,y:-45)
            }
        }.animation(.easeInOut(duration:0.25),value:axis)
    }
}

struct PointingRadioView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section(model.satellite?.name ?? "Спутник") {
                    Text(model.mode?.name ?? "Радиопрофиль")
                    if let up = model.mode?.uplinkMHz { LabeledContent("TX",value:String(format:"%.6f МГц",up)) }
                    if let down = model.mode?.downlinkMHz { LabeledContent("RX",value:String(format:"%.6f МГц",down)) }
                    Text(model.mode?.detail ?? "").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Передача и подтверждение соединения требуют внешнего радиомодуля. Зелёный индикатор показывает совпадение направления.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Радиопрофиль").toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Готово") { dismiss() } } }
        }.tint(.white)
    }
}
