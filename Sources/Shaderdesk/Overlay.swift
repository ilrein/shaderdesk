import SwiftUI

struct GalaxyLabel: Identifiable, Equatable {
    let id: String
    let name: String
    let point: CGPoint // view coordinates (top-left origin)
    let opacity: Double
}

struct HUDData: Equatable {
    var projects = 0
    var agents = 0
    var working = 0
    var subagents = 0
    var tokens = 0
    var perMin = 0
    var split: [Split] = []

    struct Split: Equatable, Identifiable {
        let id: String // provider
        let tokens: Int
    }
}

final class OverlayModel: ObservableObject {
    @Published var labels: [GalaxyLabel] = []
    @Published var hud: HUDData?
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    static let hudInset = CGSize(width: 44, height: 110) // from bottom-left

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(model.labels) { label in
                Text(label.name.lowercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color(red: 0.81, green: 0.85, blue: 1.0))
                    .opacity(label.opacity)
                    .fixedSize()
                    .position(label.point)
                    .animation(.easeInOut(duration: 1.5), value: label.opacity)
            }
            if let hud = model.hud {
                HUDView(hud: hud)
                    .padding(.leading, Self.hudInset.width)
                    .padding(.bottom, Self.hudInset.height)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}

struct HUDView: View {
    let hud: HUDData

    var body: some View {
        HStack(alignment: .top, spacing: 34) {
            stat("Projects", value: hud.projects) { EmptyView() }
            stat("Agents", value: hud.agents) {
                if hud.working > 0 {
                    Text(hud.subagents > 0 ? "\(hud.working) working · \(hud.subagents) sub" : "\(hud.working) working")
                        .foregroundStyle(Color(red: 1.0, green: 0.81, blue: 0.48))
                } else if hud.agents > 0 {
                    Text("idle")
                }
            }
            stat("Tokens today", value: hud.tokens) {
                HStack(spacing: 9) {
                    if hud.split.count > 1 {
                        ForEach(hud.split) { s in
                            HStack(spacing: 4) {
                                Circle().fill(Self.color(s.id)).frame(width: 6, height: 6)
                                Text("\(Self.name(s.id)) \(compact(s.tokens))")
                            }
                        }
                    }
                    if hud.perMin > 0 { Text("\(compact(hud.perMin))/min") }
                }
            }
        }
        .foregroundStyle(Color(red: 0.96, green: 0.97, blue: 0.98))
        .shadow(color: .black.opacity(0.7), radius: 8, y: 1)
        .background(
            // fades to zero exactly at the frame edge, so there's no visible box
            EllipticalGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                       .init(color: .black.opacity(0.25), location: 0.55),
                                       .init(color: .clear, location: 1)],
                               center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                .frame(width: 820, height: 300)
                .allowsHitTesting(false)
        )
    }

    private func stat<Sub: View>(_ label: String, value: Int, @ViewBuilder sub: () -> Sub) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).opacity(0.62)
            Text(value.formatted(.number))
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(value: Double(value)))
            sub().font(.system(size: 10).monospacedDigit()).opacity(0.75).frame(minHeight: 12)
        }
    }

    static func name(_ id: String) -> String {
        switch id { case "claude": return "Claude"; case "gpt": return "GPT"; default: return "Other" }
    }

    static func color(_ id: String) -> Color {
        switch id {
        case "claude": return Color(red: 0.91, green: 0.58, blue: 0.42)
        case "gpt": return Color(red: 0.45, green: 0.83, blue: 0.74)
        default: return Color(red: 0.66, green: 0.70, blue: 0.79)
        }
    }
}

func compact(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return "\(Int((d / 1e3).rounded()))k" }
    return "\(n)"
}

extension HUDData {
    init(_ s: StatsSnapshot) {
        projects = s.projects.count
        agents = s.agents
        working = s.working
        subagents = s.workingSubagents
        tokens = s.tokensToday
        perMin = s.tokensPerMin
        split = ["claude", "gpt", "other"].compactMap { k in
            guard let t = s.providers[k]?.tokens, t > 0 else { return nil }
            return Split(id: k, tokens: t)
        }
    }
}
