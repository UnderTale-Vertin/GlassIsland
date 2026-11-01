import SwiftUI

/// Passive glass backdrop: shapes only, zero interactive content, hit-testing
/// disabled at the hosting-view level. All interaction lives in the AppKit
/// content view above it.
struct GlassBackgroundView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassBackground(model: model)
            } else {
                LegacyBackground(model: model)
            }
        }
        .allowsHitTesting(false)
    }
}

@available(macOS 26.0, *)
private struct GlassBackground: View {
    @ObservedObject var model: IslandModel
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            ZStack {
                if model.expanded {
                    Color.clear
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
                        .glassEffectID("island", in: glassNS)
                } else {
                    Color.clear
                        .glassEffect(.regular.tint(.black.opacity(0.92)).interactive(), in: .capsule)
                        .glassEffectID("island", in: glassNS)
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.expanded)
    }
}

private struct LegacyBackground: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        ZStack {
            if model.expanded {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                Capsule().fill(Color.black.opacity(0.85))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.expanded)
    }
}
