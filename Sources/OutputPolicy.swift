import CoreAudio

struct OutputDeviceFacts {
    let name: String
    let transportType: UInt32
    let terminalTypes: Set<UInt32>
    let hasMatchingInputDevice: Bool
}

func headphoneBypassReason(for facts: OutputDeviceFacts) -> String? {
    if facts.terminalTypes.contains(kAudioStreamTerminalTypeHeadphones) {
        return "headphone terminal"
    }

    let normalizedName = facts.name.lowercased()
    if ["wh-1000xm", "wf-1000xm", "airpods"].contains(where: normalizedName.contains) {
        return "known headset"
    }

    let isBluetooth = facts.transportType == kAudioDeviceTransportTypeBluetooth
        || facts.transportType == kAudioDeviceTransportTypeBluetoothLE
    if isBluetooth && facts.hasMatchingInputDevice {
        return "Bluetooth headset with microphone"
    }
    return nil
}

func outputDeviceFacts(deviceID: AudioObjectID, name: String) throws -> OutputDeviceFacts {
    let transport = try readUInt32(
        objectID: deviceID,
        selector: kAudioDevicePropertyTransportType
    )
    let terminalTypes = Set(try audioStreams(deviceID: deviceID)
        .filter { !$0.isInput }
        .compactMap(\.terminalType))

    let allDeviceIDs = try readObjectIDs(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDevices
    )
    let hasMatchingInput = allDeviceIDs.contains { candidateID in
        guard let candidateName = try? readString(
            objectID: candidateID,
            selector: kAudioObjectPropertyName
        ), candidateName == name,
        let streams = try? audioStreams(deviceID: candidateID) else {
            return false
        }
        return streams.contains { $0.isInput && $0.format.mChannelsPerFrame > 0 }
    }
    return OutputDeviceFacts(
        name: name,
        transportType: transport,
        terminalTypes: terminalTypes,
        hasMatchingInputDevice: hasMatchingInput
    )
}

func runOutputPolicySelfTest() throws {
    let cases: [(facts: OutputDeviceFacts, shouldBypass: Bool)] = [
        (OutputDeviceFacts(
            name: "WH-1000XM6",
            transportType: kAudioDeviceTransportTypeBluetooth,
            terminalTypes: [],
            hasMatchingInputDevice: true
        ), true),
        (OutputDeviceFacts(
            name: "USB Headphones",
            transportType: kAudioDeviceTransportTypeUSB,
            terminalTypes: [kAudioStreamTerminalTypeHeadphones],
            hasMatchingInputDevice: false
        ), true),
        (OutputDeviceFacts(
            name: "DELL S2725QC",
            transportType: kAudioDeviceTransportTypeDisplayPort,
            terminalTypes: [kAudioStreamTerminalTypeDisplayPort],
            hasMatchingInputDevice: false
        ), false),
        (OutputDeviceFacts(
            name: "MacBook Pro Speakers",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            terminalTypes: [kAudioStreamTerminalTypeSpeaker],
            hasMatchingInputDevice: false
        ), false),
    ]

    for testCase in cases {
        let actuallyBypasses = headphoneBypassReason(for: testCase.facts) != nil
        guard actuallyBypasses == testCase.shouldBypass else {
            throw DuckingError.unavailable("Output policy failed for \(testCase.facts.name)")
        }
    }
}
