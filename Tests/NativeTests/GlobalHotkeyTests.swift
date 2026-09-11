import AppKit
import Carbon
import Foundation
import Testing
import RelayCore
@testable import LocalVoiceRelay

@MainActor struct GlobalHotkeyTests {
    @Test func carbonEventsRouteToCorrectUseCaseAndSuppressHeldKeyRepeats() throws {
        _ = NSApplication.shared
        let registry = GlobalHotkeys()
        defer { registry.unregister() }
        let first = ScreenUseCase(name: "first", prompt: "test", hotkey: ScreenHotkey(keyCode: 109, shift: true))
        let second = ScreenUseCase(name: "second", prompt: "test", hotkey: ScreenHotkey(keyCode: 103, shift: true))
        var received: [UUID] = []
        let errors = registry.replace(with: [first, second]) { received.append($0) }
        #expect(errors.isEmpty)
        func event(_ identifier: UInt32, pressed: Bool = true) throws {
            var event: EventRef?
            #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased),
                                0, EventAttributes(kEventAttributeUserEvent), &event) == noErr)
            let value = try #require(event)
            defer { ReleaseEvent(value) }
            var id = EventHotKeyID(signature: 0x4C565253, id: identifier)
            #expect(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      MemoryLayout<EventHotKeyID>.size, &id) == noErr)
            #expect(SendEventToEventTarget(value, GetApplicationEventTarget()) == noErr)
        }
        try event(1)
        try event(1)
        try event(2)
        #expect(received == [first.id, second.id])
        try event(1, pressed: false)
        try event(1)
        #expect(received == [first.id, second.id, first.id])
        registry.unregister()
        #expect(registry.replace(with: [second]) { received.append($0) }.isEmpty)
        try event(1)
        #expect(received.last == second.id)
    }
}
