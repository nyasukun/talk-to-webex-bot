import Carbon
import Foundation
import RelayCore

/// Carbon registers only the configured shortcuts, without a keyboard event tap or microphone.
@MainActor final class GlobalHotkeys {
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: UUID] = [:]
    private var pressed = Set<UInt32>()
    private var callback: ((UUID) -> Void)?
    private static let signature: OSType = 0x4C565253 // LVRS

    func replace(with useCases: [ScreenUseCase], onPress: @escaping (UUID) -> Void) -> [UUID: String] {
        unregister()
        callback = onPress
        var errors: [UUID: String] = [:]
        let active = useCases.filter { $0.enabled && $0.hotkey != nil }
        guard !active.isEmpty else { return errors }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue().handle(event)
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for (index, useCase) in active.enumerated() {
            guard let hotkey = useCase.hotkey else { continue }
            do { try hotkey.validate() }
            catch { errors[useCase.id] = error.localizedDescription; continue }
            let identifier = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let modifiers = (hotkey.control ? UInt32(controlKey) : 0) | (hotkey.option ? UInt32(optionKey) : 0)
                | (hotkey.shift ? UInt32(shiftKey) : 0) | (hotkey.command ? UInt32(cmdKey) : 0)
            let status = installed == noErr
                ? RegisterEventHotKey(hotkey.keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: identifier),
                                      GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
                : installed
            if status == noErr, let reference {
                references.append(reference)
                actions[identifier] = useCase.id
            } else {
                errors[useCase.id] = L10n.text("ホットキー \(hotkey.title) を登録できません（\(status)）。他のアプリとの競合を確認し、キーを変更して保存してください。")
            }
        }
        return errors
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard result == noErr, id.signature == Self.signature, let action = actions[id.id] else {
            return OSStatus(eventNotHandledErr)
        }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) { pressed.remove(id.id) }
        else if pressed.insert(id.id).inserted { callback?(action) }
        return noErr
    }

    func unregister() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        actions.removeAll()
        pressed.removeAll()
        callback = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit {
        for reference in references { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
