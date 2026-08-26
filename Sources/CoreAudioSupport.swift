import CoreAudio
import Darwin
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        "\(operation): \(fourCharacterCode(status)) (\(status))"
    }
}

func fourCharacterCode(_ status: OSStatus) -> String {
    let raw = UInt32(bitPattern: status)
    let bytes = [
        UInt8((raw >> 24) & 0xff),
        UInt8((raw >> 16) & 0xff),
        UInt8((raw >> 8) & 0xff),
        UInt8(raw & 0xff),
    ]
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
        return String(status)
    }
    return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func readUInt32(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> UInt32 {
    var address = propertyAddress(selector, scope: scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
        objectID, &address, 0, nil, &size, &value
    )
    guard status == noErr else {
        throw CoreAudioError(operation: "Read property \(fourCharacterCode(OSStatus(bitPattern: selector)))", status: status)
    }
    return value
}

func readString(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> String {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
        objectID, &address, 0, nil, &size, &value
    )
    guard status == noErr, let value else {
        throw CoreAudioError(operation: "Read string property", status: status)
    }
    return value.takeRetainedValue() as String
}

func readObjectIDs(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> [AudioObjectID] {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        objectID, &address, 0, nil, &size
    )
    guard status == noErr else {
        throw CoreAudioError(operation: "Read object-list size", status: status)
    }
    guard size > 0 else { return [] }

    var values = [AudioObjectID](
        repeating: kAudioObjectUnknown,
        count: Int(size) / MemoryLayout<AudioObjectID>.size
    )
    status = values.withUnsafeMutableBytes { bytes in
        AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, bytes.baseAddress!
        )
    }
    guard status == noErr else {
        throw CoreAudioError(operation: "Read object list", status: status)
    }
    return values
}

func defaultOutputDevice() throws -> AudioObjectID {
    let system = AudioObjectID(kAudioObjectSystemObject)
    return AudioObjectID(try readUInt32(
        objectID: system,
        selector: kAudioHardwarePropertyDefaultOutputDevice
    ))
}

func defaultInputDevice() throws -> AudioObjectID {
    let system = AudioObjectID(kAudioObjectSystemObject)
    return AudioObjectID(try readUInt32(
        objectID: system,
        selector: kAudioHardwarePropertyDefaultInputDevice
    ))
}

func setDefaultInputDevice(_ deviceID: AudioObjectID) throws {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    var mutableDeviceID = deviceID
    let size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectSetPropertyData(
        system, &address, 0, nil, size, &mutableDeviceID
    )
    guard status == noErr else {
        throw CoreAudioError(operation: "Set default input device", status: status)
    }
}

func audioProcessObject(for processID: pid_t) throws -> AudioObjectID {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var qualifier = processID
    var result = AudioObjectID(kAudioObjectUnknown)
    var resultSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
        AudioObjectGetPropertyData(
            system,
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            qualifierPointer,
            &resultSize,
            &result
        )
    }
    guard status == noErr else {
        throw CoreAudioError(operation: "Translate PID to Core Audio process", status: status)
    }
    guard result != kAudioObjectUnknown else {
        throw DuckingError.unavailable(
            "Codex Ducker could not exclude its own Core Audio process"
        )
    }
    return result
}

struct AudioStreamInfo: CustomStringConvertible {
    let id: AudioObjectID
    let isInput: Bool
    let format: AudioStreamBasicDescription
    let terminalType: UInt32?

    var description: String {
        let direction = isInput ? "input" : "output"
        let terminal = terminalType.map {
            " terminal=\(fourCharacterCode(OSStatus(bitPattern: $0)))"
        } ?? ""
        return "\(direction): \(Int(format.mChannelsPerFrame))ch "
            + "\(Int(format.mSampleRate))Hz "
            + "format=\(fourCharacterCode(OSStatus(bitPattern: format.mFormatID))) "
            + "flags=0x\(String(format.mFormatFlags, radix: 16)) "
            + "bytes/frame=\(format.mBytesPerFrame)\(terminal)"
    }
}

func audioStreams(deviceID: AudioObjectID) throws -> [AudioStreamInfo] {
    let streamIDs = try readObjectIDs(
        objectID: deviceID,
        selector: kAudioDevicePropertyStreams
    )
    return try streamIDs.map { streamID in
        let direction = try readUInt32(
            objectID: streamID,
            selector: kAudioStreamPropertyDirection
        )
        var address = propertyAddress(kAudioStreamPropertyVirtualFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            streamID, &address, 0, nil, &size, &format
        )
        guard status == noErr else {
            throw CoreAudioError(operation: "Read stream format", status: status)
        }
        let terminalType = try? readUInt32(
            objectID: streamID,
            selector: kAudioStreamPropertyTerminalType
        )
        return AudioStreamInfo(
            id: streamID,
            isInput: direction != 0,
            format: format,
            terminalType: terminalType
        )
    }
}

func validateLoopbackFormats(_ streams: [AudioStreamInfo]) throws -> Float64 {
    let inputs = streams.filter(\.isInput)
    let outputs = streams.filter { !$0.isInput }
    guard inputs.count == outputs.count, !inputs.isEmpty else {
        throw DuckingError.incompatibleStreams(
            "expected matching input/output streams, got \(inputs.count)/\(outputs.count)"
        )
    }

    for (input, output) in zip(inputs, outputs) {
        let lhs = input.format
        let rhs = output.format
        let formatsMatch = lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
        let isFloat32 = lhs.mFormatID == kAudioFormatLinearPCM
            && (lhs.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && lhs.mBitsPerChannel == 32
        guard formatsMatch && isFloat32 else {
            throw DuckingError.incompatibleStreams(
                "tap \(input) does not match device \(output) as Float32 PCM"
            )
        }
    }
    return inputs[0].format.mSampleRate
}

func waitForDeviceAlive(_ deviceID: AudioObjectID, timeout: TimeInterval = 1.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if (try? readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive
        )) == 1 {
            return true
        }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return false
}

func deviceHasMasterVolume(_ deviceID: AudioObjectID) -> Bool {
    var address = propertyAddress(
        kAudioDevicePropertyVolumeScalar,
        scope: kAudioDevicePropertyScopeOutput
    )
    return AudioObjectHasProperty(deviceID, &address)
}
