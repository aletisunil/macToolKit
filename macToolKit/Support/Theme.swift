import SwiftUI

// Per-feature tint identity rendered as System-Settings-style gradient icon
// tiles, shared by the menu panel, the settings sidebar and hero cards, and
// onboarding. One visual language across every surface.

/// Rounded-square gradient icon tile, System Settings style.
struct IconTile: View {
    let icon: String
    let tint: Color
    var side: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.mix(with: .white, by: 0.22), tint],
                        startPoint: .top, endPoint: .bottom))
            Image(systemName: icon)
                .font(.system(size: side * 0.48, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        .shadow(color: tint.opacity(0.3), radius: 2, y: 1)
    }
}
