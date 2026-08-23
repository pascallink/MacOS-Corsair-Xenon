// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// System output volume for the dashboard's volume widget (CoreAudio).

import AudioToolbox
import CoreAudio
import Foundation

public enum SystemVolume {
    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Current output volume, 0...1. Nil when the device has no volume control.
    public static func get() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    @discardableResult
    public static func set(_ value: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var volume = Float32(min(max(value, 0), 1))
        var address = volumeAddress
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &volume) == noErr
    }

    public static func isMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = muteAddress
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
            return false
        }
        return muted != 0
    }

    @discardableResult
    public static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var value = UInt32(muted ? 1 : 0)
        var address = muteAddress
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
