import CoreAudio
import Foundation

struct InputDeviceDescriptor: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
}

func preferredInputTarget(
    preferredUID: String?,
    devices: [InputDeviceDescriptor]
) -> InputDeviceDescriptor? {
    guard let preferredUID else { return nil }
    return devices.first { $0.uid == preferredUID }
}

func availableInputDevices() throws -> [InputDeviceDescriptor] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let deviceIDs = try readObjectIDs(
        objectID: system,
        selector: kAudioHardwarePropertyDevices
    )

    return deviceIDs.compactMap { deviceID in
        guard let streams = try? audioStreams(deviceID: deviceID),
              streams.contains(where: {
                  $0.isInput && $0.format.mChannelsPerFrame > 0
              }),
              let uid = try? readString(
                  objectID: deviceID,
                  selector: kAudioDevicePropertyDeviceUID
              ),
              let name = try? readString(
                  objectID: deviceID,
                  selector: kAudioObjectPropertyName
              ),
              let transportType = try? readUInt32(
                  objectID: deviceID,
                  selector: kAudioDevicePropertyTransportType
              ) else {
            return nil
        }
        return InputDeviceDescriptor(
            id: deviceID,
            uid: uid,
            name: name,
            transportType: transportType
        )
    }.sorted {
        let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
        if comparison == .orderedSame {
            return $0.uid < $1.uid
        }
        return comparison == .orderedAscending
    }
}

private struct InputPolicySnapshot: Equatable {
    let preferredUID: String?
    let preferredName: String?
    let currentInputID: AudioObjectID?
    let devices: [InputDeviceDescriptor]
}

final class PreferredInputPolicy {
    static let preferredUIDKey = "preferredInputDeviceUID"
    static let preferredNameKey = "preferredInputDeviceName"

    private let systemID = AudioObjectID(kAudioObjectSystemObject)
    private let defaults: UserDefaults
    private var devicesAddress = propertyAddress(kAudioHardwarePropertyDevices)
    private var defaultInputAddress = propertyAddress(
        kAudioHardwarePropertyDefaultInputDevice
    )
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var enforcementGeneration = 0
    private var stopped = false
    private var lastSnapshot: InputPolicySnapshot?

    private(set) var devices = [InputDeviceDescriptor]()
    private(set) var preferredUID: String?
    private(set) var preferredName: String?
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredUID = defaults.string(forKey: Self.preferredUIDKey)
        preferredName = defaults.string(forKey: Self.preferredNameKey)
        registerSystemListeners()
        scheduleEnforcement()
    }

    deinit {
        shutdown()
    }

    func selectPreferredInput(_ device: InputDeviceDescriptor?) {
        preferredUID = device?.uid
        preferredName = device?.name
        if let device {
            defaults.set(device.uid, forKey: Self.preferredUIDKey)
            defaults.set(device.name, forKey: Self.preferredNameKey)
            duckerLog("preferred microphone selected: \(device.name), uid=\(device.uid)")
        } else {
            defaults.removeObject(forKey: Self.preferredUIDKey)
            defaults.removeObject(forKey: Self.preferredNameKey)
            duckerLog("preferred microphone disabled; following macOS")
        }
        scheduleEnforcement()
    }

    func displayName(for device: InputDeviceDescriptor) -> String {
        let duplicateCount = devices.filter { $0.name == device.name }.count
        guard duplicateCount > 1 else { return device.name }
        return "\(device.name) (\(transportName(device.transportType)))"
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        enforcementGeneration += 1
        guard let listener = systemListener else { return }
        for addressKeyPath in [\PreferredInputPolicy.devicesAddress,
                               \PreferredInputPolicy.defaultInputAddress] {
            var address = self[keyPath: addressKeyPath]
            AudioObjectRemovePropertyListenerBlock(
                systemID, &address, DispatchQueue.main, listener
            )
        }
        systemListener = nil
    }

    private func registerSystemListeners() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleEnforcement()
        }
        for addressKeyPath in [\PreferredInputPolicy.devicesAddress,
                               \PreferredInputPolicy.defaultInputAddress] {
            var address = self[keyPath: addressKeyPath]
            let status = AudioObjectAddPropertyListenerBlock(
                systemID, &address, DispatchQueue.main, listener
            )
            if status != noErr {
                duckerLog(
                    "preferred-input listener failed: \(fourCharacterCode(status))"
                )
            }
        }
        systemListener = listener
    }

    private func scheduleEnforcement() {
        guard !stopped else { return }
        enforcementGeneration += 1
        let generation = enforcementGeneration

        // Bluetooth and USB devices may publish several Core Audio changes while
        // reconnecting. Re-check after the initial event so the preference wins
        // even when macOS changes the default late in that sequence.
        for delay in [0.0, 0.25, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped,
                      self.enforcementGeneration == generation else { return }
                self.enforceNow()
            }
        }
    }

    private func enforceNow() {
        do {
            devices = try availableInputDevices()
            if let target = preferredInputTarget(
                preferredUID: preferredUID,
                devices: devices
            ) {
                let currentID = try defaultInputDevice()
                if currentID != target.id {
                    try setDefaultInputDevice(target.id)
                    duckerLog(
                        "restored preferred microphone: \(target.name), uid=\(target.uid)"
                    )
                }
            }
            publishIfChanged()
        } catch {
            duckerLog("preferred-input policy failed: \(error)")
            publishIfChanged()
        }
    }

    private func publishIfChanged() {
        let snapshot = InputPolicySnapshot(
            preferredUID: preferredUID,
            preferredName: preferredName,
            currentInputID: try? defaultInputDevice(),
            devices: devices
        )
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onChange?()
    }
}

private func transportName(_ transportType: UInt32) -> String {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn:
        return "Built-in"
    case kAudioDeviceTransportTypeUSB:
        return "USB"
    case kAudioDeviceTransportTypeBluetooth,
         kAudioDeviceTransportTypeBluetoothLE:
        return "Bluetooth"
    case kAudioDeviceTransportTypeDisplayPort:
        return "DisplayPort"
    case kAudioDeviceTransportTypeHDMI:
        return "HDMI"
    default:
        return "Other"
    }
}

func runPreferredInputPolicySelfTest() throws {
    let rode = InputDeviceDescriptor(
        id: 10,
        uid: "usb-rode",
        name: "Studio microphone",
        transportType: kAudioDeviceTransportTypeUSB
    )
    let headset = InputDeviceDescriptor(
        id: 20,
        uid: "bluetooth-headset",
        name: "Headset",
        transportType: kAudioDeviceTransportTypeBluetooth
    )
    let devices = [headset, rode]

    guard preferredInputTarget(
        preferredUID: rode.uid,
        devices: devices
    ) == rode else {
        throw DuckingError.unavailable("Preferred input was not selected")
    }
    guard preferredInputTarget(
        preferredUID: "disconnected-device",
        devices: devices
    ) == nil else {
        throw DuckingError.unavailable("Unavailable preferred input did not fall back")
    }
    guard preferredInputTarget(
        preferredUID: nil,
        devices: devices
    ) == nil else {
        throw DuckingError.unavailable("Follow-macOS input policy selected a device")
    }
}
