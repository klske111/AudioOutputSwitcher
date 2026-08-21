import AppKit
import ApplicationServices
import AudioToolbox
import Carbon
import CoreAudio
import Darwin
import ServiceManagement

private let appName = "声音输出切换器"
private let vKeyCode: Int64 = 9
private let escapeKeyCode: Int64 = 53

struct AudioDevice: Equatable {
    let id: AudioObjectID
    let name: String
    let transportType: UInt32
    let terminalTypes: Set<UInt32>
}

enum DeviceIcon {
    static func symbolName(for device: AudioDevice) -> String {
        let name = device.name.lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }

        if device.transportType == kAudioDeviceTransportTypeHDMI ||
           device.transportType == kAudioDeviceTransportTypeDisplayPort ||
           device.terminalTypes.contains(kAudioStreamTerminalTypeHDMI) ||
           device.terminalTypes.contains(kAudioStreamTerminalTypeDisplayPort) {
            return "display"
        }
        if name.contains("mchose") || name.contains("headset") || name.contains("耳机") {
            return "headphones"
        }
        if device.terminalTypes.contains(kAudioStreamTerminalTypeHeadphones) {
            return "headphones"
        }
        if name.contains("macbook") && (name.contains("speaker") || name.contains("扬声器")) {
            return "laptopcomputer"
        }
        if name.contains("h27t22") || name.contains("display") || name.contains("monitor") || name.contains("显示器") {
            return "display"
        }
        if device.transportType == kAudioDeviceTransportTypeAirPlay {
            return "airplayaudio"
        }
        if device.transportType == kAudioDeviceTransportTypeVirtual ||
           device.transportType == kAudioDeviceTransportTypeAggregate ||
           name.contains("virtual") || name.contains("虚拟") {
            return "waveform.path"
        }
        if device.transportType == kAudioDeviceTransportTypeBluetooth ||
           device.transportType == kAudioDeviceTransportTypeBluetoothLE {
            if name.contains("speaker") || name.contains("音箱") || name.contains("扬声器") {
                return "hifispeaker"
            }
            return "headphones"
        }
        return "speaker.wave.2"
    }

    static func image(for device: AudioDevice) -> NSImage {
        NSImage(
            systemSymbolName: symbolName(for: device),
            accessibilityDescription: device.name
        ) ?? NSImage(
            systemSymbolName: "speaker.wave.2",
            accessibilityDescription: device.name
        ) ?? NSImage()
    }

    static func menuBarImage(for device: AudioDevice) -> NSImage {
        let image = image(for: device)
        image.isTemplate = true
        return image
    }

    static func fallbackMenuBarImage(deviceName: String) -> NSImage {
        let image = NSImage(
            systemSymbolName: "speaker.wave.2",
            accessibilityDescription: deviceName
        ) ?? NSImage()
        image.isTemplate = true
        return image
    }
}

extension Notification.Name {
    static let audioOutputDidChange = Notification.Name("AudioOutputSwitcher.audioOutputDidChange")
}

enum AudioError: LocalizedError {
    case osStatus(OSStatus, String)
    case noOutputDevices

    var errorDescription: String? {
        switch self {
        case let .osStatus(status, operation):
            return "\(operation)失败（CoreAudio \(status)）"
        case .noOutputDevices:
            return "没有找到可用的声音输出设备"
        }
    }
}

