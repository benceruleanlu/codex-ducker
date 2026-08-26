import CoreAudio
import Foundation

enum DuckingError: Error, CustomStringConvertible {
    case unavailable(String)
    case incompatibleStreams(String)

    var description: String {
        switch self {
        case .unavailable(let reason): return reason
        case .incompatibleStreams(let reason): return "Incompatible audio streams: \(reason)"
        }
    }
}

enum DuckerState: Equatable {
    case preparing
    case ready(outputName: String)
    case bypassed(outputName: String, reason: String)
    case warming(outputName: String)
    case ducking(outputName: String)
    case disabled
    case error(String)

    var menuText: String {
        switch self {
        case .preparing: return "Preparing audio path…"
        case .ready(let output): return "Ready — \(output)"
        case .bypassed(let output, let reason): return "Bypassed — \(output) (\(reason))"
        case .warming(let output): return "Listening safely — \(output)"
        case .ducking(let output): return "Ducking — \(output)"
        case .disabled: return "Disabled"
        case .error(let message): return "Needs attention — \(message)"
        }
    }
}

final class DuckingEngine {
    var onStateChange: ((DuckerState) -> Void)?
    private(set) var state: DuckerState = .preparing {
        didSet {
            guard state != oldValue else { return }
            duckerLog(state.menuText)
            onStateChange?(state)
        }
    }

    var enabled: Bool {
        didSet {
            if enabled {
                refreshInputDeviceListener()
                preparePipelineIfNeeded()
                if monitorsDevices {
                    evaluateTrigger()
                }
            } else {
                forcedTestActive = false
                stopDucking(immediate: false)
                state = .disabled
            }
        }
    }

    var duckGain: Float {
        didSet {
            duckGain = min(max(duckGain, 0.0), 1.0)
            if ioRunning, let dspState {
                DuckerDSPSetTarget(dspState, duckGain, rampFrames)
            }
        }
    }

    private let systemID = AudioObjectID(kAudioObjectSystemObject)
    private let monitorsDevices: Bool
    private var inputAddress = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    private var outputAddress = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    private var inputRunningAddress = propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private var outputRunningAddress = propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var inputDeviceListener: AudioObjectPropertyListenerBlock?
    private var outputRunningListener: AudioObjectPropertyListenerBlock?

    private var inputID = AudioObjectID(kAudioObjectUnknown)
    private var inputName = "Unknown microphone"
    private var lastMicrophoneState = false

    private var outputID = AudioObjectID(kAudioObjectUnknown)
    private var outputName = "Unknown output"
    private var outputBypassReason: String?
    private var excludedProcessID = AudioObjectID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapDescription: CATapDescription?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var dspState: OpaquePointer?
    private var sampleRate: Float64 = 48_000
    private var ioRunning = false
    private var audioCopyEngaged = false
    private var stopWorkItem: DispatchWorkItem?
    private var testWorkItem: DispatchWorkItem?
    private var warmupWorkItem: DispatchWorkItem?
    private var warmupAttempts = 0
    private var warmupStarted = Date()
    private var forcedTestActive = false

    private var rampFrames: UInt32 {
        UInt32(max(1, sampleRate * 0.025))
    }

    init(enabled: Bool, duckGain: Float, monitorsDevices: Bool = true) {
        self.enabled = enabled
        self.duckGain = min(max(duckGain, 0.0), 1.0)
        self.monitorsDevices = monitorsDevices
        self.dspState = DuckerDSPCreate()
        if monitorsDevices {
            registerSystemListeners()
        }
        refreshInputDeviceListener()
        if enabled {
            preparePipelineIfNeeded()
            if monitorsDevices {
                evaluateTrigger()
            }
        } else {
            state = .disabled
        }
    }

    deinit {
        shutdown()
        if let dspState {
            DuckerDSPDestroy(dspState)
        }
    }

