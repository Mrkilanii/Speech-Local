import Foundation
import AVFoundation
import CoreAudio
import Synchronization

/// Captures what the Mac is playing — the other people on a call — into an
/// `AudioRingBuffer`, in the same 16 kHz mono the microphone path produces.
///
/// Chosen over ScreenCaptureKit after measuring both (see `clone-run/research.md`
/// §9): they capture equally well, but this is audio asking for audio
/// permission. ScreenCaptureKit would mean opening a screen-capture session,
/// throwing its video away, asking for Screen Recording, and lighting the
/// purple capture indicator on a note-taking app.
///
/// The shape is a global mono tap that excludes this process — so the app never
/// records its own start chime — wired into a private aggregate device whose
/// IOProc converts and writes. Muting is explicitly `.unmuted`: tapping the
/// output must never silence the speakers the user is listening through.
///
/// Two things learned the hard way and encoded here:
///
/// * The HAL calls block until TCC answers, and TCC cannot answer without a
///   run loop free to present the question. Never start this from the main
///   thread during launch.
/// * The IOProc runs on the real-time thread. Everything it needs is allocated
///   in `start()`; it must not allocate, lock, or log.
public final class SystemAudioTap: @unchecked Sendable {
    public enum TapError: Error, Sendable, Equatable {
        case processObjectUnavailable
        case tapCreationFailed(OSStatus)
        case tapFormatUnavailable
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)
        case converterUnavailable
    }

    public let buffer: AudioRingBuffer

    private let targetFormat: AVAudioFormat
    private let lock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var scratch: AVAudioPCMBuffer?
    private var sourceFormat: AVAudioFormat?
    private var running = false
    /// Buffers the IOProc has delivered. A tap that is silent and a tap that
    /// never fires look identical from the ring, and they have different causes.
    private let delivered = Atomic<Int>(0)

    public init(sampleRate: Double = 16_000, historySeconds: Double = 30) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw TapError.converterUnavailable }
        self.targetFormat = format
        self.buffer = AudioRingBuffer(seconds: historySeconds, sampleRate: sampleRate)
    }

    deinit { stop() }

    // MARK: - Lifecycle

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        guard let ourProcess = Self.processObject(for: getpid()) else {
            throw TapError.processObjectUnavailable
        }

        // The purpose-made initialiser, not a bare init with the flags set by
        // hand: that one leaves UUID and deviceUID unset, and the tap it
        // produces is accepted, started, and silent.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [ourProcess])
        description.name = "SpeechLocal meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted // never silence the user's own speakers

        var tap = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tap)
        guard created == noErr, tap != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(created)
        }
        tapID = tap

        guard let uid = Self.uid(of: tap), let source = Self.format(of: tap) else {
            cleanUp()
            throw TapError.tapFormatUnavailable
        }
        sourceFormat = source

        // Anchored to the device the audio is coming out of, which supplies the
        // aggregate's clock.
        //
        // Honest history: this was added while chasing a tap that delivered
        // zero buffers, on a theory that turned out to be wrong. The real cause
        // was that nothing capturable was playing — with the output device
        // idle there is no IO cycle to deliver anything, which is correct
        // behaviour and not a fault. The audio-source spike captures fine with
        // an empty sub-device list, so this anchoring is not required; it is
        // kept because it is what was measured working end to end, and
        // removing it would put unverified code back in the capture path.
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var subDevices: [[String: Any]] = []
        var spec: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpeechLocal meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uid,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let output = Self.defaultOutputUID() {
            subDevices = [[
                kAudioSubDeviceUIDKey: output,
                kAudioSubDeviceDriftCompensationKey: true,
            ]]
            spec[kAudioAggregateDeviceMainSubDeviceKey] = output
            spec[kAudioAggregateDeviceClockDeviceKey] = output
        }
        spec[kAudioAggregateDeviceSubDeviceListKey] = subDevices
        let aggregateDescription = spec
        let madeDevice = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregate)
        guard madeDevice == noErr, aggregate != kAudioObjectUnknown else {
            cleanUp()
            throw TapError.aggregateCreationFailed(madeDevice)
        }
        aggregateID = aggregate

        guard let converter = AVAudioConverter(from: source, to: targetFormat),
              let scratch = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(targetFormat.sampleRate))
        else {
            cleanUp()
            throw TapError.converterUnavailable
        }
        self.converter = converter
        self.scratch = scratch

        var proc: AudioDeviceIOProcID?
        let installed = AudioDeviceCreateIOProcIDWithBlock(
            &proc, aggregate, nil
        ) { [weak self] _, input, _, _, _ in
            self?.ingest(input)
        }
        guard installed == noErr, let proc else {
            cleanUp()
            throw TapError.ioProcFailed(installed)
        }
        procID = proc

        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else {
            cleanUp()
            throw TapError.startFailed(started)
        }
        running = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running || tapID != kAudioObjectUnknown else { return }
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        cleanUp()
        running = false
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// How many buffers the system has handed us since `start()`.
    public var deliveredBuffers: Int { delivered.load(ordering: .relaxed) }

    /// What the tap is actually attached to. A tap that starts cleanly and
    /// delivers nothing gives no other way to tell whether it is pointed at the
    /// device the audio is coming out of.
    public var diagnostics: String {
        lock.lock(); defer { lock.unlock() }
        var parts: [String] = []
        parts.append("tap=\(tapID)")
        parts.append("aggregate=\(aggregateID)")
        parts.append("tapFormat=\(sourceFormat.map { "\(Int($0.sampleRate))Hz x\($0.channelCount)" } ?? "none")")
        parts.append("defaultOutput=\(Self.defaultOutputDescription())")
        parts.append("aggregateInputChannels=\(Self.inputChannels(of: aggregateID))")
        return parts.joined(separator: "  ")
    }

    /// UID of the device the audio is coming out of, which the aggregate
    /// borrows as its clock.
    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, $0)
        }
        return result == noErr ? uid as String : nil
    }

    /// The device the user is actually listening through.
    private static func defaultOutputDescription() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return "unknown" }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let named = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, $0)
        }
        return named == noErr ? "\(device) \"\(name as String)\"" : "\(device)"
    }

    /// Input channels the aggregate actually exposes. Zero means the tap never
    /// made it into the device, whatever the creation call returned.
    private static func inputChannels(of device: AudioObjectID) -> Int {
        guard device != kAudioObjectUnknown else { return -1 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return -1 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr
        else { return -1 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Caller already holds the lock.
    private func cleanUp() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
        scratch = nil
        sourceFormat = nil
    }

    // MARK: - Real-time path

    /// Converts to 16 kHz mono and appends to the ring. Audio thread: no
    /// allocation, no locking, no logging.
    private func ingest(_ input: UnsafePointer<AudioBufferList>) {
        delivered.add(1, ordering: .relaxed)
        guard let converter, let scratch, let sourceFormat,
              let pcm = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                bufferListNoCopy: input,
                deallocator: nil),
              pcm.frameLength > 0
        else { return }

        scratch.frameLength = 0
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: scratch, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return pcm
        }

        guard status == .haveData || status == .inputRanDry,
              let channel = scratch.floatChannelData?[0],
              scratch.frameLength > 0
        else { return }

        buffer.write(UnsafeBufferPointer(start: channel, count: Int(scratch.frameLength)))
    }

    // MARK: - HAL lookups

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return result == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func uid(of tap: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, $0)
        }
        return result == noErr ? uid as String : nil
    }

    /// The tap's own format — read rather than assumed, because it follows the
    /// output device and is 48 kHz on this machine but need not be anywhere else.
    private static func format(of tap: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let result = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description)
        guard result == noErr, description.mSampleRate > 0 else { return nil }
        return AVAudioFormat(streamDescription: &description)
    }
}