enum AudioManager {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func outputDevices() throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { throw AudioError.osStatus(status, "读取设备列表") }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(0), count: count)
        status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard status == noErr else { throw AudioError.osStatus(status, "读取设备列表") }

        let devices = ids.compactMap { id -> AudioDevice? in
            guard hasOutputChannels(id), isAlive(id) else { return nil }
            return AudioDevice(
                id: id,
                name: deviceName(id) ?? "音频设备 \(id)",
                transportType: deviceTransportType(id) ?? kAudioDeviceTransportTypeUnknown,
                terminalTypes: outputTerminalTypes(id)
            )
        }
        guard !devices.isEmpty else { throw AudioError.noOutputDevices }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultOutputID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id)
        guard status == noErr else { throw AudioError.osStatus(status, "读取当前输出") }
        return id
    }

    static func setDefaultOutput(_ id: AudioObjectID) throws {
        var mutableID = id
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        // Write the system-alert route first and the ordinary output route last.
        // Some Bluetooth devices publish their route asynchronously; leaving the
        // ordinary default as the final write makes media apps follow the choice.
        for selector in [kAudioHardwarePropertyDefaultSystemOutputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(system, &address, 0, nil, size, &mutableID)
            guard status == noErr else { throw AudioError.osStatus(status, "切换声音输出") }
            size = UInt32(MemoryLayout<AudioObjectID>.size)
        }
    }

    static func volumePercent(for deviceID: AudioObjectID) -> Int? {
        if isMuted(deviceID) { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var scalar: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &scalar) == noErr {
            return max(0, min(100, Int((scalar * 100).rounded())))
        }

        var channelValues: [Float32] = []
        for channel in [UInt32(1), UInt32(2)] {
            address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel
            )
            scalar = 0
            size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(deviceID, &address),
               AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &scalar) == noErr {
                channelValues.append(scalar)
            }
        }
        guard !channelValues.isEmpty else { return nil }
        let average = channelValues.reduce(0, +) / Float32(channelValues.count)
        return max(0, min(100, Int((average * 100).rounded())))
    }

    @discardableResult
    static func setVolumePercent(_ percent: Int, for deviceID: AudioObjectID) -> Bool {
        let clamped = max(0, min(100, percent))
        var scalar = Float32(clamped) / 100
        var didSet = false

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
           settable.boolValue,
           AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &scalar
           ) == noErr {
            didSet = true
        } else {
            for channel in [UInt32(1), UInt32(2)] {
                address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: channel
                )
                settable = DarwinBoolean(false)
                if AudioObjectHasProperty(deviceID, &address),
                   AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                   settable.boolValue,
                   AudioObjectSetPropertyData(
                        deviceID,
                        &address,
                        0,
                        nil,
                        UInt32(MemoryLayout<Float32>.size),
                        &scalar
                   ) == noErr {
                    didSet = true
                }
            }
        }

        if didSet, clamped > 0 {
            setMuted(false, for: deviceID)
        }
        return didSet
    }

    private static func setMuted(_ muted: Bool, for deviceID: AudioObjectID) {
        var value: UInt32 = muted ? 1 : 0
        for channel in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel
            )
            var settable = DarwinBoolean(false)
            if AudioObjectHasProperty(deviceID, &address),
               AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
               settable.boolValue {
                _ = AudioObjectSetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<UInt32>.size),
                    &value
                )
            }
        }
    }

    private static func isMuted(_ deviceID: AudioObjectID) -> Bool {
        for channel in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel
            )
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectHasProperty(deviceID, &address),
               AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr,
               muted != 0 {
                return true
            }
        }
        return false
    }

    static func isAnyProcessAudible() -> Bool {
        processObjects().contains(where: { isRunningOutput($0) })
    }

    static func isProcessRunningOutput(bundleIdentifier: String) -> Bool {
        for process in processObjects() {
            guard processBundleIdentifier(process) == bundleIdentifier else { continue }
            return isRunningOutput(process)
        }
        return false
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }

        var processes = Array(
            repeating: AudioObjectID(0),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else {
            return []
        }
        return processes
    }

    private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(
            process,
            &address,
            0,
            nil,
            &size,
            &running
        ) == noErr && running != 0
    }

    private static func processBundleIdentifier(_ process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value as String : nil
    }

    private static func hasOutputChannels(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func isAlive(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private static func deviceName(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value as String : nil
    }

    private static func deviceTransportType(_ id: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func outputTerminalTypes(_ id: AudioObjectID) -> Set<UInt32> {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return [] }

        var streams = Array(
            repeating: AudioStreamID(0),
            count: Int(size) / MemoryLayout<AudioStreamID>.size
        )
        guard AudioObjectGetPropertyData(id, &streamsAddress, 0, nil, &size, &streams) == noErr else {
            return []
        }

        return Set(streams.compactMap { stream -> UInt32? in
            var terminalAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyTerminalType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var terminalType: UInt32 = 0
            var terminalSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                stream,
                &terminalAddress,
                0,
                nil,
                &terminalSize,
                &terminalType
            ) == noErr else { return nil }
            return terminalType
        })
    }
}