    private func registerSystemListeners() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self else { return }
            for index in 0..<Int(count) {
                switch addresses[index].mSelector {
                case kAudioHardwarePropertyDefaultInputDevice:
                    self.refreshInputDeviceListener()
                    self.evaluateTrigger()
                case kAudioHardwarePropertyDefaultOutputDevice:
                    self.outputDeviceChanged()
                default:
                    break
                }
            }
        }
        for addressKeyPath in [\DuckingEngine.inputAddress,
                               \DuckingEngine.outputAddress] {
            var address = self[keyPath: addressKeyPath]
            let status = AudioObjectAddPropertyListenerBlock(
                systemID, &address, DispatchQueue.main, listener
            )
            if status != noErr {
                duckerLog("system listener failed: \(fourCharacterCode(status))")
            }
        }
        systemListener = listener
    }

    private func unregisterSystemListeners() {
        guard let listener = systemListener else { return }
        for addressKeyPath in [\DuckingEngine.inputAddress,
                               \DuckingEngine.outputAddress] {
            var address = self[keyPath: addressKeyPath]
            AudioObjectRemovePropertyListenerBlock(
                systemID, &address, DispatchQueue.main, listener
            )
        }
        systemListener = nil
    }

    private func refreshInputDeviceListener() {
        if inputID != kAudioObjectUnknown, let listener = inputDeviceListener {
            var address = inputRunningAddress
            AudioObjectRemovePropertyListenerBlock(
                inputID, &address, DispatchQueue.main, listener
            )
        }
        inputDeviceListener = nil

        do {
            inputID = AudioObjectID(try readUInt32(
                objectID: systemID,
                selector: kAudioHardwarePropertyDefaultInputDevice
            ))
            inputName = (try? readString(
                objectID: inputID,
                selector: kAudioObjectPropertyName
            )) ?? "Current microphone"
            if monitorsDevices {
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.evaluateTrigger()
                }
                var address = inputRunningAddress
                let status = AudioObjectAddPropertyListenerBlock(
                    inputID, &address, DispatchQueue.main, listener
                )
                guard status == noErr else {
                    throw CoreAudioError(operation: "Listen to microphone state", status: status)
                }
                inputDeviceListener = listener
            }
            let action = monitorsDevices ? "watching" : "inspecting"
            duckerLog("\(action) microphone: \(inputName), object=\(inputID)")
        } catch {
            inputID = kAudioObjectUnknown
            state = .error("Cannot watch the default microphone: \(error)")
        }
    }

    private var microphoneIsRunning: Bool {
        guard inputID != kAudioObjectUnknown else { return false }
        return (try? readUInt32(
            objectID: inputID,
            selector: kAudioDevicePropertyDeviceIsRunningSomewhere
        )) == 1
    }

    private func activeInputProcesses() -> [String] {
        guard let processIDs = try? readObjectIDs(
            objectID: systemID,
            selector: kAudioHardwarePropertyProcessObjectList
        ) else { return [] }

        return processIDs.compactMap { id in
            guard (try? readUInt32(
                objectID: id,
                selector: kAudioProcessPropertyIsRunningInput
            )) == 1 else { return nil }
            let bundle = (try? readString(
                objectID: id,
                selector: kAudioProcessPropertyBundleID
            )) ?? "unknown"
            let pid = (try? readUInt32(
                objectID: id,
                selector: kAudioProcessPropertyPID
            )) ?? 0
            return "\(bundle.isEmpty ? "unbundled" : bundle)(pid=\(pid), object=\(id))"
        }
    }

    private func evaluateTrigger() {
        guard enabled else { return }
        let microphoneRunning = microphoneIsRunning
        if microphoneRunning != lastMicrophoneState {
            lastMicrophoneState = microphoneRunning
            let owners = activeInputProcesses()
            duckerLog("microphone running=\(microphoneRunning), owners=\(owners.isEmpty ? "none reported" : owners.joined(separator: ", "))")
        }
        if microphoneRunning || forcedTestActive {
            startDucking()
        } else {
            stopDucking(immediate: false)
        }
    }

    private func outputDeviceChanged() {
        let shouldResume = enabled && (microphoneIsRunning || forcedTestActive)
        duckerLog("default output changed; rebuilding private audio path")
        stopDucking(immediate: true)
        teardownPipeline()
        preparePipelineIfNeeded()
        if shouldResume {
            startDucking()
        }
    }

    func preparePipelineIfNeeded() {
        guard enabled,
              aggregateID == kAudioObjectUnknown,
              outputBypassReason == nil else { return }
        state = .preparing
        do {
            try buildPipeline()
            if let outputBypassReason {
                state = .bypassed(
                    outputName: outputName,
                    reason: outputBypassReason
                )
            } else {
                state = .ready(outputName: outputName)
            }
        } catch {
            teardownPipeline()
            state = .error(String(describing: error))
        }
    }

    private func buildPipeline() throws {
        guard let dspState else {
            throw DuckingError.unavailable("Could not allocate the audio processor")
        }

        outputID = try defaultOutputDevice()
        guard outputID != kAudioObjectUnknown else {
            throw DuckingError.unavailable("No default output device")
        }
        outputName = (try? readString(
            objectID: outputID,
            selector: kAudioObjectPropertyName
        )) ?? "Current output"
        let outputFacts = try outputDeviceFacts(
            deviceID: outputID,
            name: outputName
        )
        if let reason = headphoneBypassReason(for: outputFacts) {
            outputBypassReason = reason
            duckerLog(
                "bypassing ducking for output=\(outputName), reason=\(reason), "
                + "transport=\(fourCharacterCode(OSStatus(bitPattern: outputFacts.transportType))), "
                + "terminals=\(outputFacts.terminalTypes.map { fourCharacterCode(OSStatus(bitPattern: $0)) }.joined(separator: ","))"
            )
            return
        }
        let outputUID = try readString(
            objectID: outputID,
            selector: kAudioDevicePropertyDeviceUID
        )
        excludedProcessID = try audioProcessObject(for: getpid())

        let description = CATapDescription()
        description.name = "Ducker system-audio tap"
        description.processes = [excludedProcessID]
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isMixdown = true
        description.isMono = false
        description.isExclusive = true
        description.deviceUID = outputUID
        description.stream = 0
        if #available(macOS 26.0, *) {
            description.bundleIDs = [Bundle.main.bundleIdentifier ?? "com.benluwu.Ducker"]
            description.isProcessRestoreEnabled = true
        }

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw CoreAudioError(operation: "Create system-audio tap", status: status)
        }
        tapID = newTapID
        tapDescription = description
        let tapUID = try readString(
            objectID: tapID,
            selector: kAudioTapPropertyUID
        )

        let aggregateUID = "com.benluwu.Ducker.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ducker Private Audio Path",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: outputUID,
                kAudioSubDeviceDriftCompensationKey: false,
            ]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: false,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: false,
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            throw CoreAudioError(operation: "Create private aggregate device", status: status)
        }
        aggregateID = newAggregateID
        guard waitForDeviceAlive(aggregateID) else {
            throw DuckingError.unavailable("Private audio path did not become ready")
        }

        let streams = try audioStreams(deviceID: aggregateID)
        sampleRate = try validateLoopbackFormats(streams)

        var newIOProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(
            aggregateID,
            DuckerAudioIOProc,
            UnsafeMutableRawPointer(dspState),
            &newIOProcID
        )
        guard status == noErr, newIOProcID != nil else {
            throw CoreAudioError(operation: "Create realtime ducking processor", status: status)
        }
        ioProcID = newIOProcID
        registerOutputRunningListener()
        duckerLog(
            "pipeline ready: input=\(inputName), output=\(outputName), "
            + "sampleRate=\(Int(sampleRate)), excludedSelfObject=\(excludedProcessID)"
        )
    }

    private var outputIsPlaying: Bool {
        guard outputID != kAudioObjectUnknown else { return false }
        return (try? readUInt32(
            objectID: outputID,
            selector: kAudioDevicePropertyDeviceIsRunningSomewhere
        )) == 1
    }

    private func registerOutputRunningListener() {
        guard monitorsDevices, outputID != kAudioObjectUnknown else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.evaluateTrigger()
        }
        var address = outputRunningAddress
        let status = AudioObjectAddPropertyListenerBlock(
            outputID, &address, DispatchQueue.main, listener
        )
        guard status == noErr else {
            duckerLog("output playback listener failed: \(fourCharacterCode(status))")
            return
        }
        outputRunningListener = listener
    }

    private func unregisterOutputRunningListener() {
        if let listener = outputRunningListener, outputID != kAudioObjectUnknown {
            var address = outputRunningAddress
            AudioObjectRemovePropertyListenerBlock(
                outputID, &address, DispatchQueue.main, listener
            )
        }
        outputRunningListener = nil
    }

    private func setTapMuteBehavior(_ behavior: CATapMuteBehavior) throws {
        guard tapID != kAudioObjectUnknown, var description = tapDescription else {
            throw DuckingError.unavailable("System-audio tap is unavailable")
        }
        description.muteBehavior = behavior
        var address = propertyAddress(kAudioTapPropertyDescription)
        let size = UInt32(MemoryLayout<CATapDescription>.stride)
        let status = withUnsafeMutablePointer(to: &description) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, size, pointer)
        }
        guard status == noErr else {
            throw CoreAudioError(operation: "Change tap mute behavior", status: status)
        }
        tapDescription = description
    }

    private func startDucking() {
        stopWorkItem?.cancel()
        stopWorkItem = nil

        if ioRunning {
            if let dspState {
                DuckerDSPSetTarget(dspState, duckGain, rampFrames)
            }
            return
        }

        preparePipelineIfNeeded()
        guard aggregateID != kAudioObjectUnknown,
              let ioProcID,
              let dspState else { return }

        guard shouldOpenAudioPath(
            observingPlayback: outputRunningListener != nil,
            outputIsPlaying: outputIsPlaying
        ) else {
            state = .ready(outputName: outputName)
            return
        }

        do {
            try setTapMuteBehavior(.unmuted)
        } catch {
            state = .error(String(describing: error))
            return
        }
        DuckerDSPSetCopyEnabled(dspState, 0)
        DuckerDSPResetTelemetry(dspState)
        DuckerDSPReset(dspState, 1.0, duckGain, rampFrames)
        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            state = .error(
                "System Audio Recording permission or audio start failed: \(fourCharacterCode(status))"
            )
            return
        }
        ioRunning = true
        audioCopyEngaged = false
        warmupAttempts = 0
        warmupStarted = Date()
        state = .warming(outputName: outputName)
        scheduleWarmupCheck()
    }

    private var warmupInterval: TimeInterval {
        let elapsed = Date().timeIntervalSince(warmupStarted)
        if elapsed < 0.5 { return 0.05 }
        if elapsed < 3.0 { return 0.25 }
        return 1.0
    }

    private func scheduleWarmupCheck() {
        warmupWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.checkWarmup()
        }
        warmupWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + warmupInterval, execute: workItem
        )
    }

    private func checkWarmup() {
        guard ioRunning, !audioCopyEngaged, let dspState else { return }
        warmupAttempts += 1
        let snapshot = DuckerDSPGetSnapshot(dspState)
        if snapshot.nonZeroInputSampleCount > 0 {
            do {
                DuckerDSPSetCopyEnabled(dspState, 1)
                try setTapMuteBehavior(.mutedWhenTapped)
                audioCopyEngaged = true
                state = .ducking(outputName: outputName)
                duckerLog(
                    "tap proven and engaged: callbacks=\(snapshot.callbackCount), "
                    + "samples=\(snapshot.inputSampleCount), nonzero=\(snapshot.nonZeroInputSampleCount), "
                    + "buffers=\(snapshot.inputBufferCount)/\(snapshot.outputBufferCount), "
                    + "bytes=\(snapshot.inputByteCount)/\(snapshot.outputByteCount)"
                )
            } catch {
                DuckerDSPSetCopyEnabled(dspState, 0)
                state = .error("Kept original audio because ducking could not engage: \(error)")
                stopDucking(immediate: true, preserveState: true)
            }
            return
        }

        if warmupAttempts == 1 {
            duckerLog(
                "tap warmup: callbacks=\(snapshot.callbackCount), "
                + "samples=\(snapshot.inputSampleCount), nonzero=0, "
                + "buffers=\(snapshot.inputBufferCount)/\(snapshot.outputBufferCount), "
                + "bytes=\(snapshot.inputByteCount)/\(snapshot.outputByteCount)"
            )
        }
        if forcedTestActive, Date().timeIntervalSince(warmupStarted) >= 2.5 {
            forcedTestActive = false
            testWorkItem?.cancel()
            testWorkItem = nil
            state = .error("Test received no system-audio samples; original audio was left untouched")
            stopDucking(immediate: true, preserveState: true)
            return
        }
        scheduleWarmupCheck()
    }

    private func stopDucking(immediate: Bool, preserveState: Bool = false) {
        guard ioRunning, let dspState else {
            if !preserveState, enabled, aggregateID != kAudioObjectUnknown {
                state = .ready(outputName: outputName)
            }
            return
        }

        warmupWorkItem?.cancel()
        warmupWorkItem = nil
        stopWorkItem?.cancel()
        if immediate || !audioCopyEngaged {
            performStop(preserveState: preserveState)
            return
        }

        DuckerDSPSetTarget(dspState, 1.0, rampFrames)
        let workItem = DispatchWorkItem { [weak self] in
            self?.performStop(preserveState: preserveState)
        }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func performStop(preserveState: Bool = false) {
        stopWorkItem = nil
        guard ioRunning, let ioProcID, let dspState else { return }
        do {
            try setTapMuteBehavior(.unmuted)
        } catch {
            duckerLog("warning: could not return tap to unmuted before stop: \(error)")
        }
        DuckerDSPSetCopyEnabled(dspState, 0)
        AudioDeviceStop(aggregateID, ioProcID)
        ioRunning = false
        audioCopyEngaged = false
        if !preserveState {
            state = enabled ? .ready(outputName: outputName) : .disabled
        }
    }

    func runTest(duration: TimeInterval = 3.0) {
        guard enabled, !microphoneIsRunning else { return }
        testWorkItem?.cancel()
        forcedTestActive = true
        startDucking()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.forcedTestActive = false
            self.evaluateTrigger()
        }
        testWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func pipelineDiagnosticReport() -> String {
        preparePipelineIfNeeded()
        let outputVolume = outputID == kAudioObjectUnknown
            ? "unknown"
            : (deviceHasMasterVolume(outputID) ? "controllable" : "fixed")
        var lines = [
            "state: \(state.menuText)",
            "microphone: \(inputName) (running=\(microphoneIsRunning))",
            "active input processes: \(activeInputProcesses().joined(separator: ", "))",
            "output: \(outputName) (\(outputVolume) volume)",
            "output bypass: \(outputBypassReason ?? "none")",
            "self process excluded from tap: \(excludedProcessID)",
        ]
        if aggregateID != kAudioObjectUnknown {
            lines.append("private pipeline: ready at \(Int(sampleRate)) Hz, fail-open warmup enabled")
            if let streams = try? audioStreams(deviceID: aggregateID) {
                lines.append(contentsOf: streams.map { "  \($0)" })
            }
        }
        return lines.joined(separator: "\n")
    }

    private func teardownPipeline() {
        warmupWorkItem?.cancel()
        warmupWorkItem = nil
        stopWorkItem?.cancel()
        stopWorkItem = nil
        if ioRunning {
            performStop(preserveState: true)
        }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        tapDescription = nil
        outputBypassReason = nil
        excludedProcessID = kAudioObjectUnknown
        unregisterOutputRunningListener()
        outputID = kAudioObjectUnknown
    }

    func shutdown() {
        testWorkItem?.cancel()
        testWorkItem = nil
        forcedTestActive = false
        if inputID != kAudioObjectUnknown, let listener = inputDeviceListener {
            var address = inputRunningAddress
            AudioObjectRemovePropertyListenerBlock(
                inputID, &address, DispatchQueue.main, listener
            )
        }
        inputDeviceListener = nil
        unregisterSystemListeners()
        stopDucking(immediate: true)
        teardownPipeline()
    }
}
