import AppKit
import CoreAudio

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let action: String
    var errorDescription: String? { "\(action) failed (OSStatus \(status))" }
}

private func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, action: action) }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func read<T>(_ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0)
        }
        try check(status, "Reading property \(selector)")
        return result
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        let value: Unmanaged<CFString>? = try read(selector, default: nil)
        return value?.takeRetainedValue() as String? ?? ""
    }

    func readArray(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "Sizing property \(selector)")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &ids), "Reading property \(selector)")
        return ids
    }
}

struct AudioSource: Identifiable, Hashable {
    enum Kind: Hashable {
        case system
        case process(AudioObjectID)
    }

    let id: String
    let name: String
    let kind: Kind
    let isPlaying: Bool

    static let system = AudioSource(id: "system", name: "All system audio", kind: .system, isPlaying: false)
}

/// Owns the current process tap and the list of apps that can be tapped.
final class AudioCapture: ObservableObject {
    @Published private(set) var sources: [AudioSource] = [.system]
    @Published private(set) var status: String?
    @Published var selectedID = AudioSource.system.id {
        didSet { if oldValue != selectedID { restart() } }
    }

    let ring = SampleRing(capacity: 1 << 16)
    private var tap: ProcessTap?

    func start() {
        refreshSources()
        restart()
    }

    func refreshSources() {
        var found: [AudioSource] = []
        let objects = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList)) ?? []
        for object in objects {
            guard let pid: pid_t = try? object.read(kAudioProcessPropertyPID, default: 0),
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let playing = ((try? object.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
            let app = NSRunningApplication(processIdentifier: pid)
            // Show regular apps (Spotify, Music…) even when paused; helpers only while they're playing.
            guard playing || app?.activationPolicy == .regular else { continue }
            let bundleID = (try? object.readString(kAudioProcessPropertyBundleID)) ?? ""
            let name = app?.localizedName ?? (bundleID.isEmpty ? "PID \(pid)" : bundleID)
            found.append(AudioSource(id: "\(bundleID)#\(pid)", name: name, kind: .process(object), isPlaying: playing))
        }
        found.sort { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        sources = [.system] + found
        if !sources.contains(where: { $0.id == selectedID }) {
            selectedID = AudioSource.system.id
        }
    }

    private func restart() {
        tap?.stop()
        tap = nil
        let source = sources.first { $0.id == selectedID } ?? .system
        do {
            tap = try ProcessTap(source: source.kind, ring: ring)
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }
}

/// A Core Audio process tap wrapped in a private aggregate device, feeding a SampleRing.
final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Phosphor.tap", qos: .userInteractive)

    init(source: AudioSource.Kind, ring: SampleRing) throws {
        let description: CATapDescription
        switch source {
        case .system:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .process(let object):
            description = CATapDescription(stereoMixdownOfProcesses: [object])
        }
        description.uuid = UUID()
        description.name = "Phosphor"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        do {
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating audio tap")

            let outputDevice: AudioDeviceID = try AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
            let outputUID = try outputDevice.readString(kAudioDevicePropertyDeviceUID)

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Phosphor Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                      "Creating aggregate device")

            let format: AudioStreamBasicDescription = try tapID.read(
                kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
                throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, action: "Reading float tap format")
            }
            ring.sampleRate = format.mSampleRate

            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first,
                      let p0 = first.mData?.assumingMemoryBound(to: Float.self) else { return }
                let channels = max(Int(first.mNumberChannels), 1)
                if buffers.count >= 2, let p1 = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    ring.write(left: p0, right: p1, stride: 1, count: Int(first.mDataByteSize) / 4)
                } else {
                    let frames = Int(first.mDataByteSize) / (4 * channels)
                    ring.write(left: p0, right: channels > 1 ? p0 + 1 : p0, stride: channels, count: frames)
                }
            }, "Creating IO proc")
            try check(AudioDeviceStart(aggregateID, procID), "Starting capture")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