enum AppLog {
    static func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AudioOutputSwitcher.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum MediaControl {
    private typealias MRSendCommand = @convention(c) (Int32, CFDictionary?) -> UInt8

    enum NeteaseMenuResumeResult: String {
        case resumed
        case alreadyPlaying
        case permissionRequired
        case appNotRunning
        case menuUnavailable
        case actionFailed
    }

    private static var didRequestAccessibility = false

    /// Sends MediaRemote's explicit Play command. Unlike the hardware
    /// play/pause key, this is idempotent and is therefore safe to retry while
    /// Netease Music is rebuilding its AirPods route.
    static func sendExplicitPlay() -> Bool {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            AppLog.write("MediaRemote load failed")
            return false
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
            AppLog.write("MediaRemote Play symbol unavailable")
            return false
        }
        let send = unsafeBitCast(symbol, to: MRSendCommand.self)
        let accepted = send(0, nil) != 0 // MRMediaRemoteCommandPlay
        AppLog.write("MediaRemote explicit Play accepted=\(accepted)")
        return accepted
    }

    /// Netease 3.1.10 can acknowledge MediaRemote Play while remaining paused
    /// after an AirPods route change. Its own Control > Play item is the only
    /// authoritative, idempotent recovery entry point: when playback has
    /// already resumed the item is titled Pause, so we leave it untouched.
    static func resumeNeteaseUsingOwnMenu(promptIfNeeded: Bool) -> NeteaseMenuResumeResult {
        guard accessibilityIsTrusted(promptIfNeeded: promptIfNeeded) else {
            return .permissionRequired
        }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.netease.163music"
        ).first else {
            return .appNotRunning
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        guard let menuBar = axElement(appElement, attribute: kAXMenuBarAttribute as CFString),
              let controlMenu = axChildren(menuBar).first(where: {
                  ["控制", "Control"].contains(axTitle($0))
              }) else {
            return .menuUnavailable
        }

        if findMenuItem(in: controlMenu, titles: ["暂停", "Pause"]) != nil {
            return .alreadyPlaying
        }
        var playItem = findMenuItem(in: controlMenu, titles: ["播放", "Play"])
        if playItem == nil {
            guard AXUIElementPerformAction(controlMenu, kAXPressAction as CFString) == .success else {
                return .menuUnavailable
            }
            Thread.sleep(forTimeInterval: 0.06)
            playItem = findMenuItem(in: controlMenu, titles: ["播放", "Play"])
        }
        guard let playItem else { return .menuUnavailable }
        return AXUIElementPerformAction(playItem, kAXPressAction as CFString) == .success
            ? .resumed : .actionFailed
    }

