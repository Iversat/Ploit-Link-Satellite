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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let d = min(geometry.size.width,geometry.size.height)
            let r = d*0.48
            let a = bearingError * .pi / 180
            ZStack {
                Circle().stroke(Color(white:0.08),lineWidth:8).padding(d*0.02)
                    .overlay(Circle().stroke(LinearGradient(colors:[Color(white:0.35),Color(white:0.12),Color(white:0.25)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:3).padding(d*0.02))
                if available {
                    RadarSector().fill(LinearGradient(colors:[pointingGreen.opacity(aligned ? 0.46:0.18),pointingGreen.opacity(0.05)],startPoint:.top,endPoint:.center))
                    RadarArc().stroke(pointingGreen.opacity(aligned ? 1:0.45),style:StrokeStyle(lineWidth:6,lineCap:.round))
                        .shadow(color:pointingGreen.opacity(aligned ? 0.45:0.1),radius:6)
                    RadarArc(scale:0.32,halfWidth:42).stroke(pointingGreen.opacity(aligned ? 0.95:0.28),style:StrokeStyle(lineWidth:5,lineCap:.round))
                        .shadow(color:pointingGreen.opacity(0.2),radius:5)
                }
                Circle().fill(RadialGradient(colors:aligned ? [Color(red:0.42,green:1,blue:0.47),pointingGreen] : [Color(white:0.22),Color(white:0.12)],center:.topLeading,startRadius:0,endRadius:d*0.25)).frame(width:d*0.24,height:d*0.24)
                    .overlay(Circle().stroke(LinearGradient(colors:[.white.opacity(aligned ? 0.45:0.14),.clear],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1).frame(width:d*0.24,height:d*0.24))
                    .shadow(color:pointingGreen.opacity(aligned ? 0.12:0),radius:18)
                if available {
                    HStack(spacing:5) {
                        Capsule().fill(.white).frame(width:d*0.045,height:4)
                        Circle().fill(.white).frame(width:d*0.105,height:d*0.105).shadow(color:.black.opacity(0.35),radius:3,y:2)
                        Capsule().fill(.white).frame(width:d*0.045,height:4)
                    }.rotationEffect(.degrees(bearingError)).offset(x:r*sin(a),y:-r*cos(a))
                }
            }.frame(width:d,height:d)
        }.aspectRatio(1,contentMode:.fit)
        .animation(reduceMotion ? nil : .easeOut(duration:0.16),value:bearingError)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:aligned)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(aligned ? "Направление совпало" : "Индикатор направления на спутник")
    }
}

