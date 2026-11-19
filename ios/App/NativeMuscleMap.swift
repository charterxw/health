import SwiftUI

private struct NativeBodyPart: @unchecked Sendable { let name: String; let path: CGPath }
private struct NativeBodyGeometry: @unchecked Sendable { let box: CGRect; let parts: [NativeBodyPart] }
private actor NativeMuscleGeometry {
    static let shared = NativeMuscleGeometry()
    private var cached: [String: NativeBodyGeometry]?
    func load() -> [String: NativeBodyGeometry] {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "MusclePaths", withExtension: "json"), let data = try? Data(contentsOf: url), let document = try? JSONValue.read(data) else { return [:] }
        var result: [String: NativeBodyGeometry] = [:]
        for gender in ["male", "female"] {
            for side in ["front", "back"] {
                let body = document[gender][side], box = body["vb"].array
                guard box.count == 4, let w = box[2].number, let h = box[3].number, w > 0, h > 0 else { continue }
                let bounds = CGRect(x: box[0].number ?? 0, y: box[1].number ?? 0, width: w, height: h)
                let parts = body["parts"].object.keys.sorted().map { name -> NativeBodyPart in
                    let path = CGMutablePath()
                    for command in body["parts"][name].array {
                        let values = command.array
                        func point(_ i: Int) -> CGPoint { CGPoint(x: values[i].number ?? 0, y: values[i + 1].number ?? 0) }
                        switch values.first?.text {
                        case "M": path.move(to: point(1))
                        case "L": path.addLine(to: point(1))
                        case "C": path.addCurve(to: point(5), control1: point(1), control2: point(3))
                        case "Q": path.addQuadCurve(to: point(3), control: point(1))
                        case "Z": path.closeSubpath()
                        default: break
                        }
                    }
                    return NativeBodyPart(name: name, path: path.copy()!)
                }
                result[gender + "-" + side] = NativeBodyGeometry(box: bounds, parts: parts)
            }
        }
        cached = result; return result
    }
}
struct NativeMuscleMap: View {
    var primary: [String]
    var secondary: [String] = []
    @AppStorage("nativeBodyMapGender") private var gender = "male"
    @State private var geometry: [String: NativeBodyGeometry] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("肌群分布").font(.headline); Spacer()
                Picker("体型", selection: $gender) { Text("男").tag("male"); Text("女").tag("female") }.pickerStyle(.segmented).frame(width: 120)
            }
            if geometry.isEmpty { ProgressView().frame(maxWidth: .infinity).frame(height: 230) }
            else {
                HStack(spacing: 20) {
                    ForEach(["front", "back"], id: \.self) { side in
                        if let body = geometry[gender + "-" + side] {
                            Canvas { context, size in
                                let scale = min(size.width / body.box.width, size.height / body.box.height)
                                var drawing = context
                                drawing.concatenate(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: size.width / 2 - body.box.width * scale / 2 - body.box.minX * scale, ty: size.height / 2 - body.box.height * scale / 2 - body.box.minY * scale))
                                for part in body.parts {
                                    drawing.fill(Path(part.path), with: .color(primary.contains(part.name) ? pine : secondary.contains(part.name) ? pine.opacity(0.4) : Color(uiColor: .tertiarySystemFill)))
                                }
                            }.frame(height: 230).frame(maxWidth: .infinity).accessibilityHidden(true)
                        }
                    }
                }
            }
            HStack { Label("主要肌群", systemImage: "circle.fill").foregroundStyle(pine); Label("辅助肌群", systemImage: "circle.fill").foregroundStyle(pine.opacity(0.4)) }.font(.caption)
        }.task { geometry = await NativeMuscleGeometry.shared.load() }
    }
}
struct NativeLicenseView: View {
    var body: some View {
        ScrollView { Text(notice).font(.footnote).textSelection(.enabled).padding(20) }.navigationTitle("开源许可")
    }
    private var notice:String { guard let url=Bundle.main.url(forResource:"THIRD_PARTY_NOTICES",withExtension:"txt") else{return ""};let text = (try? String(contentsOf:url,encoding:.utf8)) ?? ""; let license = Bundle.main.url(forResource:"AGPL-3.0",withExtension:"txt").flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? ""; return text + "\n\n" + license }
}