    private static func accessibilityIsTrusted(promptIfNeeded: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard promptIfNeeded, !didRequestAccessibility else { return false }
        didRequestAccessibility = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func axValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        guard let value = axValue(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        axValue(element, attribute: kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private static func axTitle(_ element: AXUIElement) -> String {
        axValue(element, attribute: kAXTitleAttribute as CFString) as? String ?? ""
    }

    private static func findMenuItem(
        in element: AXUIElement,
        titles: Set<String>,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth < 6 else { return nil }
        if titles.contains(axTitle(element)) { return element }
        for child in axChildren(element) {
            if let match = findMenuItem(in: child, titles: titles, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    /// Sends the same play/pause command as the keyboard media key. We call it
    /// only when CoreAudio confirms audio was playing before the route change
    /// and no process is audible afterward.
    static func pressPlayPause() {
        let playKey = 16 // NX_KEYTYPE_PLAY
        post(playKey: playKey, down: true)
        post(playKey: playKey, down: false)
    }

    private static func post(playKey: Int, down: Bool) {
        let keyState = down ? 0xA : 0xB
        let data1 = (playKey << 16) | (keyState << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}

final class DeviceRowView: NSView {
    init(device: AudioDevice, selected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.82).cgColor
            : NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = selected
            ? NSColor.white.withAlphaComponent(0.32).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor

        let symbol = NSImageView(image: DeviceIcon.image(for: device))
        symbol.contentTintColor = selected ? .white : .secondaryLabelColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: device.name)
        title.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .regular)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let state = NSTextField(labelWithString: selected ? "松开 Option 后切换到此设备" : "声音输出设备")
        state.font = .systemFont(ofSize: 11)
        state.textColor = selected ? NSColor.white.withAlphaComponent(0.82) : .secondaryLabelColor
        state.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [title, state])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        check.contentTintColor = .white
        check.isHidden = !selected
        check.translatesAutoresizingMaskIntoConstraints = false

        addSubview(symbol)
        addSubview(labels)
        addSubview(check)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 22),
            symbol.heightAnchor.constraint(equalToConstant: 22),
            labels.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 13),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 19),
            check.heightAnchor.constraint(equalToConstant: 19)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

final class OverlayPanel: NSPanel {
    private let contentStack = NSStackView()
    private var hideWorkItem: DispatchWorkItem?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        ignoresMouseEvents = true
        animationBehavior = .utilityWindow

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.masksToBounds = true
        contentView = blur

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: blur.topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -18)
        ])
    }

    func show(devices: [AudioDevice], selectedID: AudioObjectID, subtitle: String, autoHide: Bool = false) {
        hideWorkItem?.cancel()
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let title = NSTextField(labelWithString: "声音输出")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .white
        contentStack.addArrangedSubview(title)

        let helper = NSTextField(labelWithString: subtitle)
        helper.font = .systemFont(ofSize: 12)
        helper.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(helper)
        contentStack.setCustomSpacing(14, after: helper)

        for device in devices {
            let row = DeviceRowView(device: device, selected: device.id == selectedID)
            row.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let panelHeight = CGFloat(36 + 39 + devices.count * 66)
        setContentSize(NSSize(width: 410, height: min(panelHeight, 600)))
        positionNearPointerScreen()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0.9
        }

        if autoHide {
            let item = DispatchWorkItem { [weak self] in self?.fadeOut() }
            hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: item)
        }
    }

    func fadeOut() {
        hideWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.orderOut(nil) })
    }

    private func positionNearPointerScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.maxX - frame.width - 22
        let y = visible.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 16, min(y, visible.maxY - frame.height - 16))))
    }
}

final class ShortcutController {
    private let panel: OverlayPanel
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var modifierTimer: Timer?
    private var pendingID: AudioObjectID?
    private var sessionActive = false
    private var hotKeyIsDown = false
    private var wasPlayingBeforeSelection = false
    private var sourceWasAirPods = false
    private var neteaseWasRunning = false
    private var neteaseWasPlaying = false
    private var routeGuardTimer: Timer?
    private var guardedID: AudioObjectID?
    private var guardDeadline = Date.distantPast

    init(panel: OverlayPanel) {
        self.panel = panel
    }

    var isInstalled: Bool { hotKeyRef != nil }