struct AimAxisPicker: View {
    @Binding var axis: AimAxis
    var body: some View {
        Picker("Ось наведения",selection:$axis) {
            ForEach(AimAxis.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).controlSize(.large).accessibilityIdentifier("aimAxis")
    }
}

struct RearAimReticle: View {
    var projection: RearAimProjection?
    var aligned: Bool
    var available: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { g in
            let d=min(g.size.width,g.size.height), radius=d*0.42
            ZStack {
                Circle().fill(.black.opacity(0.22))
                Circle().stroke(.white.opacity(0.16),lineWidth:1)
                Circle().stroke(.white.opacity(0.08),style:StrokeStyle(lineWidth:1,dash:[3,7])).padding(d*0.24)
                Rectangle().fill(.white.opacity(0.12)).frame(width:d*0.78,height:1)
                Rectangle().fill(.white.opacity(0.12)).frame(width:1,height:d*0.78)
                Circle().fill(pointingGreen.opacity(aligned ? 0.24:0.07)).frame(width:d*0.20,height:d*0.20)
                    .overlay(Circle().stroke(aligned ? pointingGreen:.white.opacity(0.65),lineWidth:2))
                    .shadow(color:pointingGreen.opacity(aligned ? 0.4:0),radius:16)
                if available, let p=projection {
                    SatelliteGlyph().foregroundStyle(aligned ? pointingGreen:.white)
                        .frame(width:d*0.11,height:d*0.11)
                        .shadow(color:.black,radius:4)
                        .offset(x:p.x*radius,y:p.y*radius)
                }
            }.frame(width:d,height:d).frame(maxWidth:.infinity,maxHeight:.infinity)
        }.aspectRatio(1,contentMode:.fit)
            .animation(reduceMotion ? nil:.linear(duration:0.08),value:projection?.x)
            .animation(reduceMotion ? nil:.linear(duration:0.08),value:projection?.y)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("Прицел заднего стекла")
            .accessibilityValue(aligned ? "Спутник в центре":projection?.behind == true ? "Спутник со стороны экрана":"Совместите спутник с центром")
            .accessibilityIdentifier("rearAimReticle")
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
    private var available: Bool { model.target != nil && sensors.motionReady && (model.training || model.aboveMask) }
    private var rearProjection: RearAimProjection? {
        guard let target=model.target, let basis=sensors.lastBasis else { return nil }
        return RearAimProjection(azimuth:target.az,elevation:target.el,basis:basis)
    }
    private var status: String {
        if !sensors.motionReady { return "ПОДГОТОВКА" }
        if model.target == nil { return "НУЖНА ОРБИТА" }
        if !model.training && !model.aboveHorizon { return "ЗА ГОРИЗОНТОМ" }
        if !model.training && !model.aboveMask { return "НИЖЕ УГЛА ОБЗОРА" }
        if !model.training && !model.clearSkyConfirmed { return "ПРОВЕРЬТЕ ОБЗОР НЕБА" }
        if model.aligned { return "НАПРАВЛЕНИЕ СОВПАЛО" }
        if !sensors.northIsTrue || sensors.headingAccuracy < 0 || sensors.headingAccuracy > 20 { return "ПРОВЕРЬТЕ КОМПАС" }
        return "НАВЕДЕНИЕ"
    }
    private var instruction: String {
        if !sensors.motionReady { return "Подготовьте\niPhone" }
        if model.target == nil { return "Обновите\nданные орбиты" }
        if !model.training && !model.aboveHorizon { return "Дождитесь\nпролёта спутника" }
        if !model.training && !model.aboveMask { return "Дождитесь подъёма\nвыше \(Int(model.minElevation))°" }
        if !model.training && !model.clearSkyConfirmed { return "Выйдите на открытое\nместо" }
        if model.aligned { return model.training ? "Держите направление\nна спутник":"Следуйте телефоном\nза спутником" }
        if model.axis == .back {
            if rearProjection?.behind == true { return "Разверните заднее стекло\nк спутнику" }
            return "Совместите спутник\nс центром прицела"
        }
        let horizontal = abs(dx)*cos((model.target?.el ?? 0) * .pi/180)
        if horizontal > abs(dy) && abs(dx)>8 { return dx>0 ? "Поверните iPhone\nвправо" : "Поверните iPhone\nвлево" }
        if model.axis == .top { return dy>0 ? "Поднимите\nверхнюю грань" : "Опустите\nверхнюю грань" }
        return dy>0 ? "Наклоните заднее\nстекло выше" : "Наклоните заднее\nстекло ниже"
    }
    private var hint: String {
        if !sensors.motionReady { return sensors.message }
        if !model.training && !model.aboveMask { return "Ближайшее окно и обратный отсчёт — ниже" }
        if !model.training && !model.clearSkyConfirmed { return "Дома и деревья могут закрывать спутник.\nПриложение не определяет препятствия." }
        if !sensors.northIsTrue || sensors.headingAccuracy < 0 || sensors.headingAccuracy > 20 { return "Уберите магниты и откалибруйте компас" }
        if model.axis == .back { return "Направляйте заднее стекло в сторону значка.\nУдерживайте спутник в центре, следуя за ним." }
        if let motion=model.trackingMotion { return motion.instruction+"\n"+model.axis.instruction }
        return model.axis.instruction
    }
    var body: some View {
        GeometryReader { geometry in
            // Keep every control reachable on compact iPhones as well.
            ScrollView(.vertical) {
                let size = CGSize(width:geometry.size.width,height:max(geometry.size.height,740))
                Group {
                    if model.pointingStyle == .radar { radar(size:size) } else { earth(size:size) }
                }.frame(width:size.width).frame(minHeight:geometry.size.height,alignment:.top)
            }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
        }
        .sheet(item:$sheet, onDismiss:model.presentPreparedOrbit) { panel in
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
        SatelliteGlassGroup {
        ZStack {
            Text(model.training ? "Тренировка" : model.satellite?.name ?? "Спутник")
                .font(.system(size:15,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth:.infinity)
                .padding(.horizontal,earth ? 56:112)
                .accessibilityIdentifier("pointingTitle")
        HStack {
            Button {
                model.pointingStyle = earth ? .radar : .earth
            } label: {
                Image(systemName:earth ? "scope":"globe.europe.africa").font(.system(size:19,weight:.medium)).frame(width:44,height:44).satelliteGlass(in:Circle(),interactive:true)
            }.buttonStyle(.plain).accessibilityIdentifier(earth ? "showRadar":"showEarth").accessibilityLabel(earth ? "Показать круг":"Показать Землю")
            Spacer(minLength:5)
            if earth {
                Button { model.pointingIntro = true } label: { Image(systemName:"info").font(.system(size:19,weight:.medium)).frame(width:44,height:44).satelliteGlass(in:Circle(),interactive:true) }.buttonStyle(.plain).accessibilityLabel("Как держать iPhone")
            } else {
                Button { model.leavePointing() } label: { Text("Завершить").font(.system(size:13,weight:.semibold)).foregroundStyle(Color(red:1,green:0.40,blue:0.38)).padding(.horizontal,16).frame(height:44).satelliteGlass(in:Capsule(),interactive:true,tint:.red.opacity(0.12)) }.buttonStyle(.plain).accessibilityIdentifier("finishPointing")
            }
        }
        }.foregroundStyle(.white).padding(.horizontal,20).frame(height:44)
        }
    }
    private func radar(size: CGSize) -> some View {
        let compact = size.height <= 740
        let diameter = min(size.width*0.70,size.height*(compact ? 0.32:0.36))
        return VStack(spacing:0) {
            header(earth:false)
            Spacer().frame(height:size.height*(compact ? 0.06:0.11))
            Group {
                if model.axis == .back { RearAimReticle(projection:rearProjection,aligned:model.aligned,available:available) }
                else { RadarDial(bearingError:dx,aligned:model.aligned,available:available) }
            }.frame(width:diameter,height:diameter)
            Spacer().frame(height:size.height*(compact ? 0.045:0.075))
            Text(status).font(.system(size:13,weight:.semibold)).foregroundStyle(model.aligned ? pointingGreen:.white.opacity(0.5)).accessibilityIdentifier("pointingStatus")
            Text(instruction).font(.system(size:compact ? 24:26,weight:.semibold)).lineSpacing(2).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).padding(.top,9).accessibilityIdentifier("pointingInstruction")
            Text(hint).font(.system(size:12)).foregroundStyle(.white.opacity(0.42)).multilineTextAlignment(.center).padding(.horizontal,30).padding(.top,14)
            if !model.training {
                SessionSummaryView(model:model,compact:true).padding(.horizontal,26).padding(.top,12)
                skyCheck.padding(.horizontal,26).padding(.top,8)
            }
            Spacer(minLength:12)
            HStack {
                Text(model.target.map { "АЗ \(Int($0.az))°  ·  УМ \(Int($0.el))°" } ?? "АЗ —  ·  УМ —")
                if let error = model.angularError { Text("·  ОШИБКА \(Int(error))°") }
            }.font(.system(size:10,weight:.medium)).monospacedDigit().foregroundStyle(.white.opacity(0.3)).padding(.bottom,12)
            AimAxisPicker(axis:$model.axis).padding(.horizontal,26)
            Button { model.pointingIntro = true } label: {
                HStack(spacing:6) { Image(systemName:"iphone");Text("Как держать iPhone") }.font(.system(size:13,weight:.medium)).foregroundStyle(.white.opacity(0.85)).padding(.horizontal,18).frame(height:44).satelliteGlass(in:Capsule(),interactive:true)
            }.buttonStyle(.plain).accessibilityIdentifier("showPointingIntro").padding(.vertical,12)
            Text(model.training ? "Учебная цель · радиосвязь не подтверждается" : "Направление по орбите · радиосвязь не подтверждена")
                .font(.system(size:10)).foregroundStyle(.white.opacity(0.3)).multilineTextAlignment(.center).padding(.horizontal,20).padding(.bottom,10)
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(red:0.025,green:0.03,blue:0.04).ignoresSafeArea())
    }
    private func earth(size: CGSize) -> some View {
        let compact = size.height <= 740
        return VStack(spacing:0) {
            header(earth:true)
            Spacer(minLength:12)
            Group {
                if model.axis == .back { RearAimReticle(projection:rearProjection,aligned:model.aligned,available:available) }
                else { EarthAimBeacon(bearing:dx,aligned:model.aligned,available:available) }
            }.frame(height:size.height*(model.training ? (compact ? 0.15:0.23):(compact ? 0.12:0.16)))
            Text(instruction.replacingOccurrences(of:"\n",with:" "))
                .font(.system(size:20,weight:.semibold)).multilineTextAlignment(.center).padding(.horizontal,18).accessibilityIdentifier("pointingInstruction")
            Text(model.aligned ? "Направление совпало" : status.capitalized).font(.system(size:14)).foregroundStyle(.white.opacity(0.55)).padding(.top,7).accessibilityIdentifier("pointingStatus")
            if !model.training {
                SessionSummaryView(model:model,compact:true).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,30).padding(.top,12)
                skyCheck.padding(.horizontal,26).padding(.top,8)
            }
            Spacer().frame(height:compact ? 12:18)
            SatelliteGlassGroup {
            VStack(spacing:0) {
                earthRow("Спутник",subtitle:model.satellite?.name ?? "Выбрать",icon:"antenna.radiowaves.left.and.right",color:.green,id:"earthSatellites",separator:true) { sheet = .satellites }
                earthRow("Пролёты",subtitle:"Ближайшие окна видимости",icon:"clock.fill",color:.blue,id:"earthPasses",separator:true) { sheet = .passes }
                earthRow("Радиопрофиль",subtitle:model.mode?.name ?? "Частоты и режим",icon:"waveform",color:.gray,id:"earthRadio",separator:true) { sheet = .radio }
                earthRow("Как держать iPhone",subtitle:model.axis.title,icon:"iphone",color:.orange,id:"earthIntro",separator:false) { model.pointingIntro = true }
            }.satelliteGlass(in:RoundedRectangle(cornerRadius:28,style:.continuous),clear:true).padding(.horizontal,24)
            }
            Spacer(minLength:14)
            AimAxisPicker(axis:$model.axis).padding(.horizontal,24)
            Text(model.training ? "Учебная цель · радиосвязь не подтверждается" : "Радиосвязь не подтверждена внешним модулем")
                .font(.system(size:10)).foregroundStyle(.white.opacity(0.4)).padding(.top,10).padding(.bottom,14)
            Button { model.leavePointing() } label: {
                Text("Завершить наведение").font(.system(size:17,weight:.medium)).foregroundStyle(Color(red:1,green:0.40,blue:0.38)).frame(maxWidth:.infinity).frame(height:54).satelliteGlass(in:Capsule(),clear:true,interactive:true)
            }.buttonStyle(.plain).accessibilityIdentifier("finishPointing").padding(.horizontal,24).padding(.bottom,12)
        }.background(.black.opacity(0.14))
    }
    @State private var showSkyConfirmation=false
    @ViewBuilder private var skyCheck: some View {
        if model.aboveMask {
            Button {
                if model.clearSkyConfirmed { model.clearSkyConfirmed=false }
                else { showSkyConfirmation=true }
            } label: {
                Label(model.clearSkyConfirmed ? "Обзор подтверждён · изменить":"Подтвердить открытый обзор неба",systemImage:model.clearSkyConfirmed ? "checkmark.circle":"sun.max")
                    .font(.system(size:12,weight:.medium)).padding(.vertical,10).frame(maxWidth:.infinity)
            }.buttonStyle(.plain).foregroundStyle(.cyan).accessibilityIdentifier("confirmClearSky")
            .confirmationDialog("Есть прямой обзор неба в направлении спутника?",isPresented:$showSkyConfirmation,titleVisibility:.visible) {
                Button("Я снаружи, направление не закрыто") { model.clearSkyConfirmed=true }
                Button("Отмена",role:.cancel) {}
            } message: { Text("Стены, крыши и деревья могут блокировать сигнал. Это ваша проверка обзора, а не измерение радиосвязи.") }
        }
    }
    private func earthRow(_ title:String,subtitle:String,icon:String,color:Color,id:String,separator:Bool,action:@escaping ()->Void)->some View {
        Button(action:action) {
            VStack(spacing:0) {
                HStack(spacing:14) {
                    GlassMenuIcon(symbol:icon,color:color)
                    VStack(alignment:.leading,spacing:4) { Text(title).font(.system(size:17));Text(subtitle).font(.system(size:13)).foregroundStyle(.white.opacity(0.65)).lineLimit(1) }
                    Spacer(minLength:4)
                    Image(systemName:"chevron.right").font(.system(size:15,weight:.medium)).foregroundStyle(.white.opacity(0.4))
                }.padding(.horizontal,18).frame(height:76).contentShape(Rectangle())
                if separator { Rectangle().fill(.white.opacity(0.14)).frame(height:0.5).padding(.leading,76).padding(.trailing,18) }
            }
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

struct EarthAimBeacon: View {
    var bearing: Double
    var aligned: Bool
    var available: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let x = max(-70,min(70,bearing*1.2))
            ZStack {
                Ellipse().fill(RadialGradient(colors:[pointingGreen.opacity(aligned ? 0.25:0.07),.clear],center:.center,startRadius:0,endRadius:55)).frame(width:100,height:100).offset(y:10)
                Capsule().fill(LinearGradient(colors:[.cyan.opacity(0.2),pointingGreen.opacity(aligned ? 0.25:0.04),.clear],startPoint:.top,endPoint:.bottom)).frame(width:18,height:geometry.size.height*0.62).blur(radius:10).offset(x:x*0.5,y:-10)
                if available { SatelliteGlyph().frame(width:30,height:30).foregroundStyle(.white).shadow(color:.white.opacity(0.6),radius:9).offset(x:x,y:-geometry.size.height*0.30) }
                Circle().fill(aligned ? pointingGreen:.white.opacity(0.65)).frame(width:19,height:19).overlay(Circle().stroke(.white,lineWidth:4).frame(width:27,height:27)).offset(y:geometry.size.height*0.33)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.animation(reduceMotion ? nil : .easeOut(duration:0.2),value:bearing)
    }
}

struct PointingIntro: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 740
            ScrollView(.vertical) {
            VStack(spacing:0) {
                HStack {
                    Text(model.training ? "Тренировка":"Наведение на спутник").font(.system(size:14,weight:.semibold)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { model.pointingIntro = false } label: { Image(systemName:"xmark").font(.system(size:16,weight:.medium)).frame(width:44,height:44).satelliteGlass(in:Circle(),interactive:true) }.buttonStyle(.plain).accessibilityLabel("Закрыть инструкцию")
                }.padding(.horizontal,24).padding(.top,10)
                Spacer(minLength:18)
                HoldingPhoneIllustration(axis:model.axis).frame(width:240,height:compact ? 200:250)
                Spacer().frame(height:compact ? 24:36)
                Text(model.axis == .top ? "Верхняя грань\nв сторону спутника" : "Заднее стекло\nв сторону спутника").font(.system(size:28,weight:.semibold)).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("introTitle")
                VStack(alignment:.leading,spacing:18) {
                    bullet(model.axis == .top ? "Держите экран перед собой и направляйте верхний торец iPhone." : "Ориентир — перпендикуляр к плоскости заднего стекла iPhone.")
                    bullet(model.axis == .back ? "Поворачивайте и наклоняйте телефон, чтобы значок спутника оказался в центре прицела. Следуйте за ним, удерживая в центре." : "Поворачивайте и наклоняйте телефон, пока точка не окажется в зелёном секторе.")
                    bullet("Наводитесь снаружи, при открытом небе. Препятствия приложение не распознаёт.")
                    bullet("Зелёный круг подтверждает направление. Наличие радиосвязи проверяет внешний модуль.")
                }.padding(.horizontal,30).padding(.top,28)
                Spacer(minLength:20)
                AimAxisPicker(axis:$model.axis).padding(.horizontal,26).padding(.bottom,18)
                Button { model.pointingIntro = false } label: { Text("Продолжить").font(.system(size:17,weight:.semibold)).foregroundStyle(.white).frame(maxWidth:.infinity).frame(height:54).satelliteGlass(in:Capsule(),interactive:true,tint:pointingGreen.opacity(0.35)) }.buttonStyle(.plain).accessibilityIdentifier("continuePointing").padding(.horizontal,26).padding(.bottom,16)
            }.frame(maxWidth:.infinity).frame(minHeight:geometry.size.height,alignment:.top)
            }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize).background(Color.black.ignoresSafeArea())
        }.preferredColorScheme(.dark)
    }
    private func bullet(_ text:String)->some View { HStack(alignment:.top,spacing:12) { Text("•");Text(text).fixedSize(horizontal:false,vertical:true) }.font(.system(size:15)).foregroundStyle(.white.opacity(0.8)) }
}

struct HoldingPhoneIllustration: View {
    var axis: AimAxis
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
        let scale = min(geometry.size.width/260,geometry.size.height/260)
        ZStack {
            phone
                .rotation3DEffect(.degrees(axis == .back ? 26:0),axis:(x:1,y:0,z:0))
                .rotation3DEffect(.degrees(axis == .back ? 35:0),axis:(x:0,y:1,z:0))
                .position(x:axis == .back ? 114:130,y:151)
            if axis == .top {
                SatelliteGlyph().frame(width:30,height:30).foregroundStyle(.white).position(x:130,y:19)
                Path { path in
                    path.move(to:CGPoint(x:130,y:61));path.addLine(to:CGPoint(x:130,y:39))
                    path.move(to:CGPoint(x:124,y:46));path.addLine(to:CGPoint(x:130,y:39));path.addLine(to:CGPoint(x:136,y:46))
                }.stroke(pointingGreen,style:StrokeStyle(lineWidth:2.5,lineCap:.round,lineJoin:.round))
            } else {
                SatelliteGlyph().frame(width:30,height:30).foregroundStyle(.white).position(x:222,y:39)
                Path { path in
                    path.move(to:CGPoint(x:114,y:151));path.addLine(to:CGPoint(x:207,y:57))
                    path.move(to:CGPoint(x:196,y:60));path.addLine(to:CGPoint(x:207,y:57));path.addLine(to:CGPoint(x:205,y:69))
                }.stroke(pointingGreen,style:StrokeStyle(lineWidth:2.5,lineCap:.round,lineJoin:.round))
                Circle().fill(pointingGreen).frame(width:7,height:7).position(x:114,y:151)
                Text("90° к стеклу").font(.system(size:10,weight:.medium)).foregroundStyle(.white.opacity(0.65)).position(x:205,y:110)
            }
        }
        .frame(width:260,height:260).scaleEffect(scale)
        .frame(width:geometry.size.width,height:geometry.size.height)
        }.animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:axis)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(axis == .back ? "Вид заднего стекла iPhone с тремя камерами. Стрелка направлена перпендикулярно задней плоскости к спутнику." : "Экран iPhone перед вами. Верхняя грань направлена к спутнику.")
    }
    private var phone: some View {
        RoundedRectangle(cornerRadius:21).fill(LinearGradient(colors:axis == .back ? [Color(white:0.43),Color(white:0.20)] : [Color(white:0.15),Color(white:0.025)],startPoint:.topLeading,endPoint:.bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius:21).stroke(.white.opacity(0.7),lineWidth:1.6))
            .overlay {
                if axis == .top {
                    RoundedRectangle(cornerRadius:17).stroke(.black.opacity(0.8),lineWidth:2.5).padding(4)
                }
            }
            .overlay(alignment:.top) {
                if axis == .top { Capsule().fill(.black).frame(width:30,height:8).padding(.top,9) }
            }
            .overlay(alignment:.bottom) {
                if axis == .top { Capsule().fill(.white.opacity(0.65)).frame(width:33,height:3).padding(.bottom,8) }
            }
            .overlay(alignment:.topLeading) {
                if axis == .back { cameraIsland.padding(7) }
            }
            .frame(width:100,height:182)
    }
    private var cameraIsland: some View {
        ZStack {
            RoundedRectangle(cornerRadius:12).fill(Color(white:0.27))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(.white.opacity(0.24),lineWidth:0.8))
            lens.position(x:15,y:15)
            lens.position(x:15,y:42)
            lens.position(x:40,y:29)
            Circle().fill(Color(red:0.94,green:0.91,blue:0.79)).frame(width:7,height:7).position(x:40,y:10)
            Circle().fill(.black.opacity(0.85)).frame(width:6,height:6)
                .overlay(Circle().stroke(.white.opacity(0.3),lineWidth:0.6)).position(x:40,y:48)
            Circle().fill(.black.opacity(0.7)).frame(width:2,height:2).position(x:50,y:14)
        }.frame(width:55,height:57)
    }
    private var lens: some View {
        Circle().fill(.black)
            .overlay(Circle().stroke(Color(white:0.55),lineWidth:1.5))
            .overlay(Circle().fill(Color(red:0.04,green:0.07,blue:0.10)).padding(3))
            .overlay(alignment:.topLeading) { Circle().fill(.white.opacity(0.25)).frame(width:4,height:3).offset(x:5,y:4) }
            .frame(width:21,height:21)
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
