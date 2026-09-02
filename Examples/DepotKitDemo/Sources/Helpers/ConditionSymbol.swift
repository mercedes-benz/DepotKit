// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mercedes-Benz Group AG

import SwiftUI

// MARK: - App accent

extension Color {
    /// Warm amber accent used app-wide — matches the sun in the weather rows.
    static let depotAmber = Color(red: 0.96, green: 0.68, blue: 0.12)
}

// MARK: - Condition theming

extension Forecast.Condition {
    /// A representative tint for soft row backgrounds and accents.
    var tint: Color {
        switch self {
        case .clear: .depotAmber
        case .cloudy: .gray
        case .rain: .blue
        case .snow: .cyan
        case .storm: .indigo
        }
    }

    /// Gradient colors for the detail-view hero header.
    var gradientColors: [Color] {
        switch self {
        case .clear: [Color.depotAmber, .orange.opacity(0.7)]
        case .cloudy: [Color.gray, .gray.opacity(0.5)]
        case .rain: [Color.blue, .cyan.opacity(0.6)]
        case .snow: [Color.cyan.opacity(0.8), .white.opacity(0.4)]
        case .storm: [Color.indigo, .purple.opacity(0.6)]
        }
    }
}

/// Weather symbol with explicit palette colors. Multicolor rendering draws
/// clouds white on light backgrounds — palette mode keeps them visible.
struct ConditionSymbol: View {
    let condition: Forecast.Condition

    var body: some View {
        Image(systemName: condition.systemImage)
            .symbolRenderingMode(.palette)
            .foregroundStyle(primaryColor, secondaryColor)
    }

    private var primaryColor: Color {
        switch condition {
        case .clear: .yellow
        case .cloudy: .gray
        case .rain, .snow: .gray
        case .storm: .indigo
        }
    }

    private var secondaryColor: Color {
        switch condition {
        case .clear: .orange
        case .cloudy: .gray
        case .rain: .blue
        case .snow: .cyan
        case .storm: .yellow
        }
    }
}

// MARK: - Empty state illustration

/// Layered sun-behind-cloud illustration for the empty-cities state.
struct SunAndCloudIllustration: View {
    var body: some View {
        ZStack {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.depotAmber)
                .offset(x: 22, y: -18)
            Image(systemName: "cloud.fill")
                .font(.system(size: 72))
                .foregroundStyle(.gray.opacity(0.55))
                .offset(x: -10, y: 12)
        }
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }
}

// MARK: - API annotation pill

/// Pill showing which DepotKit API powers a UI section — the consistent
/// "SDK showcase" annotation used across every tab.
struct DepotAnnotation: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .imageScale(.small)
            Text(text)
                .font(.caption2.monospaced())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: Capsule())
    }
}