    func switchDirectly(to selected: AudioObjectID) {
        stopRouteGuard()
        do {
            let devices = try AudioManager.outputDevices()
            guard let target = devices.first(where: { $0.id == selected }) else {
                throw AudioError.noOutputDevices
            }
            let sourceID = try AudioManager.defaultOutputID()
            if sourceID == selected {
                AppLog.write("Menu selected current output without overlay: \(target.name) [\(selected)]")
                return
            }

            let sourceName = devices.first(where: { $0.id == sourceID })?.name ?? ""
            let sourceIsAirPods = sourceName.localizedCaseInsensitiveContains("AirPods")
            let neteaseRunning = !NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.netease.163music"
            ).isEmpty
            let neteasePlaying = AudioManager.isProcessRunningOutput(
                bundleIdentifier: "com.netease.163music"
            )
            let wasPlaying = neteasePlaying || AudioManager.isAnyProcessAudible()

            try AudioManager.setDefaultOutput(selected)
            AppLog.write("Menu selected output: \(target.name) [\(selected)]")
            startRouteGuard(for: selected, name: target.name)
            NotificationCenter.default.post(
                name: .audioOutputDidChange,
                object: nil,
                userInfo: ["deviceName": target.name]
            )
            resumePlaybackIfNeeded(
                wasPlaying: wasPlaying,
                selectedID: selected,
                useNeteaseRecovery: sourceIsAirPods && neteaseRunning && neteasePlaying
            )
        } catch {
            showError(error)
        }
    }

    func install() -> Bool {
        guard hotKeyRef == nil else { return true }
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        let callback: EventHandlerUPP = { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<ShortcutController>.fromOpaque(refcon).takeUnretainedValue()
            controller.handleCarbonHotKey(kind: GetEventKind(event))
            return noErr
        }
        let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            pointer,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            AppLog.write("Carbon event handler failed: \(handlerStatus)")
            return false
        }

        var hotKeyID = EventHotKeyID(signature: OSType(0x414F5357), id: 1) // AOSW
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            AppLog.write("Carbon hotkey registration failed: \(registerStatus)")
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            eventHandlerRef = nil
            return false
        }
        AppLog.write("Carbon Option+V hotkey installed without Accessibility permission")
        return true
    }

    private func handleCarbonHotKey(kind: UInt32) {
        if kind == UInt32(kEventHotKeyPressed) {
            guard !hotKeyIsDown else { return }
            hotKeyIsDown = true
            previewNext()
            if modifierTimer == nil {
                modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    let optionIsDown = (GetCurrentKeyModifiers() & UInt32(optionKey)) != 0
                    if self.sessionActive, !optionIsDown {
                        timer.invalidate()
                        self.modifierTimer = nil
                        self.applyPending()
                    }
                }
            }
        } else if kind == UInt32(kEventHotKeyReleased) {
            hotKeyIsDown = false
        }
    }

    private func previewNext() {
        stopRouteGuard()
        do {
            let startingNewSession = pendingID == nil
            if startingNewSession {
                neteaseWasRunning = !NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.netease.163music"
                ).isEmpty
                neteaseWasPlaying = AudioManager.isProcessRunningOutput(
                    bundleIdentifier: "com.netease.163music"
                )
                wasPlayingBeforeSelection = neteaseWasPlaying || AudioManager.isAnyProcessAudible()
                AppLog.write(
                    "Playback before selection: \(wasPlayingBeforeSelection); " +
                    "NeteasePlaying=\(neteaseWasPlaying)"
                )
            }
            let devices = try AudioManager.outputDevices()
            let baseID: AudioObjectID
            if let pendingID {
                baseID = pendingID
            } else {
                baseID = try AudioManager.defaultOutputID()
            }
            if startingNewSession {
                let sourceName = devices.first(where: { $0.id == baseID })?.name ?? ""
                sourceWasAirPods = sourceName.localizedCaseInsensitiveContains("AirPods")
                AppLog.write(
                    "Source output: \(sourceName); AirPods=\(sourceWasAirPods); " +
                    "NeteaseRunning=\(neteaseWasRunning)"
                )
            }
            let currentIndex = devices.firstIndex(where: { $0.id == baseID }) ?? -1
            let nextIndex = (currentIndex + 1) % devices.count
            pendingID = devices[nextIndex].id
            sessionActive = true
            panel.show(
                devices: devices,
                selectedID: devices[nextIndex].id,
                subtitle: "按 V 选择下一个 · 松开 Option 应用"
            )
        } catch {
            showError(error)
        }
    }

    private func applyPending() {
        guard sessionActive, let selected = pendingID else { return }
        let shouldResume = wasPlayingBeforeSelection
        let useNeteaseRecovery = sourceWasAirPods && neteaseWasRunning && neteaseWasPlaying
        defer { resetSession() }
        do {
            try AudioManager.setDefaultOutput(selected)
            let devices = try AudioManager.outputDevices()
            let name = devices.first(where: { $0.id == selected })?.name ?? "所选设备"
            AppLog.write("Selected output: \(name) [\(selected)]")
            startRouteGuard(for: selected, name: name)
            NotificationCenter.default.post(
                name: .audioOutputDidChange,
                object: nil,
                userInfo: ["deviceName": name]
            )
            resumePlaybackIfNeeded(
                wasPlaying: shouldResume,
                selectedID: selected,
                useNeteaseRecovery: useNeteaseRecovery
            )
            panel.show(devices: devices, selectedID: selected, subtitle: "已切换到 \(name)", autoHide: true)
        } catch {
            showError(error)
        }
    }

    private func cancelSelection() {
        resetSession()
        panel.fadeOut()
    }

    private func resetSession() {
        pendingID = nil
        sessionActive = false
        hotKeyIsDown = false
        wasPlayingBeforeSelection = false
        sourceWasAirPods = false
        neteaseWasRunning = false
        neteaseWasPlaying = false
    }

    private func resumePlaybackIfNeeded(
        wasPlaying: Bool,
        selectedID: AudioObjectID,
        useNeteaseRecovery: Bool
    ) {
        guard wasPlaying else { return }
        if useNeteaseRecovery {
            AppLog.write("Netease AirPods-to-output own-menu recovery armed")
            let delays: [TimeInterval] = [0.45, 1.1, 2.2, 4.0]
            for (index, delay) in delays.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard (try? AudioManager.defaultOutputID()) == selectedID else {
                        AppLog.write("Netease recovery \(index + 1) skipped: target route not stable")
                        return
                    }
                    let result = MediaControl.resumeNeteaseUsingOwnMenu(promptIfNeeded: index == 0)
                    AppLog.write(
                        "Netease own-menu recovery \(index + 1)/\(delays.count): \(result.rawValue)"
                    )
                    if result == .permissionRequired || result == .menuUnavailable {
                        _ = MediaControl.sendExplicitPlay()
                    }
                }
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            if AudioManager.isAnyProcessAudible() {
                AppLog.write("Playback continued by itself; no media command sent")
                return
            }
            guard (try? AudioManager.defaultOutputID()) == selectedID else { return }
            AppLog.write("Playback paused; sending one play/pause command")
            MediaControl.pressPlayPause()
        }
    }

    /// AirPods and a few media apps may republish the Bluetooth route when
    /// playback resumes. Keep the user's explicit choice authoritative during
    /// that short reconnection window, then release the guard so later manual
    /// changes still work normally.
    private func startRouteGuard(for id: AudioObjectID, name: String) {
        stopRouteGuard()
        guardedID = id
        guardDeadline = Date().addingTimeInterval(15)
        AppLog.write("Route guard started for \(name) [\(id)]")
        routeGuardTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self, let guardedID = self.guardedID, Date() < self.guardDeadline else {
                timer.invalidate()
                self?.routeGuardTimer = nil
                self?.guardedID = nil
                return
            }
            do {
                let available = try AudioManager.outputDevices().contains(where: { $0.id == guardedID })
                guard available else {
                    AppLog.write("Route guard stopped: selected device disappeared")
                    self.stopRouteGuard()
                    return
                }
                let current = try AudioManager.defaultOutputID()
                if current != guardedID {
                    AppLog.write("Route was reclaimed by device [\(current)]; restoring [\(guardedID)]")
                    try AudioManager.setDefaultOutput(guardedID)
                }
            } catch {
                AppLog.write("Route guard error: \(error.localizedDescription)")
            }
        }
    }

    private func stopRouteGuard() {
        routeGuardTimer?.invalidate()
        routeGuardTimer = nil
        guardedID = nil
        guardDeadline = .distantPast
    }

    private func showError(_ error: Error) {
        resetSession()
        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let panel = OverlayPanel()
    private lazy var shortcut = ShortcutController(panel: panel)
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var volumeDeviceID: AudioObjectID?
    private weak var volumeSlider: NSSlider?
    private weak var volumePercentLabel: NSTextField?
    private weak var currentDeviceMenuItem: NSMenuItem?
    private var currentDeviceMenuName = ""
    private var volumePollTimer: Timer?
    private var lastDisplayedVolume: Int?

    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--list") {
            do {
                let current = try AudioManager.defaultOutputID()
                for device in try AudioManager.outputDevices() {
                    print("\(device.id)\t\(device.id == current ? "*" : " ")\t\(device.name)")
                }
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if arguments.contains("--verify-current") {
            do {
                let current = try AudioManager.defaultOutputID()
                try AudioManager.setDefaultOutput(current)
                print("verified current output id: \(current)")
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(outputDeviceNotification(_:)),
            name: .audioOutputDidChange,
            object: nil
        )
        startMonitoringDefaultOutput()
        refreshStatusItemIcon()
        if !shortcut.install() {
            let alert = NSAlert()
            alert.messageText = "快捷键注册失败"
            alert.informativeText = "Option + V 可能被其他应用占用。请退出冲突应用后重新启动声音输出切换器。"
            alert.alertStyle = .warning
            alert.runModal()
        }
        registerLoginItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "\(appName)（Option + V）"
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        rebuildStatusMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildStatusMenu()
        startVolumePolling()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopVolumePolling()
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()

        do {
            let devices = try AudioManager.outputDevices()
            let currentID = try AudioManager.defaultOutputID()
            let currentName = devices.first(where: { $0.id == currentID })?.name ?? "声音输出"
            let volumePercent = AudioManager.volumePercent(for: currentID)
            let volumeText = volumePercent
                .map { "音量 \($0)%" } ?? "音量由设备控制"
            statusMenu.addItem(makeVolumeControlItem(deviceID: currentID, percent: volumePercent))
            statusMenu.addItem(.separator())
            currentDeviceMenuName = currentName
            lastDisplayedVolume = volumePercent

            for device in devices {
                let title: String
                if device.id == currentID {
                    title = "\(device.name)  ·  \(volumeText)"
                } else {
                    title = device.name
                }
                let item = NSMenuItem(
                    title: title,
                    action: #selector(selectOutputDevice(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NSNumber(value: device.id)
                item.state = device.id == currentID ? .on : .off
                let icon = DeviceIcon.menuBarImage(for: device)
                icon.size = NSSize(width: 17, height: 17)
                item.image = icon
                statusMenu.addItem(item)
                if device.id == currentID {
                    currentDeviceMenuItem = item
                }
            }
        } catch {
            let heading = NSMenuItem(title: "声音输出", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            statusMenu.addItem(heading)
            statusMenu.addItem(.separator())
            let errorItem = NSMenuItem(title: "无法读取输出设备", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            statusMenu.addItem(errorItem)
        }

        statusMenu.addItem(.separator())
        let shortcutItem = NSMenuItem(title: "Option + V：快速切换", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        statusMenu.addItem(shortcutItem)

        let loginItem = NSMenuItem(title: "登录时自动启动", action: nil, keyEquivalent: "")
        loginItem.isEnabled = false
        loginItem.state = .on
        statusMenu.addItem(loginItem)
        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func makeVolumeControlItem(deviceID: AudioObjectID, percent: Int?) -> NSMenuItem {
        volumeDeviceID = deviceID
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 46))

        let lowIcon = NSImageView(image: NSImage(
            systemSymbolName: "speaker.fill",
            accessibilityDescription: "低音量"
        ) ?? NSImage())
        lowIcon.contentTintColor = .secondaryLabelColor
        lowIcon.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(
            value: Double(percent ?? 0),
            minValue: 0,
            maxValue: 100,
            target: self,
            action: #selector(volumeSliderChanged(_:))
        )
        slider.isContinuous = true
        slider.isEnabled = percent != nil
        slider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider = slider

        let highIcon = NSImageView(image: NSImage(
            systemSymbolName: "speaker.wave.3.fill",
            accessibilityDescription: "高音量"
        ) ?? NSImage())
        highIcon.contentTintColor = .secondaryLabelColor
        highIcon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: percent.map { "\($0)%" } ?? "设备控制")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .right
        label.textColor = percent == nil ? .tertiaryLabelColor : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        volumePercentLabel = label

        container.addSubview(lowIcon)
        container.addSubview(slider)
        container.addSubview(highIcon)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            lowIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            lowIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            lowIcon.widthAnchor.constraint(equalToConstant: 17),
            lowIcon.heightAnchor.constraint(equalToConstant: 17),
            slider.leadingAnchor.constraint(equalTo: lowIcon.trailingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            highIcon.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
            highIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            highIcon.widthAnchor.constraint(equalToConstant: 19),
            highIcon.heightAnchor.constraint(equalToConstant: 19),
            label.leadingAnchor.constraint(equalTo: highIcon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 66),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        item.view = container
        return item
    }

    @objc private func volumeSliderChanged(_ sender: NSSlider) {
        guard let deviceID = volumeDeviceID else { return }
        let percent = Int(sender.doubleValue.rounded())
        if AudioManager.setVolumePercent(percent, for: deviceID) {
            volumePercentLabel?.stringValue = "\(percent)%"
            lastDisplayedVolume = percent
            updateCurrentDeviceMenuTitle(percent: percent)
            refreshStatusItemIcon()
        } else {
            sender.isEnabled = false
            volumePercentLabel?.stringValue = "设备控制"
            volumePercentLabel?.textColor = .tertiaryLabelColor
        }
    }

    private func startVolumePolling() {
        stopVolumePolling()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.refreshVolumeControlsFromSystem()
        }
        volumePollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshVolumeControlsFromSystem()
    }

    private func stopVolumePolling() {
        volumePollTimer?.invalidate()
        volumePollTimer = nil
    }

    private func refreshVolumeControlsFromSystem() {
        guard let deviceID = volumeDeviceID,
              let currentID = try? AudioManager.defaultOutputID(),
              currentID == deviceID else { return }
        let percent = AudioManager.volumePercent(for: deviceID)
        guard percent != lastDisplayedVolume else { return }
        lastDisplayedVolume = percent

        if let percent {
            volumeSlider?.isEnabled = true
            volumeSlider?.doubleValue = Double(percent)
            volumePercentLabel?.stringValue = "\(percent)%"
            volumePercentLabel?.textColor = .labelColor
            updateCurrentDeviceMenuTitle(percent: percent)
        } else {
            volumeSlider?.isEnabled = false
            volumePercentLabel?.stringValue = "设备控制"
            volumePercentLabel?.textColor = .tertiaryLabelColor
            currentDeviceMenuItem?.title = currentDeviceMenuName
        }
        refreshStatusItemIcon()
    }

    private func updateCurrentDeviceMenuTitle(percent: Int) {
        currentDeviceMenuItem?.title = "\(currentDeviceMenuName)  ·  音量 \(percent)%"
    }

    @objc private func selectOutputDevice(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        shortcut.switchDirectly(to: AudioObjectID(value.uint32Value))
        rebuildStatusMenu()
    }

    private func startMonitoringDefaultOutput() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshStatusItemIcon() }
        }
        outputListener = listener
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        AppLog.write("Default-output icon listener status: \(status)")
    }

    private func refreshStatusItemIcon(deviceName suppliedName: String? = nil) {
        let currentID = try? AudioManager.defaultOutputID()
        let currentDevice = try? AudioManager.outputDevices().first(where: { $0.id == currentID })
        let name = currentDevice?.name ?? suppliedName ?? "声音输出"
        statusItem.button?.image = currentDevice.map(DeviceIcon.menuBarImage(for:))
            ?? DeviceIcon.fallbackMenuBarImage(deviceName: name)
        let volumeText: String
        if let currentID,
           let percent = AudioManager.volumePercent(for: currentID) {
            volumeText = "音量 \(percent)%"
        } else {
            volumeText = "音量由设备控制"
        }
        statusItem.button?.toolTip = "\(name) · \(volumeText) · Option + V 切换"
    }

    @objc private func outputDeviceNotification(_ notification: Notification) {
        refreshStatusItemIcon(deviceName: notification.userInfo?["deviceName"] as? String)
    }

    private func registerLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
                AppLog.write("Login item status: \(SMAppService.mainApp.status.rawValue)")
            } catch {
                AppLog.write("Login item registration failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func showCurrentDevices() {
        do {
            let devices = try AudioManager.outputDevices()
            let current = try AudioManager.defaultOutputID()
            panel.show(devices: devices, selectedID: current, subtitle: "当前正在使用", autoHide: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = appName
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
