import SwiftUI

/// Holds the Sounds slot until the ambient sounds UI (#44) fills it.
struct PopoverSoundsTab: View {
    private static let previews = ["cloud.rain", "cup.and.saucer", "flame", "water.waves"]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ForEach(Self.previews, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(PopoverStyle.surface))
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Ambient sounds")
                    .font(.headline)
                Text("Coming soon: ambient sounds to help you focus.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
