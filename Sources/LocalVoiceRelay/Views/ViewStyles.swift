import SwiftUI
import AppKit

extension View {
    func relayCard() -> some View {
        self.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.055)))
    }
}
