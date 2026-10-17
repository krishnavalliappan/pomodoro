import AppKit
import SwiftUI

struct PopoverView: View {
    static let size = CGSize(width: 280, height: 160)

    var body: some View {
        VStack(spacing: 12) {
            Text("Pomodoro")
                .font(.title2.weight(.semibold))
            Text("Focus timer coming soon")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
