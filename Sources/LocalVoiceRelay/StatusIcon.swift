import AppKit
import RelayCore

enum StatusIcon {
    static func image(for indicator: RelayIndicator) -> NSImage {
        let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: nil)!
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        switch indicator {
        case .idle:
            let result = image.withSymbolConfiguration(configuration) ?? image
            result.isTemplate = true
            return result
        case .receiving, .sent:
            let color = indicator == .receiving ? NSColor.systemRed : NSColor.systemGreen
            let result = image.withSymbolConfiguration(configuration.applying(.init(paletteColors: [color]))) ?? image
            result.isTemplate = false
            return result
        }
    }
}
