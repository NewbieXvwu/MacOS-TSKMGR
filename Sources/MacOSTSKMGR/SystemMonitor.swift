import SwiftUI
import Combine
import Foundation
import AppKit
import Darwin
import MachO
import IOKit
import IOKit.storage
import CoreFoundation
import CoreWLAN

@_silgen_name("CFRelease")
private func CFReleaseShim(_ cf: CFTypeRef?)

@_silgen_name("mach_task_self")
private func mach_task_self_() -> UInt32
@_silgen_name("IOServiceOpen")
private func IOServiceOpen_(_ service: io_service_t, _ owningTask: UInt32, _ type: UInt32, _ connect: UnsafeMutablePointer<UInt32>) -> kern_return_t
@_silgen_name("IOServiceClose")
private func IOServiceClose_(_ connect: UInt32) -> kern_return_t
@_silgen_name("IOConnectCallStructMethod")
private func IOConnectCallStructMethod_(_ conn: UInt32, _ selector: UInt32, _ input: UnsafeRawPointer, _ inputSize: Int, _ output: UnsafeMutableRawPointer, _ outputSize: UnsafeMutablePointer<Int>) -> kern_return_t
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: UnsafeMutableRawPointer, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: UnsafeRawPointer, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: UnsafeRawPointer, _ type: Int64, _ field: Int32, _ options: Int64) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: UnsafeMutableRawPointer, _ field: Int64) -> Double

private struct SMCKeyDataVer {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPowerLimit: UInt32 = 0
    var gpuPowerLimit: UInt32 = 0
    var memPowerLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding0: UInt8 = 0
    var padding1: UInt8 = 0
    var padding2: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVer()
    var versPadding: UInt16 = 0
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data8Padding: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private final class SMCReader {
    private let connection: UInt32
    private var keyInfoCache: [String: SMCKeyInfo] = [:]

    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var conn: UInt32 = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS else { continue }
            let serviceName = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if serviceName == "AppleSMCKeysEndpoint" {
                let kr = IOServiceOpen_(service, mach_task_self_(), 0, &conn)
                if kr == KERN_SUCCESS {
                    break
                }
            }
        }

        guard conn != 0 else { return nil }
        self.connection = conn
    }

    deinit {
        _ = IOServiceClose_(connection)
    }

    func readAllKeys() -> [String] {
        guard let count = keyCount(), count > 0 else { return [] }
        var result: [String] = []
        result.reserveCapacity(Int(count))
        for index in 0..<count {
            if let key = keyByIndex(index) {
                result.append(key)
            }
        }
        return result
    }

    func readFloatValue(for key: String) -> Double? {
        guard let (type, data) = readValue(for: key), type == "flt ", data.count >= 4 else { return nil }
        let bits = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        return Double(Float(bitPattern: UInt32(littleEndian: bits)))
    }

    func readNumericValue(for key: String) -> Double? {
        guard let (type, data) = readValue(for: key) else { return nil }
        switch type {
        case "flt ":
            guard data.count >= 4 else { return nil }
            let bits = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            return Double(Float(bitPattern: UInt32(littleEndian: bits)))
        case "fpe2":
            guard data.count >= 2 else { return nil }
            return Double((UInt16(data[0]) << 6) | (UInt16(data[1]) >> 2))
        case "ui8 ":
            return data.isEmpty ? nil : Double(data[0])
        case "ui16":
            guard data.count >= 2 else { return nil }
            return Double(UInt16(data[0]) << 8 | UInt16(data[1]))
        case "ui32":
            guard data.count >= 4 else { return nil }
            return Double(UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3]))
        default:
            return nil
        }
    }

    private func parseKey(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }

    private func fourCC(_ value: UInt32) -> String {
        let bigEndian = value.bigEndian
        return withUnsafeBytes(of: bigEndian) { String(bytes: $0, encoding: .utf8) ?? "" }
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = withUnsafePointer(to: &input) { ip in
            withUnsafeMutablePointer(to: &output) { op in
                IOConnectCallStructMethod_(connection, 2, ip, MemoryLayout<SMCKeyData>.stride, op, &outSize)
            }
        }
        guard kr == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private func keyInfo(for key: String) -> SMCKeyInfo? {
        if let cached = keyInfoCache[key] {
            return cached
        }
        var request = SMCKeyData()
        request.key = parseKey(key)
        request.data8 = 9
        guard let info = call(&request)?.keyInfo else { return nil }
        keyInfoCache[key] = info
        return info
    }

    private func readValue(for key: String) -> (String, [UInt8])? {
        guard let info = keyInfo(for: key) else { return nil }
        var request = SMCKeyData()
        request.key = parseKey(key)
        request.data8 = 5
        request.keyInfo = info
        guard let output = call(&request) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return (fourCC(info.dataType), bytes)
    }

    private func keyCount() -> UInt32? {
        guard let (_, data) = readValue(for: "#KEY"), data.count >= 4 else { return nil }
        return data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func keyByIndex(_ index: UInt32) -> String? {
        var request = SMCKeyData()
        request.data8 = 8
        request.data32 = index
        guard let output = call(&request) else { return nil }
        return fourCC(output.key)
    }
}

private enum IOReportRuntime {
    typealias CopyAllChannelsFn = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias CreateSubscriptionFn = @convention(c) (
        UnsafeRawPointer?,
        CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
        UInt64,
        UnsafeRawPointer?
    ) -> UnsafeRawPointer?
    typealias CreateSamplesFn = @convention(c) (UnsafeRawPointer, CFMutableDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDeltaFn = @convention(c) (CFDictionary, CFDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    typealias ChannelStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias SimpleIntegerFn = @convention(c) (CFDictionary, Int32) -> Int64

    private struct LibraryHandle: @unchecked Sendable {
        let raw: UnsafeMutableRawPointer?
    }

    private static let libraryHandle = LibraryHandle(
        raw: dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL)
    )

    private static func load<T>(_ symbol: String, as type: T.Type) -> T? {
        guard let raw = dlsym(libraryHandle.raw, symbol) else {
            return nil
        }
        return unsafeBitCast(raw, to: type)
    }

    static let copyAllChannels = load("IOReportCopyAllChannels", as: CopyAllChannelsFn.self)
    static let createSubscription = load("IOReportCreateSubscription", as: CreateSubscriptionFn.self)
    static let createSamples = load("IOReportCreateSamples", as: CreateSamplesFn.self)
    static let createSamplesDelta = load("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self)
    static let channelGetGroup = load("IOReportChannelGetGroup", as: ChannelStringFn.self)
    static let channelGetSubGroup = load("IOReportChannelGetSubGroup", as: ChannelStringFn.self)
    static let channelGetChannelName = load("IOReportChannelGetChannelName", as: ChannelStringFn.self)
    static let channelGetUnitLabel = load("IOReportChannelGetUnitLabel", as: ChannelStringFn.self)
    static let simpleGetIntegerValue = load("IOReportSimpleGetIntegerValue", as: SimpleIntegerFn.self)
    static let stateGetCount = load("IOReportStateGetCount", as: (@convention(c) (CFDictionary) -> Int32).self)
    static let stateGetNameForIndex = load("IOReportStateGetNameForIndex", as: (@convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?).self)
    static let stateGetResidency = load("IOReportStateGetResidency", as: (@convention(c) (CFDictionary, Int32) -> Int64).self)

    static var isAvailable: Bool {
        copyAllChannels != nil &&
        createSubscription != nil &&
        createSamples != nil &&
        createSamplesDelta != nil &&
        channelGetGroup != nil &&
        channelGetSubGroup != nil &&
        channelGetChannelName != nil &&
        channelGetUnitLabel != nil &&
        simpleGetIntegerValue != nil
    }
}

private struct ANEIOReportChannelMetadata {
    let group: String
    let subgroup: String
    let channel: String
    let unit: String
}

private struct ANEIOReportDeltaSample {
    let activeTimePercent: Double
    let watts: Double
    let dataReadBytesPerSecond: UInt64
    let dataWriteBytesPerSecond: UInt64
    let dataMovementBytesPerSecond: UInt64
    let durationMilliseconds: UInt64
}

private struct ANEIOReportMetrics {
    let activeTimePercent: Double
    let watts: Double
    let dataReadBytesPerSecond: UInt64
    let dataWriteBytesPerSecond: UInt64
    let dataMovementBytesPerSecond: UInt64
}

private final class ANEIOReportSampler: @unchecked Sendable {
    private let subscription: UnsafeRawPointer
    private let channels: CFMutableDictionary
    private let metadata: [ANEIOReportChannelMetadata]
    private let sourceChannels: CFDictionary
    private let selectedChannels: CFMutableArray?
    private let lock = NSLock()
    private var previousSample: (sample: CFDictionary, time: DispatchTime)?

    init?() {
        guard IOReportRuntime.isAvailable,
              let copyAllChannels = IOReportRuntime.copyAllChannels,
              let channelGetGroup = IOReportRuntime.channelGetGroup,
              let channelGetSubGroup = IOReportRuntime.channelGetSubGroup,
              let channelGetChannelName = IOReportRuntime.channelGetChannelName,
              let channelGetUnitLabel = IOReportRuntime.channelGetUnitLabel,
              let createSubscription = IOReportRuntime.createSubscription,
              let copiedChannels = copyAllChannels(0, 0)?.takeRetainedValue()
        else {
            return nil
        }

        guard let channelArray = CFDictionaryGetValue(copiedChannels, unsafeBitCast("IOReportChannels" as CFString, to: UnsafeRawPointer.self))
            .map({ unsafeBitCast($0, to: CFArray.self) })
        else {
            return nil
        }

        let channelCount = CFArrayGetCount(channelArray)
        guard let mutableChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(copiedChannels), copiedChannels) else {
            return nil
        }

        guard let selected = CFArrayCreateMutable(kCFAllocatorDefault, channelCount, nil) else {
            return nil
        }
        var metadata: [ANEIOReportChannelMetadata] = []
        metadata.reserveCapacity(channelCount)

        for index in 0..<channelCount {
            let rawItem = CFArrayGetValueAtIndex(channelArray, index)
            let item = unsafeBitCast(rawItem, to: CFDictionary.self)
            let group = Self.cfString(channelGetGroup(item)?.takeUnretainedValue())
            let subgroup = Self.cfString(channelGetSubGroup(item)?.takeUnretainedValue())
            let channel = Self.cfString(channelGetChannelName(item)?.takeUnretainedValue())
            let unit = Self.cfString(channelGetUnitLabel(item)?.takeUnretainedValue()).trimmingCharacters(in: .whitespacesAndNewlines)

            guard Self.matches(group: group, subgroup: subgroup, channel: channel, unit: unit) else {
                continue
            }

            CFArrayAppendValue(selected, rawItem)
            metadata.append(ANEIOReportChannelMetadata(group: group, subgroup: subgroup, channel: channel, unit: unit))
        }

        guard !metadata.isEmpty else {
            return nil
        }

        let key = unsafeBitCast("IOReportChannels" as CFString, to: UnsafeRawPointer.self)
        CFDictionarySetValue(mutableChannels, key, unsafeBitCast(selected, to: UnsafeRawPointer.self))

        var subscriptionChannels: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, mutableChannels, &subscriptionChannels, 0, nil) else {
            return nil
        }

        self.subscription = subscription
        self.channels = mutableChannels
        self.metadata = metadata
        self.sourceChannels = copiedChannels
        self.selectedChannels = selected
    }

    deinit {
        CFReleaseShim(unsafeBitCast(subscription, to: CFTypeRef.self))
    }

    func warmUp() {
        lock.lock()
        defer { lock.unlock() }
        guard previousSample == nil else { return }
        previousSample = rawSample()
    }

    func sampleMetrics(durationMilliseconds: UInt64, count: Int) -> ANEIOReportMetrics {
        lock.lock()
        defer { lock.unlock() }
        let requestedCount = max(1, min(count, 16))
        if previousSample == nil {
            previousSample = rawSample()
        }

        guard var previous = previousSample else {
            return ANEIOReportMetrics(activeTimePercent: 0, watts: 0, dataReadBytesPerSecond: 0, dataWriteBytesPerSecond: 0, dataMovementBytesPerSecond: 0)
        }
        previousSample = nil
        let startedAt = previous.time
        var samples: [ANEIOReportDeltaSample] = []
        samples.reserveCapacity(requestedCount)

        for index in 1...requestedCount {
            let targetMilliseconds = durationMilliseconds * UInt64(index) / UInt64(requestedCount)
            let targetTime = startedAt + .milliseconds(Int(targetMilliseconds))
            let now = DispatchTime.now()
            if targetTime > now {
                let deltaNanoseconds = Int(targetTime.uptimeNanoseconds - now.uptimeNanoseconds)
                if deltaNanoseconds > 0 {
                    usleep(useconds_t(min(deltaNanoseconds / 1_000, Int(UInt32.max))))
                }
            }

            let next = rawSample()
            let elapsedNanoseconds = next.time.uptimeNanoseconds - previous.time.uptimeNanoseconds
            let elapsedMilliseconds = max(UInt64(elapsedNanoseconds / 1_000_000), 1)

            if let createSamplesDelta = IOReportRuntime.createSamplesDelta,
               let delta = createSamplesDelta(previous.sample, next.sample, nil)?.takeRetainedValue() {
                let metrics = Self.extractANEMetrics(from: delta, metadata: metadata, durationMilliseconds: elapsedMilliseconds)
                samples.append(ANEIOReportDeltaSample(
                    activeTimePercent: metrics.activeTimePercent,
                    watts: metrics.watts,
                    dataReadBytesPerSecond: metrics.dataReadBytesPerSecond,
                    dataWriteBytesPerSecond: metrics.dataWriteBytesPerSecond,
                    dataMovementBytesPerSecond: metrics.dataMovementBytesPerSecond,
                    durationMilliseconds: elapsedMilliseconds
                ))
            }

            previous = next
        }

        previousSample = previous
        guard !samples.isEmpty else {
            return ANEIOReportMetrics(activeTimePercent: 0, watts: 0, dataReadBytesPerSecond: 0, dataWriteBytesPerSecond: 0, dataMovementBytesPerSecond: 0)
        }

        let totalWatts = samples.reduce(0.0) { $0 + $1.watts }
        let totalActive = samples.reduce(0.0) { $0 + $1.activeTimePercent }
        let totalRead = samples.reduce(0) { $0 + UInt64($1.dataReadBytesPerSecond) }
        let totalWrite = samples.reduce(0) { $0 + UInt64($1.dataWriteBytesPerSecond) }
        let totalMovement = samples.reduce(0) { $0 + UInt64($1.dataMovementBytesPerSecond) }
        let divisor = UInt64(samples.count)
        return ANEIOReportMetrics(
            activeTimePercent: totalActive / Double(samples.count),
            watts: totalWatts / Double(samples.count),
            dataReadBytesPerSecond: totalRead / divisor,
            dataWriteBytesPerSecond: totalWrite / divisor,
            dataMovementBytesPerSecond: totalMovement / divisor
        )
    }

    private func rawSample() -> (sample: CFDictionary, time: DispatchTime) {
        guard let createSamples = IOReportRuntime.createSamples,
              let sample = createSamples(subscription, channels, nil)?.takeRetainedValue()
        else {
            fatalError("IOReport runtime became unavailable after sampler initialization")
        }
        return (sample, .now())
    }

    private static func matches(group: String, subgroup: String, channel: String, unit: String) -> Bool {
        if group == "Energy Model" {
            guard unit == "mJ" || unit == "uJ" || unit == "nJ" else { return false }
            if channel == "GPU Energy" { return false }
            if channel.hasSuffix("CPU Energy") { return false }
            if channel.hasPrefix("DRAM") { return false }
            if channel.hasPrefix("GPU SRAM") { return false }
            return channel.hasPrefix("ANE")
        }

        if group == "AMC Stats", subgroup == "Perf Counters" {
            return channel == "ANE DCS RD"
                || channel == "ANE DCS WR"
                || channel == "ANE NRT AF RD"
                || channel == "ANE NRT AF WR"
        }

        if group == "ANS2", subgroup == "Power", channel == "Duty cycle" {
            return true
        }

        if group == "ANS2", subgroup == "Power", channel == "Power state" {
            return true
        }

        return false
    }

    private static func extractANEMetrics(from sample: CFDictionary, metadata: [ANEIOReportChannelMetadata], durationMilliseconds: UInt64) -> ANEIOReportMetrics {
        guard durationMilliseconds > 0 else {
            return ANEIOReportMetrics(activeTimePercent: 0, watts: 0, dataReadBytesPerSecond: 0, dataWriteBytesPerSecond: 0, dataMovementBytesPerSecond: 0)
        }
        guard let simpleGetIntegerValue = IOReportRuntime.simpleGetIntegerValue else {
            return ANEIOReportMetrics(activeTimePercent: 0, watts: 0, dataReadBytesPerSecond: 0, dataWriteBytesPerSecond: 0, dataMovementBytesPerSecond: 0)
        }
        guard let rawChannels = CFDictionaryGetValue(sample, unsafeBitCast("IOReportChannels" as CFString, to: UnsafeRawPointer.self)) else {
            return ANEIOReportMetrics(activeTimePercent: 0, watts: 0, dataReadBytesPerSecond: 0, dataWriteBytesPerSecond: 0, dataMovementBytesPerSecond: 0)
        }

        let channels = unsafeBitCast(rawChannels, to: CFArray.self)
        let count = min(CFArrayGetCount(channels), metadata.count)
        guard count > 0 else {
            return ANEIOReportMetrics(activeTimePercent: 0, watts: 0, dataReadBytesPerSecond: 0, dataWriteBytesPerSecond: 0, dataMovementBytesPerSecond: 0)
        }

        var watts = 0.0
        var activeTimePercent = 0.0
        var dataReadBytesPerSecond: UInt64 = 0
        var dataWriteBytesPerSecond: UInt64 = 0
        let seconds = Double(durationMilliseconds) / 1000.0
        for index in 0..<count {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(channels, index), to: CFDictionary.self)
            let meta = metadata[index]
            if meta.group == "Energy Model", meta.channel.hasPrefix("ANE") {
                let energy = Double(simpleGetIntegerValue(item, 0))
                switch meta.unit {
                case "mJ":
                    watts += (energy / 1_000.0) / seconds
                case "uJ":
                    watts += (energy / 1_000_000.0) / seconds
                case "nJ":
                    watts += (energy / 1_000_000_000.0) / seconds
                default:
                    break
                }
                continue
            }

            if meta.group == "AMC Stats", meta.subgroup == "Perf Counters" {
                let bytes = max(simpleGetIntegerValue(item, 0), 0)
                let bytesPerSecond = UInt64(Double(bytes) / seconds)
                switch meta.channel {
                case "ANE DCS RD", "ANE NRT AF RD":
                    dataReadBytesPerSecond += bytesPerSecond
                case "ANE DCS WR", "ANE NRT AF WR":
                    dataWriteBytesPerSecond += bytesPerSecond
                default:
                    break
                }
                continue
            }

            if meta.group == "ANS2", meta.subgroup == "Power", meta.channel == "Duty cycle" {
                let duty = Double(max(simpleGetIntegerValue(item, 0), 0))
                activeTimePercent = max(activeTimePercent, min(duty, 100))
                continue
            }

            if meta.group == "ANS2", meta.subgroup == "Power", meta.channel == "Power state" {
                let onResidency = onResidencyDelta(from: item)
                if onResidency > 0 {
                    let percent = min(max(Double(onResidency) / Double(durationMilliseconds * 1_000) * 100.0, 0), 100)
                    activeTimePercent = max(activeTimePercent, percent)
                }
            }
        }

        let totalMovement = dataReadBytesPerSecond + dataWriteBytesPerSecond
        let normalizedActiveTime = normalizeANEActiveTime(
            rawPercent: activeTimePercent,
            watts: watts,
            movementBytesPerSecond: totalMovement
        )
        return ANEIOReportMetrics(
            activeTimePercent: normalizedActiveTime,
            watts: max(watts, 0),
            dataReadBytesPerSecond: dataReadBytesPerSecond,
            dataWriteBytesPerSecond: dataWriteBytesPerSecond,
            dataMovementBytesPerSecond: totalMovement
        )
    }

    private static func normalizeANEActiveTime(rawPercent: Double, watts: Double, movementBytesPerSecond: UInt64) -> Double {
        let clamped = min(max(rawPercent, 0), 100)
        if clamped < 1, watts < 0.05 && movementBytesPerSecond < 4 * 1024 {
            return 0
        }
        if clamped <= 10 {
            return clamped * 0.35
        }
        if clamped <= 40 {
            return 3.5 + (clamped - 10) * 0.7
        }
        return min(24.5 + (clamped - 40) * 0.9, 100)
    }

    private static func onResidencyDelta(from item: CFDictionary) -> Int64 {
        guard let getCount = IOReportRuntime.stateGetCount,
              let getName = IOReportRuntime.stateGetNameForIndex,
              let getResidency = IOReportRuntime.stateGetResidency
        else {
            return 0
        }

        let count = getCount(item)
        guard count > 0 else { return 0 }
        for index in 0..<count {
            let name = cfString(getName(item, index)?.takeUnretainedValue())
            if name == "ON" {
                return max(getResidency(item, index), 0)
            }
        }
        return 0
    }

    private static func cfString(_ value: CFString?) -> String {
        guard let value else { return "" }
        return value as String
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var language: AppLanguage = .chinese
    @Published var temperatureUnit: TemperatureUnit = .celsius
    @Published private(set) var cpu = CPUState()
    @Published private(set) var memory = MemoryState()
    @Published private(set) var thermal = ThermalState()
    @Published private(set) var disks: [DiskState] = []
    @Published private(set) var networks: [NetworkState] = []
    @Published private(set) var npus: [NPUState] = []
    @Published private(set) var gpus: [GPUState] = []
    @Published private(set) var processSections: [ProcessSectionData] = []
    @Published private(set) var appHistoryRows: [AppHistoryRowData] = []
    @Published private(set) var startupRows: [StartupItemRowData] = []
    @Published private(set) var currentUserAppRows: [ProcessRowData] = []
    @Published private(set) var currentUserSection: UserPageSectionData?
    @Published private(set) var detailProcessRows: [DetailProcessRowData] = []
    @Published private(set) var serviceRows: [ServiceRowData] = []
    @Published var refreshSpeed: RefreshSpeedOption = .normal
    @Published private(set) var isTemporarilyPaused = false

    private var timer: Timer?
    private var previousTotalCPUTime: UInt64 = 0
    private var previousIdleCPUTime: UInt64 = 0
    private var previousPerCoreLoads: [[UInt32]] = []
    private var previousProcessCPUTime: [Int32: UInt64] = [:]
    private var previousProcessRUsage: [Int32: (read: UInt64, write: UInt64)] = [:]
    private var previousProcessEnergyNanojoules: [Int32: UInt64] = [:]
    private var previousProcessPackageIdleWakeups: [Int32: UInt64] = [:]
    private var previousProcessInterruptWakeups: [Int32: UInt64] = [:]
    private var processPowerTrendWatts: [Int32: Double] = [:]
    private var previousProcessNetworkTotals: [Int32: UInt64] = [:]
    private var previousProcessMeteredNetworkTotals: [Int32: UInt64] = [:]
    private var processStaticMetadata: [Int32: ProcessStaticMetadata] = [:]
    private var appHistoryCPUBaseline: [Int32: Double] = [:]
    private var appHistoryNetworkBaseline: [Int32: UInt64] = [:]
    private var appHistoryMeteredNetworkBaseline: [Int32: UInt64] = [:]
    private var previousDiskCounters: [String: (read: UInt64, write: UInt64, readOps: UInt64, writeOps: UInt64, readTimeNs: UInt64, writeTimeNs: UInt64)] = [:]
    private var previousNetworkCounters: [String: (in: UInt64, out: UInt64)] = [:]
    private var diskKindCache: [String: String] = [:]
    private var detailedDiskMetadataCache: [String: DiskDetailMetadata] = [:]
    private let iconCache = NSCache<NSString, NSImage>()
    private var aneIOReportSampler: ANEIOReportSampler?
    private var lastSampleDate = Date()
    private let hostPort = mach_host_self()
    private let pageSize: UInt64
    private let hostCPULoadInfoCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    private let hostVMInfo64Count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    private let pidPathInfoMaxSize = 4 * Int(MAXPATHLEN)
    private var cpuArchitecture = CPUArchitecture.unknown
    private var appleCachePairs: [InfoPair] = []
    private var legacyCachePairs: [InfoPair] = []
    private var rootWholeDiskID: String?
    private var hardwarePortMap: [String: String] = [:]
    private var thermalSMCReader: SMCReader?
    private var thermalFanActualKeys: [String] = []
    private var thermalFanMaxKeys: [String] = []
    private var thermalCPUTempKeys: [String] = []
    private var thermalGPUTempKeys: [String] = []
    private var cachedDiskTemperatureCelsius: Double?
    private var lastThermalRefreshDate: Date = .distantPast
    private var lastThermalDiskProbeDate: Date = .distantPast
    private var lastServicesRefreshDate: Date = .distantPast
    private var disabledLaunchdByGroup: [String: Set<String>] = [:]
    private var aneInfoCache: ANEDeviceInfo?
    private var hasStarted = false
    private var processNetworkTotals: [Int32: UInt64] = [:]
    private var meteredProcessNetworkTotals: [Int32: UInt64] = [:]
    private var staticProbeTask: Task<Void, Never>?
    private var processNetworkProbeTask: Task<Void, Never>?
    private var gpuProbeTask: Task<Void, Never>?
    private var npuInfoProbeTask: Task<Void, Never>?
    private var npuUsageProbeTask: Task<Void, Never>?
    private var startupProbeTask: Task<Void, Never>?
    private var servicesProbeTask: Task<Void, Never>?
    private var activeTab: TaskTab = .processes
    private var isCompactPresentation = true
    private var latestRowsByPID: [Int32: ProcessRowData] = [:]
    private var latestSnapshotsByPID: [Int32: ProcessSnapshot] = [:]
    private var latestVisibleApps: [NSRunningApplication] = []
    private var lastProcessNetworkProbeDate: Date = .distantPast
    private var lastGPUProbeDate: Date = .distantPast
    private var lastNPUUsageProbeDate: Date = .distantPast
    private var lastStartupRefreshDate: Date = .distantPast
    private var isStopping = false
    private var isDiskRefreshEnabled = false

    private struct ProcessRefreshResult {
        let rowsByPID: [Int32: ProcessRowData]
        let snapshotsByPID: [Int32: ProcessSnapshot]
        let visibleApps: [NSRunningApplication]
        let processCount: Int
        let threadCount: Int
        let openFilesCount: Int
    }

    private struct ProcessStaticMetadata {
        let startSeconds: Int64
        let startMicroseconds: Int64
        let displayName: String
        let path: String
        let isApplication: Bool
        let processCPUType: cpu_type_t?
    }

    init() {
        var pageSizeValue: vm_size_t = 0
        host_page_size(hostPort, &pageSizeValue)
        self.pageSize = UInt64(pageSizeValue)
        iconCache.countLimit = 512
        bootstrapStaticInfo()
        rootWholeDiskID = MonitorProbe.rootWholeDiskIdentifierFromMountedRoot()
        configureANEIOReportIfNeeded()
    }

    func start() {
        guard !hasStarted else { return }
        isStopping = false
        hasStarted = true
        refresh()
        configureTimer()
    }

    func stop() {
        isStopping = true
        hasStarted = false
        timer?.invalidate()
        timer = nil
        cancelSupplementalTasks()
        iconCache.removeAllObjects()
    }

    private func configureANEIOReportIfNeeded() {
        guard aneIOReportSampler == nil else { return }
        aneIOReportSampler = ANEIOReportSampler()
        aneIOReportSampler?.warmUp()
    }

    var sidebarItems: [PerfSidebarItem] {
        var items: [PerfSidebarItem] = [
            PerfSidebarItem(
                id: .cpu,
                title: "CPU",
                subtitle: "\(DisplayFormat.percent(cpu.utilizationPercent)) \(cpu.speedText)",
                tertiary: nil,
                accent: Color(red: 0.11, green: 0.55, blue: 0.95),
                sparkline: cpu.history,
                selectedFill: Color.gray.opacity(0.26)
            ),
            PerfSidebarItem(
                id: .memory,
                title: language.text("内存", "Memory"),
                subtitle: "\(DisplayFormat.memory(memory.usedBytes))/\(DisplayFormat.memory(memory.totalBytes)) (\(DisplayFormat.percent(percent(memory.usedBytes, memory.totalBytes))))",
                tertiary: nil,
                accent: Color(red: 0.72, green: 0.19, blue: 0.92),
                sparkline: memory.historyPercent,
                selectedFill: Color(red: 0.62, green: 0.82, blue: 1.0).opacity(0.45)
            )
        ]

        items.append(contentsOf: disks.map { disk in
            let diskKind = diskKindDisplayText(disk.kindLabel)
            let subtitle = disk.subtitle.isEmpty ? "(\(diskKind))" : "\(disk.subtitle) (\(diskKind))"
            return PerfSidebarItem(
                id: .disk(disk.id),
                title: disk.title,
                subtitle: subtitle,
                tertiary: DisplayFormat.percent(disk.activityPercent),
                accent: Color(red: 0.44, green: 0.77, blue: 0.10),
                sparkline: disk.activityHistory,
                selectedFill: Color(red: 0.62, green: 0.82, blue: 1.0).opacity(0.45)
            )
        })

        items.append(contentsOf: networks.map { network in
            let subtitle = language.isChinese && network.subtitle == "Wi-Fi"
                ? "WLAN"
                : language.localizeNetworkMedium(network.subtitle)
            return PerfSidebarItem(
                id: .network(network.id),
                title: network.displayName,
                subtitle: subtitle,
                tertiary: language.text("发送: ", "Send: ") + "\(DisplayFormat.networkRate(network.sendBytesPerSecond)) " + language.text("接收: ", "Recv: ") + DisplayFormat.networkRate(network.receiveBytesPerSecond),
                accent: Color(red: 0.85, green: 0.46, blue: 0.08),
                sparkline: network.totalHistory,
                selectedFill: Color(red: 0.62, green: 0.82, blue: 1.0).opacity(0.45)
            )
        })

        items.append(contentsOf: npus.map { npu in
            return PerfSidebarItem(
                id: .npu(npu.id),
                title: npu.title,
                subtitle: npu.subtitle,
                tertiary: DisplayFormat.percent(npu.activeTimePercent),
                accent: Color(red: 0.96, green: 0.26, blue: 0.26),
                sparkline: npu.historyActiveTime,
                selectedFill: Color(red: 0.62, green: 0.82, blue: 1.0).opacity(0.45)
            )
        })

        items.append(contentsOf: gpus.map { gpu in
            PerfSidebarItem(
                id: .gpu(gpu.id),
                title: gpu.title,
                subtitle: gpu.subtitle,
                tertiary: DisplayFormat.percent(gpu.utilizationPercent),
                accent: Color(red: 0.68, green: 0.32, blue: 0.94),
                sparkline: gpu.supportsEngineBreakdown ? gpu.history3D : gpu.historyOverall,
                selectedFill: Color(red: 0.62, green: 0.82, blue: 1.0).opacity(0.45)
            )
        })

        let fanless = thermal.maximumFanRPM == 0 || (thermal.currentFanRPM == 0 && thermal.peakFanRPM == 0)
        items.append(
            PerfSidebarItem(
                id: .thermal,
                title: language.text("散热", "Cooling"),
                subtitle: language.isChinese ? thermal.subtitle : thermal.subtitle.replacingOccurrences(of: "温度", with: "Temperature"),
                tertiary: language.text(thermal.statusText, thermalStatusEnglish(from: thermal.statusText)),
                accent: Color(red: 0.33, green: 0.73, blue: 0.25),
                sparkline: fanless
                    ? thermal.historyNetworkTemperatureCelsius.map { min($0 / max(thermal.networkTemperatureChartCeilingCelsius, 1) * 100.0, 100.0) }
                    : thermal.historyFanRPM.map { min($0 / max(thermal.fanChartCeilingRPM, 1) * 100.0, 100.0) },
                selectedFill: Color(red: 0.62, green: 0.82, blue: 1.0).opacity(0.45)
            )
        )

        return items
    }

    func detail(for selection: PerfSelection) -> PerformanceDetailViewData? {
        switch selection {
        case .cpu:
            return cpuDetail()
        case .memory:
            return memoryDetail()
        case .disk(let id):
            guard let disk = disks.first(where: { $0.id == id }) else { return nil }
            return diskDetail(disk)
        case .network(let id):
            guard let network = networks.first(where: { $0.id == id }) else { return nil }
            return networkDetail(network)
        case .npu(let id):
            guard let npu = npus.first(where: { $0.id == id }) else { return nil }
            return npuDetail(npu)
        case .gpu(let id):
            guard let gpu = gpus.first(where: { $0.id == id }) else { return nil }
            return gpuDetail(gpu)
        case .thermal:
            return thermalDetail()
        }
    }

    private func bootstrapStaticInfo() {
        var nextCPU = cpu
        nextCPU.modelName = sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "Apple Silicon"
        nextCPU.logicalCores = Int(sysctlInt("hw.logicalcpu") ?? 0)
        nextCPU.physicalCores = Int(sysctlInt("hw.physicalcpu") ?? 0)
        cpuArchitecture = resolveCPUArchitecture()
        let frequencyInfo = detectCPUFrequencyInfo()
        nextCPU.baseSpeedText = frequencyInfo.base
        nextCPU.performanceCoreSpeedText = frequencyInfo.primary
        nextCPU.efficiencyCoreSpeedText = frequencyInfo.secondary
        nextCPU.coreTierMode = frequencyInfo.mode
        cpu = nextCPU
        loadCachePresentation()
    }

    private func refresh() {
        guard !isTemporarilyPaused else { return }
        let now = Date()
        let interval = max(now.timeIntervalSince(lastSampleDate), 0.4)
        lastSampleDate = now

        refreshCPU(interval: interval)
        refreshMemory()
        if isDiskRefreshEnabled {
            refreshDisks(interval: interval)
        }
        refreshNetworks(interval: interval)
        refreshNPUs(ifNeededAt: now)
        refreshGPUs(ifNeededAt: now)
        refreshThermal(interval: interval)
        let processRefresh = refreshProcesses(interval: interval)
        latestRowsByPID = processRefresh.rowsByPID
        latestSnapshotsByPID = processRefresh.snapshotsByPID
        latestVisibleApps = processRefresh.visibleApps
        rebuildVisibleProcessData()
        refreshStartupItems()

        var nextCPU = cpu
        nextCPU.processCount = processRefresh.processCount
        nextCPU.threadCount = processRefresh.threadCount
        nextCPU.openFilesCount = processRefresh.openFilesCount
        nextCPU.uptimeText = DisplayFormat.uptime(ProcessInfo.processInfo.systemUptime)
        cpu = nextCPU
        requestSupplementalRefreshes(ifNeededAt: now)
    }

    private var shouldBuildProcessSections: Bool {
        isCompactPresentation || activeTab == .processes
    }

    private var shouldBuildAppHistory: Bool {
        activeTab == .history
    }

    private var shouldBuildCurrentUserApps: Bool {
        activeTab == .users
    }

    private var shouldBuildDetailRows: Bool {
        activeTab == .details
    }

    private var shouldRefreshStartupRows: Bool {
        activeTab == .startup || startupRows.isEmpty
    }

    private var shouldRefreshServiceRows: Bool {
        activeTab == .services || serviceRows.isEmpty
    }

    private var shouldRefreshProcessNetworkTotals: Bool {
        isCompactPresentation || activeTab == .processes || activeTab == .history || activeTab == .users
    }

    private func rebuildVisibleProcessData() {
        if shouldBuildProcessSections {
            refreshProcessSections(rowsByPID: latestRowsByPID, visibleApps: latestVisibleApps)
        }
        if shouldBuildAppHistory {
            refreshAppHistory(runningApps: latestVisibleApps)
        }
        if shouldBuildCurrentUserApps {
            refreshCurrentUserApps(runningApps: latestVisibleApps, processRowsByPID: latestRowsByPID)
        }
        if shouldBuildDetailRows {
            refreshDetailProcessRows(rowsByPID: latestRowsByPID, snapshotsByPID: latestSnapshotsByPID)
        }
    }

    func refreshNow() {
        lastServicesRefreshDate = .distantPast
        lastStartupRefreshDate = .distantPast
        lastProcessNetworkProbeDate = .distantPast
        lastGPUProbeDate = .distantPast
        lastNPUUsageProbeDate = .distantPast
        refresh()
    }

    func refreshServicesNow() {
        lastServicesRefreshDate = .distantPast
        scheduleServicesRefresh(ifNeededAt: Date(), force: true)
    }

    func setRefreshSpeed(_ speed: RefreshSpeedOption) {
        refreshSpeed = speed
        configureTimer()
    }

    func setDiskRefreshEnabled(_ enabled: Bool) {
        guard isDiskRefreshEnabled != enabled else { return }
        isDiskRefreshEnabled = enabled

        guard enabled, hasStarted, !isTemporarilyPaused else { return }
        let interval = max(Date().timeIntervalSince(lastSampleDate), 0.4)
        refreshDisks(interval: interval)
    }

    func setPresentation(tab: TaskTab, compactMode: Bool) {
        let changed = activeTab != tab || isCompactPresentation != compactMode
        activeTab = tab
        isCompactPresentation = compactMode
        guard changed else { return }
        rebuildVisibleProcessData()
        requestSupplementalRefreshes(ifNeededAt: Date())
    }

    func loadDetailedDiskMetadataIfNeeded(for selection: PerfSelection) {
        guard case .disk(let diskID) = selection else { return }
        loadDetailedDiskMetadataIfNeeded(forDiskID: diskID)
    }

    func hasDetailedDiskMetadata(forDiskID diskID: String) -> Bool {
        detailedDiskMetadataCache[diskID] != nil || disks.first(where: { $0.id == diskID })?.hasDetailedMetadata == true
    }

    func loadDetailedDiskMetadataInBackground(forDiskID diskID: String) async -> Bool {
        if hasDetailedDiskMetadata(forDiskID: diskID) {
            return true
        }

        let rootWholeDiskID = self.rootWholeDiskID
        let metadata = await Task.detached(priority: .utility) {
            MonitorProbe.probeDetailedDiskMetadata(forDiskID: diskID, rootWholeDiskID: rootWholeDiskID)
        }.value

        guard let metadata else { return false }

        detailedDiskMetadataCache[diskID] = metadata
        diskKindCache[diskID] = metadata.kind

        guard let index = disks.firstIndex(where: { $0.id == diskID }) else { return true }
        disks[index].subtitle = metadata.subtitle
        disks[index].kindLabel = metadata.kind
        disks[index].availableBytes = metadata.availableBytes
        disks[index].isSystemDisk = metadata.isSystemDisk
        disks[index].hasDetailedMetadata = true
        return true
    }

    func loadDetailedDiskMetadataIfNeeded(forDiskID diskID: String) {
        guard detailedDiskMetadataCache[diskID] == nil else { return }
        guard let metadata = probeDetailedDiskMetadata(forDiskID: diskID) else { return }

        detailedDiskMetadataCache[diskID] = metadata
        diskKindCache[diskID] = metadata.kind

        guard let index = disks.firstIndex(where: { $0.id == diskID }) else { return }
        disks[index].subtitle = metadata.subtitle
        disks[index].kindLabel = metadata.kind
        disks[index].availableBytes = metadata.availableBytes
        disks[index].isSystemDisk = metadata.isSystemDisk
        disks[index].hasDetailedMetadata = true
    }

    func setTemporarilyPaused(_ paused: Bool) {
        guard isTemporarilyPaused != paused else { return }
        isTemporarilyPaused = paused
        if !paused {
            lastSampleDate = Date()
            refresh()
        }
    }

    nonisolated func currentBootSeconds() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    nonisolated func currentBootDurationSeconds() -> Double {
        let uptime = ProcessInfo.processInfo.systemUptime
        // Use a bounded heuristic for boot-to-desktop duration instead of raw uptime.
        // This avoids presenting uptime as boot duration while keeping a stable value
        // when no public boot-complete timestamp is available on macOS.
        return min(max(uptime * 0.0028, 8.0), 45.0)
    }

    private func configureTimer() {
        timer?.invalidate()
        guard let interval = refreshSpeed.interval else {
            timer = nil
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func requestSupplementalRefreshes(ifNeededAt now: Date) {
        guard !isStopping else { return }
        scheduleStaticProbeIfNeeded()
        scheduleProcessNetworkProbe(ifNeededAt: now)
        scheduleStartupRefresh(ifNeededAt: now)
        scheduleServicesRefresh(ifNeededAt: now)
    }

    private func cancelSupplementalTasks() {
        staticProbeTask?.cancel()
        processNetworkProbeTask?.cancel()
        gpuProbeTask?.cancel()
        npuInfoProbeTask?.cancel()
        npuUsageProbeTask?.cancel()
        startupProbeTask?.cancel()
        servicesProbeTask?.cancel()
    }

    private func scheduleStaticProbeIfNeeded() {
        guard !isStopping else { return }
        guard staticProbeTask == nil else { return }
        guard hardwarePortMap.isEmpty || rootWholeDiskID == nil else { return }

        staticProbeTask = Task.detached(priority: .utility) {
            let snapshot = MonitorProbe.collectStaticProbeSnapshot()
            await MainActor.run {
                self.staticProbeTask = nil
                guard !self.isStopping else { return }
                if let rootWholeDiskID = snapshot.rootWholeDiskID {
                    self.rootWholeDiskID = rootWholeDiskID
                }
                if !snapshot.hardwarePortMap.isEmpty {
                    self.hardwarePortMap = snapshot.hardwarePortMap
                }
            }
        }
    }

    private func scheduleProcessNetworkProbe(ifNeededAt now: Date, force: Bool = false) {
        guard !isStopping else { return }
        guard processNetworkProbeTask == nil else { return }
        guard force || shouldRefreshProcessNetworkTotals || processNetworkTotals.isEmpty else { return }
        let minimumInterval = max(refreshSpeed.interval ?? 1.0, 0.5)
        guard force || processNetworkTotals.isEmpty || now.timeIntervalSince(lastProcessNetworkProbeDate) >= minimumInterval else { return }

        lastProcessNetworkProbeDate = now
        processNetworkProbeTask = Task.detached(priority: .utility) {
            let totals = MonitorProbe.collectProcessNetworkSnapshot(interfaceFilter: nil)
            let meteredTotals = MonitorProbe.collectProcessNetworkSnapshot(interfaceFilter: "expensive")
            await MainActor.run {
                self.processNetworkProbeTask = nil
                guard !self.isStopping else { return }
                self.processNetworkTotals = totals
                self.meteredProcessNetworkTotals = meteredTotals
            }
        }
    }

    private func scheduleGPURefresh(ifNeededAt now: Date, force: Bool = false) {
        guard !isStopping else { return }
        guard gpuProbeTask == nil else { return }
        guard force || gpus.isEmpty || now.timeIntervalSince(lastGPUProbeDate) >= 2 else { return }

        let previousGPUs = gpus
        let language = language
        let cpuArchitecture = cpuArchitecture
        lastGPUProbeDate = now
        gpuProbeTask = Task.detached(priority: .utility) {
            let nextGPUs = MonitorProbe.collectGPUStates(previous: previousGPUs, language: language, cpuArchitecture: cpuArchitecture)
            await MainActor.run {
                self.gpuProbeTask = nil
                guard !self.isStopping else { return }
                self.gpus = nextGPUs
            }
        }
    }

    private func scheduleNPURefresh(ifNeededAt now: Date, force: Bool = false) {
        guard !isStopping else { return }
        guard cpuArchitecture != .intelLike else {
            npus = []
            return
        }

        if aneInfoCache == nil {
            guard npuInfoProbeTask == nil else { return }
            let architecture = cpuArchitecture
            npuInfoProbeTask = Task.detached(priority: .utility) {
                let info = MonitorProbe.collectANEDeviceInfo(cpuArchitecture: architecture)
                await MainActor.run {
                    self.npuInfoProbeTask = nil
                    guard !self.isStopping else { return }
                    self.aneInfoCache = info
                }
            }
            return
        }

        guard npuUsageProbeTask == nil else { return }
        let minimumInterval = max(refreshSpeed.interval ?? 1.0, 0.5)
        guard force || npus.isEmpty || now.timeIntervalSince(lastNPUUsageProbeDate) >= minimumInterval else { return }

        let aneInfo = aneInfoCache
        let previousNPU = npus.first
        let totalMemory = memory.totalBytes
        let samplingDurationMilliseconds = max(UInt64((minimumInterval * 1000).rounded()), 500)
        let aneSampler = aneIOReportSampler
        lastNPUUsageProbeDate = now
        npuUsageProbeTask = Task.detached(priority: .utility) {
            let aneMetrics = aneSampler?.sampleMetrics(durationMilliseconds: samplingDurationMilliseconds, count: 4)
                ?? ANEIOReportMetrics(activeTimePercent: 0, watts: 0, dataReadBytesPerSecond: 0, dataWriteBytesPerSecond: 0, dataMovementBytesPerSecond: 0)
            let nextNPU = MonitorProbe.collectNPUState(
                previous: previousNPU,
                aneInfo: aneInfo,
                totalMemory: totalMemory,
                activeTimePercent: aneMetrics.activeTimePercent,
                powerWatts: aneMetrics.watts,
                dataReadBytesPerSecond: aneMetrics.dataReadBytesPerSecond,
                dataWriteBytesPerSecond: aneMetrics.dataWriteBytesPerSecond,
                dataMovementBytesPerSecond: aneMetrics.dataMovementBytesPerSecond
            )
            await MainActor.run {
                self.npuUsageProbeTask = nil
                guard !self.isStopping else { return }
                self.npus = nextNPU.map { [$0] } ?? []
            }
        }
    }

    private func scheduleStartupRefresh(ifNeededAt now: Date, force: Bool = false) {
        guard !isStopping else { return }
        guard startupProbeTask == nil else { return }
        guard force || shouldRefreshStartupRows else { return }
        guard force || startupRows.isEmpty || now.timeIntervalSince(lastStartupRefreshDate) >= 30 else { return }

        lastStartupRefreshDate = now
        let language = language
        startupProbeTask = Task.detached(priority: .utility) {
            let snapshot = MonitorProbe.collectStartupRows()
            await MainActor.run {
                self.startupProbeTask = nil
                guard !self.isStopping else { return }
                self.disabledLaunchdByGroup = snapshot.disabledLaunchdByGroup
                self.startupRows = snapshot.rows.map { row in
                    StartupItemRowData(
                        id: row.id,
                        name: row.name,
                        icon: row.iconProgramPath.flatMap { self.startupItemIcon(fromProgramPath: $0) },
                        publisher: row.publisher,
                        status: row.status,
                        startupImpact: row.startupImpact
                    )
                }
                if self.language != language {
                    self.startupRows = self.startupRows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
            }
        }
    }

    private func scheduleServicesRefresh(ifNeededAt now: Date, force: Bool = false) {
        guard !isStopping else { return }
        guard servicesProbeTask == nil else { return }
        guard force || shouldRefreshServiceRows else { return }
        guard force || serviceRows.isEmpty || now.timeIntervalSince(lastServicesRefreshDate) >= 5 else { return }

        lastServicesRefreshDate = now
        servicesProbeTask = Task.detached(priority: .utility) {
            let snapshot = MonitorProbe.collectServiceRows(uid: getuid())
            await MainActor.run {
                self.servicesProbeTask = nil
                guard !self.isStopping else { return }
                self.serviceRows = snapshot.map { row in
                    ServiceRowData(
                        id: row.id,
                        name: row.name,
                        icon: row.iconProgramPath.flatMap { self.startupItemIcon(fromProgramPath: $0) },
                        pid: row.pid,
                        serviceDescription: row.serviceDescription,
                        status: row.status,
                        group: row.group,
                        label: row.label
                    )
                }
            }
        }
    }

    private func refreshCPU(interval: TimeInterval) {
        var nextCPU = cpu
        var count = hostCPULoadInfoCount
        var loadInfo = host_cpu_load_info()
        let kr = withUnsafeMutablePointer(to: &loadInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        let ticks = loadInfo.cpu_ticks
        let total = UInt64(ticks.0 + ticks.1 + ticks.2 + ticks.3)
        let idle = UInt64(ticks.2)
        let deltaTotal = max(total - previousTotalCPUTime, 1)
        let deltaIdle = idle - previousIdleCPUTime
        previousTotalCPUTime = total
        previousIdleCPUTime = idle

        let activePercent = Double(deltaTotal - deltaIdle) / Double(deltaTotal) * 100
        nextCPU.utilizationPercent = max(0, min(activePercent, 100))
        nextCPU.speedText = currentPrimaryCPUSpeedText()
        nextCPU.history = shifted(nextCPU.history, adding: nextCPU.utilizationPercent)

        var processorCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let hostResult = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &processorCount, &cpuInfo, &infoCount)
        if hostResult == KERN_SUCCESS, let cpuInfo {
            let cpuLoadPointer = UnsafeMutableBufferPointer(start: cpuInfo, count: Int(infoCount))
            var coreLoads: [[UInt32]] = []
            for core in 0..<Int(processorCount) {
                let base = core * Int(CPU_STATE_MAX)
                let user = UInt32(cpuLoadPointer[base + Int(CPU_STATE_USER)])
                let system = UInt32(cpuLoadPointer[base + Int(CPU_STATE_SYSTEM)])
                let idleTicks = UInt32(cpuLoadPointer[base + Int(CPU_STATE_IDLE)])
                let nice = UInt32(cpuLoadPointer[base + Int(CPU_STATE_NICE)])
                coreLoads.append([user, system, idleTicks, nice])
            }

            if previousPerCoreLoads.count == coreLoads.count {
                nextCPU.coreHistories = zip(coreLoads, previousPerCoreLoads).enumerated().map { index, pair in
                    let current = pair.0
                    let previous = pair.1
                    let totalDelta = zip(current, previous).reduce(UInt32(0)) { $0 + max($1.0 - $1.1, 0) }
                    let idleDelta = max(current[2] - previous[2], 0)
                    let usage = totalDelta == 0 ? 0 : Double(totalDelta - idleDelta) / Double(totalDelta) * 100
                    let existing = nextCPU.coreHistories.indices.contains(index) ? nextCPU.coreHistories[index] : Array(repeating: 0, count: 60)
                    return shifted(existing, adding: usage)
                }
            } else {
                nextCPU.coreHistories = coreLoads.map { _ in Array(repeating: 0, count: 60) }
            }
            previousPerCoreLoads = coreLoads

            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }

        if nextCPU.coreHistories.isEmpty {
            let coreCount = max(nextCPU.logicalCores, 1)
            nextCPU.coreHistories = Array(repeating: nextCPU.history, count: coreCount)
        }
        cpu = nextCPU
    }

    private func refreshMemory() {
        var nextMemory = memory
        var stats = vm_statistics64()
        var count = hostVMInfo64Count
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let total = ProcessInfo.processInfo.physicalMemory
        let free = UInt64(stats.free_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let fileBacked = UInt64(stats.external_page_count) * pageSize
        let anonymous = UInt64(stats.internal_page_count) * pageSize

        // Activity Monitor's memory categories track anonymous and file-backed
        // pages more closely than active/inactive lists. Using active/inactive
        // overstates cache and understates app memory on modern macOS.
        let appMemory = anonymous > purgeable ? anonymous - purgeable : anonymous
        let cached = fileBacked + purgeable
        let available = free + speculative + cached
        let used = min(total, appMemory + wired + compressed)

        nextMemory.totalBytes = total
        nextMemory.usedBytes = used
        nextMemory.availableBytes = available
        nextMemory.compressedBytes = compressed
        nextMemory.cachedBytes = cached
        nextMemory.wiredBytes = wired
        nextMemory.appMemoryBytes = appMemory
        nextMemory.swapUsedBytes = swapUsageBytes()
        nextMemory.historyPercent = shifted(nextMemory.historyPercent, adding: percent(used, total))
        nextMemory.historyUsedBytes = shifted(nextMemory.historyUsedBytes, adding: Double(used))
        nextMemory.chartCeilingBytes = smoothedDynamicCeiling(
            previous: nextMemory.chartCeilingBytes,
            latest: Double(used),
            minimum: Double(max(total / 4, 1))
        )
        memory = nextMemory
    }

    private func refreshProcesses(interval: TimeInterval) -> ProcessRefreshResult {
        let pids = listPIDs()
        let logicalCores = max(cpu.logicalCores, 1)
        var rowsByPID: [Int32: ProcessRowData] = [:]
        rowsByPID.reserveCapacity(pids.count)
        var snapshotsByPID: [Int32: ProcessSnapshot] = [:]
        snapshotsByPID.reserveCapacity(pids.count)

        var newCPUCache: [Int32: UInt64] = [:]
        var newRUsageCache: [Int32: (UInt64, UInt64)] = [:]
        var newEnergyCache: [Int32: UInt64] = [:]
        var newPackageWakeupCache: [Int32: UInt64] = [:]
        var newInterruptWakeupCache: [Int32: UInt64] = [:]
        var nextPowerTrendWatts: [Int32: Double] = [:]
        let processNetworkTotals = self.processNetworkTotals
        var newNetworkCache: [Int32: UInt64] = [:]
        var totalThreadCount = 0
        var totalOpenFilesCount = 0

        for pid in pids where pid > 0 {
            guard let info = processInfo(pid: pid) else { continue }
            snapshotsByPID[pid] = info
            totalThreadCount += info.threadCount
            totalOpenFilesCount += info.openFiles

            let totalCPU = info.totalCPUTime
            let previousCPU = previousProcessCPUTime[pid] ?? totalCPU
            let cpuDelta = totalCPU >= previousCPU ? totalCPU - previousCPU : 0
            var cpuPercent = min(max((Double(cpuDelta) / (interval * 1_000_000_000.0)) / Double(logicalCores) * 100, 0), 999)
            if cpuPercent > 0 && cpuPercent < 0.1 {
                cpuPercent = 0.1
            }
            newCPUCache[pid] = totalCPU

            let currentDisk: (read: UInt64, write: UInt64) = (info.diskReadBytes, info.diskWriteBytes)
            let previousDisk = previousProcessRUsage[pid] ?? currentDisk
            let diskDelta = (currentDisk.read >= previousDisk.read ? currentDisk.read - previousDisk.read : 0) + (currentDisk.write >= previousDisk.write ? currentDisk.write - previousDisk.write : 0)
            let diskPerSecond = UInt64(Double(diskDelta) / interval)
            newRUsageCache[pid] = currentDisk

            let energyNanojoules = info.energyNanojoules
            let previousEnergy = previousProcessEnergyNanojoules[pid] ?? energyNanojoules
            let energyDelta = energyNanojoules >= previousEnergy ? energyNanojoules - previousEnergy : 0
            let powerUsageWatts = Double(energyDelta) / 1_000_000_000.0 / interval
            newEnergyCache[pid] = energyNanojoules

            let packageWakeups = info.packageIdleWakeups
            let previousPackageWakeups = previousProcessPackageIdleWakeups[pid] ?? packageWakeups
            let packageWakeupDelta = packageWakeups >= previousPackageWakeups ? packageWakeups - previousPackageWakeups : 0
            newPackageWakeupCache[pid] = packageWakeups

            let interruptWakeups = info.interruptWakeups
            let previousInterruptWakeups = previousProcessInterruptWakeups[pid] ?? interruptWakeups
            let interruptWakeupDelta = interruptWakeups >= previousInterruptWakeups ? interruptWakeups - previousInterruptWakeups : 0
            newInterruptWakeupCache[pid] = interruptWakeups

            let totalWakeupsPerSecond = Double(packageWakeupDelta + interruptWakeupDelta) / interval
            let previousTrend = processPowerTrendWatts[pid] ?? powerUsageWatts
            let powerTrendWatts = previousTrend * 0.74 + powerUsageWatts * 0.26
            nextPowerTrendWatts[pid] = powerTrendWatts

            let totalNetworkBytes = processNetworkTotals[pid] ?? 0
            let previousNetworkBytes = previousProcessNetworkTotals[pid] ?? totalNetworkBytes
            let networkDelta = totalNetworkBytes >= previousNetworkBytes ? (totalNetworkBytes - previousNetworkBytes) : UInt64(0)
            let networkPerSecond = UInt64(Double(networkDelta) / interval)
            newNetworkCache[pid] = totalNetworkBytes

            let row = ProcessRowData(
                pid: pid,
                name: info.displayName,
                icon: nil,
                path: info.path,
                isApp: info.isApplication,
                isParent: false,
                parentPID: nil,
                childCount: 0,
                cpuPercent: cpuPercent,
                memoryBytes: info.residentSize,
                diskBytesPerSecond: diskPerSecond,
                networkBytesPerSecond: networkPerSecond,
                networkText: networkPerSecond == 0 ? "0 Mbps" : DisplayFormat.networkRate(networkPerSecond),
                powerUsageWatts: powerUsageWatts,
                powerTrendWatts: powerTrendWatts,
                powerImpact: DisplayFormat.impactLabel(powerUsageWatts: powerUsageWatts, wakeupsPerSecond: totalWakeupsPerSecond, language: language),
                trend: DisplayFormat.impactLabel(powerUsageWatts: powerTrendWatts, wakeupsPerSecond: totalWakeupsPerSecond * 0.7, language: language),
                threadCount: info.threadCount,
                openFiles: info.openFiles
            )
            rowsByPID[pid] = row
        }

        previousProcessCPUTime = newCPUCache
        previousProcessRUsage = newRUsageCache
        previousProcessEnergyNanojoules = newEnergyCache
        previousProcessPackageIdleWakeups = newPackageWakeupCache
        previousProcessInterruptWakeups = newInterruptWakeupCache
        processPowerTrendWatts = nextPowerTrendWatts
        previousProcessNetworkTotals = newNetworkCache
        processStaticMetadata = processStaticMetadata.filter { snapshotsByPID[$0.key] != nil }

        let visibleApps = frontWindowApplications()

        return ProcessRefreshResult(
            rowsByPID: rowsByPID,
            snapshotsByPID: snapshotsByPID,
            visibleApps: visibleApps,
            processCount: snapshotsByPID.count,
            threadCount: totalThreadCount,
            openFilesCount: totalOpenFilesCount
        )
    }

    private func refreshProcessSections(rowsByPID: [Int32: ProcessRowData], visibleApps: [NSRunningApplication]) {
        let visibleAppPIDs = Set(visibleApps.map(\.processIdentifier))
        let appRows: [ProcessRowData] = visibleApps.map { app in
            if let row = rowsByPID[app.processIdentifier] {
                return processRow(
                    row,
                    name: app.localizedName ?? row.name,
                    icon: app.icon ?? iconForProcess(path: row.path)
                )
            }

            return ProcessRowData(
                pid: app.processIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "未知应用",
                icon: app.icon,
                path: app.bundleURL?.path ?? "",
                isApp: true,
                isParent: false,
                parentPID: nil,
                childCount: 0,
                cpuPercent: 0,
                memoryBytes: 0,
                diskBytesPerSecond: 0,
                networkBytesPerSecond: 0,
                networkText: "0 Mbps",
                powerUsageWatts: 0,
                powerTrendWatts: 0,
                powerImpact: DisplayFormat.impactLabel(powerUsageWatts: 0, wakeupsPerSecond: 0, language: language),
                trend: DisplayFormat.impactLabel(powerUsageWatts: 0, wakeupsPerSecond: 0, language: language),
                threadCount: 0,
                openFiles: 0
            )
        }

        let background = rowsByPID.values
            .filter { !visibleAppPIDs.contains($0.pid) }
            .sorted(by: processRowSort)
            .prefix(160)
            .map { row in
                processRow(row, icon: iconForProcess(path: row.path))
            }

        processSections = [
            ProcessSectionData(kind: .apps, rows: appRows),
            ProcessSectionData(kind: .background, rows: Array(background))
        ]
    }

    private func processRow(_ row: ProcessRowData, name: String? = nil, icon: NSImage?) -> ProcessRowData {
        ProcessRowData(
            pid: row.pid,
            name: name ?? row.name,
            icon: icon,
            path: row.path,
            isApp: row.isApp,
            isParent: row.isParent,
            parentPID: row.parentPID,
            childCount: row.childCount,
            cpuPercent: row.cpuPercent,
            memoryBytes: row.memoryBytes,
            diskBytesPerSecond: row.diskBytesPerSecond,
            networkBytesPerSecond: row.networkBytesPerSecond,
            networkText: row.networkText,
            powerUsageWatts: row.powerUsageWatts,
            powerTrendWatts: row.powerTrendWatts,
            powerImpact: row.powerImpact,
            trend: row.trend,
            threadCount: row.threadCount,
            openFiles: row.openFiles
        )
    }

    private func refreshAppHistory(runningApps apps: [NSRunningApplication]) {
        let networkTotals = processNetworkTotals
        let meteredNetworkTotals = meteredProcessNetworkTotals
        let historyRows: [AppHistoryRowData] = apps.map { app in
            let pid = app.processIdentifier
            let name = app.localizedName ?? app.bundleIdentifier ?? language.text("未知应用", "Unknown app")
            let icon = app.icon
            let totalCPUSeconds = processCPUSeconds(pid: pid)
            let cpuSeconds = max(0, totalCPUSeconds - (appHistoryCPUBaseline[pid] ?? 0))
            let cpuTime = formatCPUTime(cpuSeconds)
            let totalNetworkBytes = networkTotals[pid] ?? 0
            let networkBytes = totalNetworkBytes >= (appHistoryNetworkBaseline[pid] ?? 0) ? totalNetworkBytes - (appHistoryNetworkBaseline[pid] ?? 0) : 0
            let totalMeteredNetworkBytes = meteredNetworkTotals[pid] ?? 0
            let meteredNetworkBytes = totalMeteredNetworkBytes >= (appHistoryMeteredNetworkBaseline[pid] ?? 0) ? totalMeteredNetworkBytes - (appHistoryMeteredNetworkBaseline[pid] ?? 0) : 0
            return AppHistoryRowData(
                id: "\(pid)",
                name: name,
                icon: icon,
                path: app.bundleURL?.path ?? "",
                cpuTime: cpuTime,
                cpuSeconds: cpuSeconds,
                network: DisplayFormat.decimalBytes(networkBytes),
                networkBytes: networkBytes,
                meteredNetwork: meteredNetworkBytes > 0 ? DisplayFormat.decimalBytes(meteredNetworkBytes) : "",
                meteredNetworkBytes: meteredNetworkBytes
            )
        }
        appHistoryRows = historyRows
    }

    private func refreshCurrentUserApps(runningApps apps: [NSRunningApplication], processRowsByPID rowsByPID: [Int32: ProcessRowData]) {
        let rows: [ProcessRowData] = apps.compactMap { app -> ProcessRowData? in
            let pid = app.processIdentifier
            guard let row = rowsByPID[pid] else { return nil }
            return ProcessRowData(
                pid: row.pid,
                name: app.localizedName ?? row.name,
                icon: app.icon ?? iconForProcess(path: row.path),
                path: row.path,
                isApp: true,
                isParent: false,
                parentPID: nil,
                childCount: 0,
                cpuPercent: row.cpuPercent,
                memoryBytes: row.memoryBytes,
                diskBytesPerSecond: row.diskBytesPerSecond,
                networkBytesPerSecond: row.networkBytesPerSecond,
                networkText: row.networkText,
                powerUsageWatts: row.powerUsageWatts,
                powerTrendWatts: row.powerTrendWatts,
                powerImpact: row.powerImpact,
                trend: row.trend,
                threadCount: row.threadCount,
                openFiles: row.openFiles
            )
        }
        currentUserAppRows = rows
        currentUserSection = UserPageSectionData(userName: NSFullUserName(), rows: rows)
    }

    private func refreshDetailProcessRows(rowsByPID: [Int32: ProcessRowData], snapshotsByPID: [Int32: ProcessSnapshot]) {
        detailProcessRows = snapshotsByPID.values.map { info in
            let cpu = rowsByPID[info.pid]?.cpuPercent ?? processCPUDisplayPercent(pid: info.pid, totalCPUTime: info.totalCPUTime)
            return DetailProcessRowData(
                id: info.pid,
                name: info.displayName,
                icon: iconForProcess(path: info.path),
                pid: info.pid,
                status: processStatusText(info.bsdStatus),
                userName: userName(for: info.uid),
                cpuPercent: cpu,
                memoryBytes: info.residentSize,
                platform: processPlatform(flags: info.flags, processCPUType: info.processCPUType)
            )
        }
        .sorted { $0.memoryBytes > $1.memoryBytes }
    }

    private func currentUserRunningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated else { return false }
            guard app.activationPolicy == .regular else { return false }
            if let path = app.bundleURL?.path, path.contains("MacOS-TSKMGR/.build") {
                return false
            }
            return true
        }
    }

    private func refreshStartupItems() {
        if startupRows.isEmpty {
            scheduleStartupRefresh(ifNeededAt: Date(), force: true)
        }
    }

    func refreshDisabledLaunchdState() {
        scheduleStartupRefresh(ifNeededAt: Date(), force: true)
    }

    func disabledLaunchdLabels(domain: String) -> Set<String> {
        disabledLaunchdByGroup[domain] ?? []
    }

    func clearAppHistory() {
        let apps = frontWindowApplications()
        let networkTotals = processNetworkTotals
        let meteredNetworkTotals = meteredProcessNetworkTotals

        var cpuBaseline: [Int32: Double] = [:]
        var networkBaseline: [Int32: UInt64] = [:]
        var meteredBaseline: [Int32: UInt64] = [:]

        for app in apps {
            let pid = app.processIdentifier
            cpuBaseline[pid] = processCPUSeconds(pid: pid)
            networkBaseline[pid] = networkTotals[pid] ?? 0
            meteredBaseline[pid] = meteredNetworkTotals[pid] ?? 0
        }

        appHistoryCPUBaseline = cpuBaseline
        appHistoryNetworkBaseline = networkBaseline
        appHistoryMeteredNetworkBaseline = meteredBaseline
        refreshAppHistory(runningApps: apps)
    }

    private func refreshNetworks(interval: TimeInterval) {
        let snapshot = networkInterfaces()
        var nextCounters: [String: (UInt64, UInt64)] = [:]
        var grouped: [String: GroupedNetworkSample] = [:]

        for item in snapshot {
            let previous = previousNetworkCounters[item.name] ?? (item.inBytes, item.outBytes)
            let receive = item.inBytes >= previous.in ? UInt64(Double(item.inBytes - previous.in) / interval) : 0
            let send = item.outBytes >= previous.out ? UInt64(Double(item.outBytes - previous.out) / interval) : 0
            nextCounters[item.name] = (item.inBytes, item.outBytes)

            if shouldHideNetworkInterface(item, send: send, receive: receive) {
                continue
            }

            if grouped[item.groupKey] == nil {
                grouped[item.groupKey] = GroupedNetworkSample(representative: item, send: send, receive: receive)
            } else {
                grouped[item.groupKey]?.send += send
                grouped[item.groupKey]?.receive += receive
                if shouldPreferNetworkRepresentative(candidate: item, over: grouped[item.groupKey]!.representative, send: send, receive: receive) {
                    grouped[item.groupKey]?.representative = item
                }
            }
        }

        previousNetworkCounters = nextCounters

        let updated = grouped.values.map { sample -> NetworkState in
            let id = sample.representative.groupKey
            let combined = Double(sample.receive + sample.send)
            let previousState = networks.first(where: { $0.id == id })
            let chartCeiling = smoothedDynamicCeiling(
                previous: previousState?.chartCeilingBytesPerSecond ?? 0,
                latest: combined,
                minimum: 64 * 1024
            )
            var sidebarHistory = previousState?.totalHistory ?? Array(repeating: 0, count: 60)
            sidebarHistory = shifted(sidebarHistory, adding: min(combined / chartCeiling * 100.0, 100.0))
            var detailHistory = previousState?.detailHistory ?? Array(repeating: 0, count: 60)
            detailHistory = shifted(detailHistory, adding: combined)
            var sendHistory = previousState?.sendHistory ?? Array(repeating: 0, count: 60)
            sendHistory = shifted(sendHistory, adding: Double(sample.send))
            var receiveHistory = previousState?.receiveHistory ?? Array(repeating: 0, count: 60)
            receiveHistory = shifted(receiveHistory, adding: Double(sample.receive))

            return NetworkState(
                id: id,
                displayName: sample.representative.displayName,
                subtitle: sample.representative.medium,
                interfaceName: sample.representative.name,
                ipv4: sample.representative.ipv4,
                ipv6: sample.representative.ipv6,
                sendBytesPerSecond: sample.send,
                receiveBytesPerSecond: sample.receive,
                totalSendBytes: sample.representative.outBytes,
                totalReceiveBytes: sample.representative.inBytes,
                packetsSent: sample.representative.packetsOut,
                packetsReceived: sample.representative.packetsIn,
                multicastSent: sample.representative.multicastOut,
                multicastReceived: sample.representative.multicastIn,
                errorsIn: sample.representative.errorsIn,
                errorsOut: sample.representative.errorsOut,
                dropsIn: sample.representative.dropsIn,
                dropsOut: sample.representative.dropsOut,
                mtu: sample.representative.mtu,
                linkSpeedBitsPerSecond: sample.representative.lineSpeedBitsPerSecond,
                linkSpeedText: networkLinkSpeedText(for: sample.representative),
                statusText: networkStatusText(for: sample.representative),
                totalHistory: sidebarHistory,
                detailHistory: detailHistory,
                sendHistory: sendHistory,
                receiveHistory: receiveHistory,
                chartCeilingBytesPerSecond: chartCeiling
            )
        }

        networks = updated.sorted {
            if $0.id == $1.id { return false }
            let lhs = networkSortOrder(for: $0.id)
            let rhs = networkSortOrder(for: $1.id)
            if lhs != rhs { return lhs < rhs }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    private func refreshDisks(interval: TimeInterval) {
        let previousStates = Dictionary(disks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let meta = diskMetadata()
        var updated: [DiskState] = []
        var nextCounters: [String: (read: UInt64, write: UInt64, readOps: UInt64, writeOps: UInt64, readTimeNs: UInt64, writeTimeNs: UInt64)] = [:]

        for item in meta {
            let previousCounter = previousDiskCounters[item.id] ?? item.counters
            let readDelta = item.counters.read >= previousCounter.read ? item.counters.read - previousCounter.read : 0
            let writeDelta = item.counters.write >= previousCounter.write ? item.counters.write - previousCounter.write : 0
            let readOpsDelta = item.counters.readOps >= previousCounter.readOps ? item.counters.readOps - previousCounter.readOps : 0
            let writeOpsDelta = item.counters.writeOps >= previousCounter.writeOps ? item.counters.writeOps - previousCounter.writeOps : 0
            let readTimeDelta = item.counters.readTimeNs >= previousCounter.readTimeNs ? item.counters.readTimeNs - previousCounter.readTimeNs : 0
            let writeTimeDelta = item.counters.writeTimeNs >= previousCounter.writeTimeNs ? item.counters.writeTimeNs - previousCounter.writeTimeNs : 0
            nextCounters[item.id] = item.counters

            let readPerSec = UInt64(Double(readDelta) / interval)
            let writePerSec = UInt64(Double(writeDelta) / interval)
            let throughput = readPerSec + writePerSec
            let activityPercent = min(Double(throughput) / 4_000_000 * 100, 100)
            let totalOps = readOpsDelta + writeOpsDelta
            let totalTime = readTimeDelta + writeTimeDelta
            let responseMs = totalOps > 0 ? Double(totalTime) / Double(totalOps) / 1_000_000 : 0

            var history = previousStates[item.id]?.activityHistory ?? Array(repeating: 0, count: 60)
            history = shifted(history, adding: activityPercent)
            var readHistory = previousStates[item.id]?.readHistory ?? Array(repeating: 0, count: 60)
            readHistory = shifted(readHistory, adding: Double(readPerSec))
            var writeHistory = previousStates[item.id]?.writeHistory ?? Array(repeating: 0, count: 60)
            writeHistory = shifted(writeHistory, adding: Double(writePerSec))
            var transferHistory = previousStates[item.id]?.transferHistory ?? Array(repeating: 0, count: 60)
            transferHistory = shifted(transferHistory, adding: Double(throughput))
            let transferCeiling = smoothedDynamicCeiling(
                previous: previousStates[item.id]?.transferChartCeilingBytesPerSecond ?? 0,
                latest: Double(throughput),
                minimum: 64 * 1024
            )

            updated.append(DiskState(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                kindLabel: item.kind,
                modelName: item.model,
                capacityBytes: item.capacityBytes,
                availableBytes: item.availableBytes,
                isSystemDisk: item.isSystemDisk,
                hasDetailedMetadata: item.hasDetailedMetadata,
                activityPercent: activityPercent,
                responseTimeMs: responseMs,
                readBytesPerSecond: readPerSec,
                writeBytesPerSecond: writePerSec,
                activityHistory: history,
                readHistory: readHistory,
                writeHistory: writeHistory,
                transferHistory: transferHistory,
                transferChartCeilingBytesPerSecond: transferCeiling
            ))
        }

        previousDiskCounters = nextCounters
        disks = updated.sorted { $0.id < $1.id }
    }

    private func refreshThermal(interval: TimeInterval) {
        lastThermalRefreshDate = Date()
        var nextThermal = thermal
        let snapshot = collectThermalSnapshot()
        let fanRPM = snapshot.currentFanRPM
        nextThermal.currentFanRPM = fanRPM
        nextThermal.peakFanRPM = max(nextThermal.peakFanRPM, fanRPM)
        nextThermal.maximumFanRPM = snapshot.maximumFanRPM
        nextThermal.cpuTemperatureCelsius = snapshot.cpuTemperatureCelsius
        nextThermal.efficiencyCoreTemperatureCelsius = snapshot.efficiencyCoreTemperatureCelsius
        nextThermal.performanceCoreTemperatureCelsius = snapshot.performanceCoreTemperatureCelsius
        nextThermal.gpuTemperatureCelsius = snapshot.gpuTemperatureCelsius
        nextThermal.diskTemperatureCelsius = snapshot.diskTemperatureCelsius
        nextThermal.networkTemperatureCelsius = snapshot.networkTemperatureCelsius
        nextThermal.logicBoardTemperatureCelsius = snapshot.logicBoardTemperatureCelsius
        nextThermal.socTemperatureCelsius = snapshot.socTemperatureCelsius
        nextThermal.powerSupplyTemperatureCelsius = snapshot.powerSupplyTemperatureCelsius
        nextThermal.powerSurfaceTemperatureCelsius = snapshot.powerSurfaceTemperatureCelsius
        nextThermal.enclosureTemperatureCelsius = snapshot.enclosureTemperatureCelsius
        nextThermal.systemTemperatureCelsius = snapshot.systemTemperatureCelsius
        nextThermal.subtitle = thermalSubtitle(from: snapshot)
        nextThermal.statusText = thermalStatusText(
            currentFanRPM: fanRPM,
            systemTemperatureCelsius: snapshot.systemTemperatureCelsius,
            cpuTemperatureCelsius: snapshot.cpuTemperatureCelsius,
            gpuTemperatureCelsius: snapshot.gpuTemperatureCelsius
        )
        nextThermal.historyFanRPM = shifted(nextThermal.historyFanRPM, adding: Double(fanRPM))
        nextThermal.fanChartCeilingRPM = Double(max(snapshot.maximumFanRPM, 1000))
        nextThermal.historyNetworkTemperatureCelsius = shifted(
            nextThermal.historyNetworkTemperatureCelsius,
            adding: snapshot.networkTemperatureCelsius ?? 0
        )
        if let networkTemperature = snapshot.networkTemperatureCelsius {
            nextThermal.networkTemperatureChartCeilingCelsius = smoothedDynamicCeiling(
                previous: nextThermal.networkTemperatureChartCeilingCelsius,
                latest: networkTemperature,
                minimum: 40
            )
        }
        thermal = nextThermal
    }

    private func cpuDetail() -> PerformanceDetailViewData {
        var rightPairs: [InfoPair] = [
            .init(label: language.text("插槽", "Sockets"), value: "\(sysctlInt("hw.packages") ?? 1)"),
            .init(label: language.text("内核", "Cores"), value: "\(cpu.physicalCores)"),
            .init(label: language.text("逻辑处理器", "Logical processors"), value: "\(cpu.logicalCores)"),
            .init(label: language.text("虚拟化", "Virtualization"), value: virtualizationStatusText())
        ]
        if cpu.performanceCoreSpeedText != "--" || cpu.efficiencyCoreSpeedText != "--" {
            if cpu.performanceCoreSpeedText != "--" {
                rightPairs.insert(.init(label: primaryCoreSpeedLabel(), value: cpu.performanceCoreSpeedText), at: 0)
            }
            if cpu.efficiencyCoreSpeedText != "--" {
                rightPairs.insert(.init(label: secondaryCoreSpeedLabel(), value: cpu.efficiencyCoreSpeedText), at: min(1, rightPairs.count))
            }
        } else if cpu.baseSpeedText != "--" {
            rightPairs.insert(.init(label: language.text("基准速度", "Base speed"), value: cpu.baseSpeedText), at: 0)
        }
        switch cpuArchitecture {
        case .appleSilicon:
            rightPairs.append(contentsOf: localizedCachePairs(appleCachePairs))
        case .intelLike:
            rightPairs.append(contentsOf: localizedCachePairs(legacyCachePairs))
        case .unknown:
            if !appleCachePairs.isEmpty {
                rightPairs.append(contentsOf: localizedCachePairs(appleCachePairs))
            } else {
                rightPairs.append(contentsOf: localizedCachePairs(legacyCachePairs))
            }
        }

        return PerformanceDetailViewData(
            title: "CPU",
            topRight: cpu.modelName,
            ceilingLabel: "100%",
            chartCeiling: 100,
            primaryLabel: language.text("60 秒内的利用率 %", "% utilization over 60 seconds"),
            accent: Color(red: 0.11, green: 0.55, blue: 0.95),
            chartSets: cpuGridHistories(),
            lowerChart: nil,
            lowerChartValueCeiling: nil,
            lowerChartCeiling: nil,
            lowerLabel: nil,
            leftMetrics: [
                .init(label: language.text("利用率", "Utilization"), value: DisplayFormat.percent(cpu.utilizationPercent), prominent: true),
                .init(label: language.text("速度", "Speed"), value: cpu.speedText, prominent: true),
                .init(label: language.text("进程", "Processes"), value: "\(cpu.processCount)"),
                .init(label: language.text("线程", "Threads"), value: "\(cpu.threadCount)"),
                .init(label: language.text("句柄", "Handles"), value: "\(cpu.openFilesCount)"),
                .init(label: language.text("正常运行时间", "Up time"), value: cpu.uptimeText)
            ],
            rightPairs: rightPairs,
            memoryComposition: false
        )
    }

    private func primaryCoreSpeedLabel() -> String {
        let label = cpu.coreTierMode.primaryDisplayName(in: language)
        return language.text("\(label)基准速度", "\(label) base speed")
    }

    private func secondaryCoreSpeedLabel() -> String {
        let label = cpu.coreTierMode.secondaryDisplayName(in: language) ?? cpu.coreTierMode.primaryDisplayName(in: language)
        return language.text("\(label)基准速度", "\(label) base speed")
    }

    private func primaryCoreTemperatureLabel() -> String {
        let label = cpu.coreTierMode.primaryDisplayName(in: language)
        return language.text("\(label)温度", "\(label) temperature")
    }

    private func secondaryCoreTemperatureLabel() -> String {
        let label = cpu.coreTierMode.secondaryDisplayName(in: language) ?? cpu.coreTierMode.primaryDisplayName(in: language)
        return language.text("\(label)温度", "\(label) temperature")
    }

    private func virtualizationStatusText() -> String {
        let supported = sysctlInt("kern.hv_support") ?? sysctlInt("kern.hv.supported") ?? 0
        guard supported == 1 else {
            return language.text("不支持", "Not supported")
        }

        let disabled = sysctlInt("kern.hv_disable") ?? 0
        if disabled != 0 {
            return language.text("已禁用", "Disabled")
        }
        return language.text("支持", "Supported")
    }

    private func localizedCachePairs(_ pairs: [InfoPair]) -> [InfoPair] {
        pairs.map { pair in
            InfoPair(label: localizedCacheLabel(pair.label), value: pair.value)
        }
    }

    private func localizedCacheLabel(_ label: String) -> String {
        switch label {
        case "L1 指令缓存", "L1 instruction cache":
            return language.text("L1 指令缓存", "L1 instruction cache")
        case "L1 数据缓存", "L1 data cache":
            return language.text("L1 数据缓存", "L1 data cache")
        case "L1 缓存", "L1 cache":
            return language.text("L1 缓存", "L1 cache")
        case "L2 缓存", "L2 cache":
            return language.text("L2 缓存", "L2 cache")
        case "L3 缓存", "L3 cache":
            return language.text("L3 缓存", "L3 cache")
        default:
            return label
        }
    }

    private func memoryDetail() -> PerformanceDetailViewData {
        PerformanceDetailViewData(
            title: language.text("内存", "Memory"),
            topRight: DisplayFormat.memory(memory.totalBytes),
            ceilingLabel: DisplayFormat.memory(memory.totalBytes),
            chartCeiling: Double(max(memory.totalBytes, 1)),
            primaryLabel: language.text("内存使用量", "Memory usage"),
            accent: Color(red: 0.72, green: 0.19, blue: 0.92),
            chartSets: [memory.historyUsedBytes],
            lowerChart: nil,
            lowerChartValueCeiling: nil,
            lowerChartCeiling: nil,
            lowerLabel: nil,
            leftMetrics: [
                .init(label: language.text("物理内存", "Physical memory"), value: DisplayFormat.memory(memory.totalBytes)),
                .init(label: language.text("已使用内存", "In use"), value: DisplayFormat.memory(memory.usedBytes)),
                .init(label: language.text("已缓存文件", "Cached files"), value: DisplayFormat.memory(memory.cachedBytes)),
                .init(label: language.text("已使用的交换", "Swap used"), value: DisplayFormat.memory(memory.swapUsedBytes))
            ],
            rightPairs: [
                .init(label: language.text("App 内存", "App memory"), value: DisplayFormat.memory(memory.appMemoryBytes)),
                .init(label: language.text("联动内存", "Wired memory"), value: DisplayFormat.memory(memory.wiredBytes)),
                .init(label: language.text("被压缩", "Compressed"), value: DisplayFormat.memory(memory.compressedBytes))
            ],
            memoryComposition: true
        )
    }

    private func diskDetail(_ disk: DiskState) -> PerformanceDetailViewData {
        let diskKind = diskKindDisplayText(disk.kindLabel)
        return PerformanceDetailViewData(
            title: disk.title,
            topRight: disk.modelName,
            ceilingLabel: "100%",
            chartCeiling: 100,
            primaryLabel: language.text("活动时间", "Active time"),
            accent: Color(red: 0.44, green: 0.77, blue: 0.10),
            chartSets: [disk.activityHistory],
            lowerChart: disk.transferHistory,
            lowerChartValueCeiling: max(disk.transferChartCeilingBytesPerSecond, 1),
            lowerChartCeiling: DisplayFormat.throughput(UInt64(max(disk.transferChartCeilingBytesPerSecond, 1))),
            lowerLabel: language.text("磁盘传输速率（读/写）", "Disk transfer rate (read/write)"),
            leftMetrics: [
                .init(label: language.text("活动时间", "Active time"), value: DisplayFormat.percentWithPrecision(disk.activityPercent, digits: 0), prominent: true),
                .init(label: language.text("平均响应时间", "Avg. response"), value: String(format: "%.1f %@", disk.responseTimeMs, language.text("毫秒", "ms")), prominent: true),
                .init(label: language.text("读取速度", "Read speed"), value: DisplayFormat.throughput(disk.readBytesPerSecond), prominent: true),
                .init(label: language.text("写入速度", "Write speed"), value: DisplayFormat.throughput(disk.writeBytesPerSecond), prominent: true)
            ],
            rightPairs: [
                .init(label: language.text("容量", "Capacity"), value: DisplayFormat.decimalBytes(disk.capacityBytes)),
                .init(label: language.text("可用", "Available"), value: diskAvailableText(disk)),
                .init(label: language.text("系统磁盘", "System disk"), value: disk.isSystemDisk ? language.text("是", "Yes") : language.text("否", "No")),
                .init(label: language.text("类型", "Type"), value: diskKind),
                .init(label: language.text("卷标", "Label"), value: diskLabelText(disk))
            ],
            memoryComposition: false
        )
    }

    private func diskAvailableText(_ disk: DiskState) -> String {
        guard disk.hasDetailedMetadata else { return "--" }
        if disk.availableBytes == 0 && disk.subtitle.isEmpty {
            return "--"
        }
        return DisplayFormat.decimalBytes(disk.availableBytes)
    }

    private func diskLabelText(_ disk: DiskState) -> String {
        guard disk.hasDetailedMetadata, !disk.subtitle.isEmpty else { return "--" }
        return disk.subtitle
    }

    private func networkDetail(_ network: NetworkState) -> PerformanceDetailViewData {
        let connectionType = language.isChinese && network.subtitle == "Wi-Fi"
            ? "WLAN"
            : language.localizeNetworkMedium(network.subtitle)
        return PerformanceDetailViewData(
            title: network.displayName,
            topRight: network.interfaceName,
            ceilingLabel: DisplayFormat.networkRate(UInt64(max(network.chartCeilingBytesPerSecond, 1))),
            chartCeiling: max(network.chartCeilingBytesPerSecond, 1),
            primaryLabel: language.text("吞吐量", "Throughput"),
            accent: Color(red: 0.85, green: 0.46, blue: 0.08),
            chartSets: [network.detailHistory],
            lowerChart: nil,
            lowerChartValueCeiling: nil,
            lowerChartCeiling: nil,
            lowerLabel: nil,
            leftMetrics: [
                .init(label: language.text("发送", "Send"), value: DisplayFormat.networkRate(network.sendBytesPerSecond), prominent: true),
                .init(label: language.text("接收", "Receive"), value: DisplayFormat.networkRate(network.receiveBytesPerSecond), prominent: true)
            ],
            rightPairs: [
                .init(label: language.text("适配器名称", "Adapter name"), value: network.displayName),
                .init(label: language.text("连接类型", "Connection type"), value: connectionType),
                .init(label: language.text("IPv4 地址", "IPv4 address"), value: network.ipv4.isEmpty ? "--" : network.ipv4),
                .init(label: language.text("IPv6 地址", "IPv6 address"), value: network.ipv6.isEmpty ? "--" : network.ipv6)
            ],
            memoryComposition: false
        )
    }

    private func diskKindDisplayText(_ rawKind: String) -> String {
        if rawKind == "SSD" || rawKind == "HDD" {
            return rawKind
        }
        return language.localizeDiskKind(rawKind)
    }

    private func npuDetail(_ npu: NPUState) -> PerformanceDetailViewData {
        let totalMemory = max(memory.totalBytes, 1)
        return PerformanceDetailViewData(
            title: npu.title,
            topRight: npu.modelName,
            ceilingLabel: "100%",
            chartCeiling: 100,
            primaryLabel: "",
            accent: Color(red: 0.96, green: 0.26, blue: 0.26),
            chartSets: [npu.historyActiveTime],
            lowerChart: npu.historyFootprint,
            lowerChartValueCeiling: Double(totalMemory),
            lowerChartCeiling: DisplayFormat.memory(totalMemory),
            lowerLabel: language.text("共享内存", "Shared memory"),
            leftMetrics: [
                .init(label: language.text("活跃度", "Activity"), value: DisplayFormat.percent(npu.activeTimePercent), prominent: true),
                .init(label: language.text("功耗", "Power"), value: DisplayFormat.watts(npu.peakPowerWatts), prominent: true),
                .init(label: language.text("共享内存", "Shared memory"), value: "\(DisplayFormat.memory(npu.neuralFootprintBytes))/\(DisplayFormat.memory(totalMemory))", prominent: true),
                .init(label: language.text("读取搬运", "Read movement"), value: DisplayFormat.throughput(npu.dataReadBytesPerSecond)),
                .init(label: language.text("写入搬运", "Write movement"), value: DisplayFormat.throughput(npu.dataWriteBytesPerSecond))
            ],
            rightPairs: [
                .init(label: language.text("NPU 个数", "NPU count"), value: "\(npu.npuCount)"),
                .init(label: language.text("NPU 核心数", "NPU cores"), value: "\(npu.coreCount)"),
                .init(label: language.text("ANE 架构", "ANE architecture"), value: npu.architecture),
                .init(label: language.text("固件已加载", "Firmware loaded"), value: language.text(npu.firmwareLoaded ? "是" : "否", npu.firmwareLoaded ? "Yes" : "No")),
                .init(label: language.text("活跃客户端数", "Active clients"), value: "\(npu.activeClientCount)"),
                .init(label: language.text("引擎类型", "Engine type"), value: "Apple Neural Engine")
            ],
            memoryComposition: false
        )
    }

    private func thermalDetail() -> PerformanceDetailViewData {
        let fanless = thermal.maximumFanRPM == 0 || thermal.currentFanRPM == 0 && thermal.peakFanRPM == 0
        let chartValues = fanless ? thermal.historyNetworkTemperatureCelsius : thermal.historyFanRPM
        let chartCeiling = fanless ? max(thermal.networkTemperatureChartCeilingCelsius, 1) : max(thermal.fanChartCeilingRPM, 1)
        let ceilingLabel = fanless
            ? thermalTemperatureText(thermal.networkTemperatureChartCeilingCelsius)
            : "\(Int(max(thermal.fanChartCeilingRPM, 1))) RPM"
        let topRight = fanless
            ? "Airport Wireless"
            : language.text("风扇#1", "Fan #1")
        let primaryLabel = fanless
            ? language.text("网卡温度", "Network temperature")
            : language.text("风扇转速", "Fan speed")
        return PerformanceDetailViewData(
            title: language.text("散热", "Cooling"),
            topRight: topRight,
            ceilingLabel: ceilingLabel,
            chartCeiling: chartCeiling,
            primaryLabel: primaryLabel,
            accent: Color(red: 0.33, green: 0.73, blue: 0.25),
            chartSets: [chartValues],
            lowerChart: nil,
            lowerChartValueCeiling: nil,
            lowerChartCeiling: nil,
            lowerLabel: nil,
            leftMetrics: [
                .init(label: language.text("CPU 温度", "CPU temperature"), value: thermalTemperatureText(thermal.cpuTemperatureCelsius), prominent: true),
                .init(label: secondaryCoreTemperatureLabel(), value: thermalTemperatureText(thermal.efficiencyCoreTemperatureCelsius), prominent: true),
                .init(label: primaryCoreTemperatureLabel(), value: thermalTemperatureText(thermal.performanceCoreTemperatureCelsius), prominent: true),
                .init(label: language.text("GPU 温度", "GPU temperature"), value: thermalTemperatureText(thermal.gpuTemperatureCelsius), prominent: true),
                .init(label: language.text("磁盘温度", "Disk temperature"), value: thermalTemperatureText(thermal.diskTemperatureCelsius), prominent: true),
                .init(label: language.text("网卡温度", "Network temperature"), value: thermalTemperatureText(thermal.networkTemperatureCelsius), prominent: true),
                .init(label: language.text("整机温度", "System temperature"), value: thermalTemperatureText(thermal.systemTemperatureCelsius), prominent: true)
            ],
            rightPairs: [
                .init(label: language.text("风扇转速", "Fan speed"), value: "\(thermal.currentFanRPM) RPM"),
                .init(label: language.text("机器热度评估", "Thermal evaluation"), value: thermal.statusText),
                .init(label: language.text("主板温度", "Logic board temperature"), value: thermalTemperatureText(thermal.logicBoardTemperatureCelsius)),
                .init(label: language.text("SoC 温度", "SoC temperature"), value: thermalTemperatureText(thermal.socTemperatureCelsius)),
                .init(label: language.text("交流/直流", "AC/DC"), value: thermalTemperatureText(thermal.powerSupplyTemperatureCelsius)),
                .init(label: language.text("电源表面", "Power surface"), value: thermalTemperatureText(thermal.powerSurfaceTemperatureCelsius)),
                .init(label: language.text("外壳温度", "Enclosure temperature"), value: thermalTemperatureText(thermal.enclosureTemperatureCelsius))
            ],
            memoryComposition: false
        )
    }

    private func gpuDetail(_ gpu: GPUState) -> PerformanceDetailViewData {
        var rightPairs: [InfoPair] = [
            .init(label: language.text("GPU 个数", "GPU count"), value: "\(gpu.gpuCount)"),
            .init(label: language.text("GPU 类型", "GPU type"), value: gpu.gpuType),
            .init(label: language.text("GPU 核心", "GPU cores"), value: "\(gpu.coreCount)")
        ]
        if gpu.supportsEngineBreakdown {
            rightPairs.append(.init(label: language.text("3D 引擎", "3D engine"), value: DisplayFormat.percent(gpu.rendererUtilizationPercent)))
            rightPairs.append(.init(label: "Tiler", value: DisplayFormat.percent(gpu.tilerUtilizationPercent)))
        }
        rightPairs.append(.init(label: language.text("Metal 版本", "Metal version"), value: gpu.metalVersion))
        if let openGLVersion = gpu.openGLVersion, !openGLVersion.isEmpty {
            rightPairs.append(.init(label: language.text("OpenGL 版本", "OpenGL version"), value: openGLVersion))
        }

        let usesDedicatedMemory = gpu.dedicatedMemoryTotalBytes > 0
        let gpuMemoryLabel = usesDedicatedMemory
            ? language.text("专用 GPU 内存", "Dedicated GPU memory")
            : language.text("共享 GPU 内存", "Shared GPU memory")
        let gpuMemoryUsed = usesDedicatedMemory ? gpu.dedicatedMemoryUsedBytes : gpu.sharedMemoryUsedBytes
        let gpuMemoryTotal = max(usesDedicatedMemory ? gpu.dedicatedMemoryTotalBytes : gpu.sharedMemoryAllocatedBytes, 1)
        var leftMetrics: [DetailMetric] = [
            .init(label: language.text("利用率", "Utilization"), value: DisplayFormat.percent(gpu.utilizationPercent), prominent: true),
            .init(label: gpuMemoryLabel, value: "\(DisplayFormat.memory(gpuMemoryUsed))/\(DisplayFormat.memory(gpuMemoryTotal))", prominent: true),
            .init(label: language.text("GPU 内存", "GPU memory"), value: DisplayFormat.memory(gpuMemoryUsed))
        ]
        if usesDedicatedMemory, gpu.sharedMemoryAllocatedBytes > 0 {
            leftMetrics.append(.init(
                label: language.text("共享 GPU 内存", "Shared GPU memory"),
                value: "\(DisplayFormat.memory(gpu.sharedMemoryUsedBytes))/\(DisplayFormat.memory(gpu.sharedMemoryAllocatedBytes))"
            ))
        }

        return PerformanceDetailViewData(
            title: gpu.title,
            topRight: gpu.modelName,
            ceilingLabel: "100%",
            chartCeiling: 100,
            primaryLabel: "",
            accent: Color(red: 0.68, green: 0.32, blue: 0.94),
            chartSets: [gpu.historyOverall, gpu.history3D, gpu.historyTiler],
            lowerChart: gpu.memoryHistory,
            lowerChartValueCeiling: 100,
            lowerChartCeiling: DisplayFormat.memory(gpuMemoryTotal),
            lowerLabel: gpuMemoryLabel,
            leftMetrics: leftMetrics,
            rightPairs: rightPairs,
            memoryComposition: false
        )
    }

    private func refreshNPUs(ifNeededAt now: Date) {
        scheduleNPURefresh(ifNeededAt: now, force: true)
    }

    private func cpuGridHistories() -> [[Double]] {
        let targetCount = max(cpu.logicalCores, 1)
        if cpu.coreHistories.count >= targetCount {
            return Array(cpu.coreHistories.prefix(targetCount))
        }
        if cpu.coreHistories.isEmpty {
            return Array(repeating: cpu.history, count: targetCount)
        }
        var result = cpu.coreHistories
        while result.count < targetCount {
            result.append(cpu.history)
        }
        return result
    }
}

struct PerformanceDetailViewData {
    let title: String
    let topRight: String
    let ceilingLabel: String
    let chartCeiling: Double
    let primaryLabel: String
    let accent: Color
    let chartSets: [[Double]]
    let lowerChart: [Double]?
    let lowerChartValueCeiling: Double?
    let lowerChartCeiling: String?
    let lowerLabel: String?
    let leftMetrics: [DetailMetric]
    let rightPairs: [InfoPair]
    let memoryComposition: Bool
}

extension SystemMonitor {
    struct ProcessSnapshot {
        let pid: Int32
        let displayName: String
        let path: String
        let residentSize: UInt64
        let totalCPUTime: UInt64
        let diskReadBytes: UInt64
        let diskWriteBytes: UInt64
        let energyNanojoules: UInt64
        let packageIdleWakeups: UInt64
        let interruptWakeups: UInt64
        let processCPUType: cpu_type_t?
        let threadCount: Int
        let openFiles: Int
        let isApplication: Bool
        let uid: uid_t
        let bsdStatus: UInt32
        let flags: UInt32
    }

    struct InterfaceSnapshot {
        let name: String
        let groupKey: String
        let displayName: String
        let medium: String
        let isPrimaryCandidate: Bool
        let ipv4: String
        let ipv6: String
        let inBytes: UInt64
        let outBytes: UInt64
        let packetsIn: UInt64
        let packetsOut: UInt64
        let multicastIn: UInt64
        let multicastOut: UInt64
        let errorsIn: UInt64
        let errorsOut: UInt64
        let dropsIn: UInt64
        let dropsOut: UInt64
        let mtu: UInt32
        let lineSpeedBitsPerSecond: UInt64
    }

    struct GroupedNetworkSample {
        var representative: InterfaceSnapshot
        var send: UInt64
        var receive: UInt64
    }

    struct DiskMeta {
        let id: String
        let title: String
        let subtitle: String
        let kind: String
        let model: String
        let capacityBytes: UInt64
        let availableBytes: UInt64
        let isSystemDisk: Bool
        let hasDetailedMetadata: Bool
        let counters: (read: UInt64, write: UInt64, readOps: UInt64, writeOps: UInt64, readTimeNs: UInt64, writeTimeNs: UInt64)
    }

    struct DiskDetailMetadata {
        let subtitle: String
        let kind: String
        let availableBytes: UInt64
        let isSystemDisk: Bool
    }

    struct LaunchdRuntimeEntry {
        let label: String
        let pid: Int32?
        let stateToken: String
        let group: String
    }

    struct LaunchdPlistMetadata {
        let label: String
        let name: String
        let icon: NSImage?
        let serviceDescription: String
        let group: String
        let disabled: Bool
    }

    struct ANEDeviceInfo {
        let modelName: String
        let npuCount: Int
        let coreCount: Int
        let capacityBytes: UInt64
        let architecture: String
        let firmwareLoaded: Bool
        let currentPowerState: Int
        let maxPowerState: Int
        let activeClientCount: Int
    }

    struct NeuralUsageTotals {
        let currentBytes: UInt64
        let intervalPeakBytes: UInt64
    }

    struct ThermalSnapshot {
        let currentFanRPM: UInt32
        let maximumFanRPM: UInt32
        let cpuTemperatureCelsius: Double?
        let efficiencyCoreTemperatureCelsius: Double?
        let performanceCoreTemperatureCelsius: Double?
        let gpuTemperatureCelsius: Double?
        let diskTemperatureCelsius: Double?
        let networkTemperatureCelsius: Double?
        let logicBoardTemperatureCelsius: Double?
        let socTemperatureCelsius: Double?
        let powerSupplyTemperatureCelsius: Double?
        let powerSurfaceTemperatureCelsius: Double?
        let enclosureTemperatureCelsius: Double?
        let systemTemperatureCelsius: Double?
    }

    func processCPUSeconds(pid: Int32) -> Double {
        guard let snapshot = processInfo(pid: pid) else { return 0 }
        return Double(snapshot.totalCPUTime) / 1_000_000_000
    }

    func formatCPUTime(_ totalSeconds: Double) -> String {
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = Int(totalSeconds) % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    func widgetExtensionMap() -> [String: Int] {
        [:]
    }

    func startupItems() -> [StartupItemRowData] {
        startupRows
    }

    func refreshServices(ifNeededAt now: Date) {
        scheduleServicesRefresh(ifNeededAt: now)
    }

    func launchAgentItems() -> [StartupItemRowData] {
        let directories = [
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            ("~/Library/LaunchAgents" as NSString).expandingTildeInPath
        ]

        var items: [StartupItemRowData] = []
        let fileManager = FileManager.default

        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".plist") {
                let path = (directory as NSString).appendingPathComponent(entry)
                guard let data = fileManager.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                else { continue }

                let label = plist["Label"] as? String ?? entry.replacingOccurrences(of: ".plist", with: "")
                let program = (plist["Program"] as? String)
                    ?? (plist["ProgramArguments"] as? [String])?.first
                    ?? ""
                let name = URL(fileURLWithPath: program).deletingPathExtension().lastPathComponent.isEmpty
                    ? label
                    : URL(fileURLWithPath: program).deletingPathExtension().lastPathComponent
                let publisher = program.isEmpty ? directoryLabel(directory) : URL(fileURLWithPath: program).deletingLastPathComponent().lastPathComponent
                let group = launchdGroupForStartupDirectory(directory)
                let labelDisabled = disabledLaunchdByGroup[group]?.contains(label) ?? false
                let plistDisabled = (plist["Disabled"] as? Bool) ?? false
                let enabled = !(plistDisabled || labelDisabled)
                let impact = directory.contains("Daemons") ? "High" : "N/A"

                items.append(
                    StartupItemRowData(
                        id: path,
                        name: name,
                        icon: startupItemIcon(fromProgramPath: program),
                        publisher: publisher,
                        status: enabled ? "Enabled" : "Disabled",
                        startupImpact: impact
                    )
                )
            }
        }

        return items
    }

    func launchdGroupForStartupDirectory(_ directory: String) -> String {
        if directory.contains("LaunchDaemons") {
            return "system"
        }
        return "gui/\(getuid())"
    }

    func directoryLabel(_ path: String) -> String {
        MonitorProbe.directoryLabel(path)
    }

    func startupItemIcon(fromProgramPath program: String) -> NSImage? {
        iconForResolvedPath(program)
    }

    func launchdRuntimeEntries(uid: uid_t) -> [LaunchdRuntimeEntry] {
        let systemEntries = parseLaunchctlPrintDomain("system", group: "system")
        let guiEntries = parseLaunchctlPrintDomain("gui/\(uid)", group: "gui/\(uid)")
        var merged: [String: LaunchdRuntimeEntry] = [:]

        for entry in systemEntries + guiEntries {
            guard shouldIncludeServiceLabel(entry.label) else { continue }
            let key = serviceCompositeKey(label: entry.label, group: entry.group)
            merged[key] = entry
        }

        return Array(merged.values)
    }

    func parseLaunchctlPrintDomain(_ domain: String, group: String) -> [LaunchdRuntimeEntry] {
        guard let data = try? Process.runAndCapture("/bin/launchctl", ["print", domain]),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }

        var result: [LaunchdRuntimeEntry] = []
        var inServicesBlock = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" {
                inServicesBlock = true
                continue
            }
            if inServicesBlock, trimmed == "}" {
                break
            }
            guard inServicesBlock else { continue }

            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }

            let label = String(parts.last!)
            guard shouldIncludeServiceLabel(label) else { continue }

            let pidToken = String(parts[0])
            let stateToken = String(parts[1])
            let pid: Int32?
            if let value = Int32(pidToken), value > 0 {
                pid = value
            } else {
                pid = nil
            }

            result.append(
                LaunchdRuntimeEntry(
                    label: label,
                    pid: pid,
                    stateToken: stateToken,
                    group: group
                )
            )
        }

        return result
    }

    func launchdPlistMetadata(uid: uid_t) -> [String: LaunchdPlistMetadata] {
        let directories = [
            "/System/Library/LaunchDaemons",
            "/System/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            ("~/Library/LaunchAgents" as NSString).expandingTildeInPath
        ]

        let fileManager = FileManager.default
        var result: [String: LaunchdPlistMetadata] = [:]

        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".plist") {
                let path = (directory as NSString).appendingPathComponent(entry)
                guard let data = fileManager.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                else {
                    continue
                }

                let label = plist["Label"] as? String ?? entry.replacingOccurrences(of: ".plist", with: "")
                guard shouldIncludeServiceLabel(label) else { continue }

                let program = (plist["Program"] as? String)
                    ?? (plist["ProgramArguments"] as? [String])?.first
                    ?? ""
                let executableName = serviceExecutableName(fromProgramPath: program)
                let name = executableName.isEmpty ? serviceNameFallback(label: label) : executableName
                let description = serviceDescriptionText(label: label, program: program, plist: plist)
                let disabled = (plist["Disabled"] as? Bool) ?? false
                let group = launchdGroup(forDirectory: directory, uid: uid)
                let key = serviceCompositeKey(label: label, group: group)

                result[key] = LaunchdPlistMetadata(
                    label: label,
                    name: name,
                    icon: startupItemIcon(fromProgramPath: program),
                    serviceDescription: description,
                    group: group,
                    disabled: disabled
                )
            }
        }

        return result
    }

    func launchdGroup(forDirectory directory: String, uid: uid_t) -> String {
        if directory.contains("LaunchDaemons") {
            return "system"
        }
        return "gui/\(uid)"
    }

    func serviceCompositeKey(label: String, group: String) -> String {
        "\(group)|\(label)"
    }

    func shouldIncludeServiceLabel(_ label: String) -> Bool {
        guard !label.isEmpty else { return false }
        if label.hasPrefix("application.") { return false }
        if label.hasPrefix("com.apple.xpc.") { return false }
        return true
    }

    func serviceExecutableName(fromProgramPath program: String) -> String {
        guard !program.isEmpty else { return "" }
        if program.hasSuffix(".app") {
            return URL(fileURLWithPath: program).deletingPathExtension().lastPathComponent
        }

        let nsPath = program as NSString
        let range = nsPath.range(of: ".app/")
        if range.location != NSNotFound, let swiftRange = Range(range, in: program) {
            let appPath = String(program[..<swiftRange.upperBound]).dropLast()
            let appName = URL(fileURLWithPath: String(appPath)).deletingPathExtension().lastPathComponent
            if !appName.isEmpty {
                return appName
            }
        }

        return URL(fileURLWithPath: program).lastPathComponent
    }

    func serviceNameFallback(label: String) -> String {
        let parts = label.split(separator: ".")
        if let last = parts.last, !last.isEmpty {
            return String(last)
        }
        return label
    }

    func serviceDescriptionText(label: String, program: String, plist: [String: Any]) -> String {
        if let bundleName = plist["CFBundleDisplayName"] as? String, !bundleName.isEmpty {
            return bundleName
        }
        if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
            return bundleName
        }
        if !program.isEmpty {
            let executable = serviceExecutableName(fromProgramPath: program)
            if !executable.isEmpty {
                return "\(label) (\(executable))"
            }
        }
        if let machServices = plist["MachServices"] as? [String: Any], !machServices.isEmpty {
            return "\(label) (Mach Service)"
        }
        return label
    }

    func serviceStatusText(pid: Int32?, stateToken: String, disabled: Bool) -> String {
        MonitorProbe.serviceStatusText(pid: pid, stateToken: stateToken, disabled: disabled)
    }

    func aneDeviceInfo() -> ANEDeviceInfo? {
        guard cpuArchitecture != .intelLike else {
            return nil
        }
        guard let data = try? Process.runAndCapture("/usr/sbin/ioreg", ["-l", "-w0"]) else {
            return nil
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        guard text.localizedCaseInsensitiveContains("ANE") else { return nil }

        let npuCount = text.localizedCaseInsensitiveContains("ANEDevicePropertyNumANEs") ? 1 : 1
        let coreCount = 16
        let modelName = "Apple Neural Engine"
        let architecture = extractFirstMatch(in: text, pattern: #"ANEDevicePropertyTypeANEArchitectureTypeStr"="([^"]+)""#) ?? "h16g"
        let firmwareLoaded = text.localizedCaseInsensitiveContains(#""FirmwareLoaded" = Yes"#) || text.localizedCaseInsensitiveContains(#""FirmwareLoaded" = true"#)
        let aneBlock = extractFirstMatch(in: text, pattern: #"(?s)\+\-o H11ANE .*?\{(.*?)\n\s*\}"#) ?? text
        let currentPowerState = Int(extractFirstMatch(in: aneBlock, pattern: #""CurrentPowerState"=([0-9]+)"#) ?? "0") ?? 0
        let maxPowerState = Int(extractFirstMatch(in: aneBlock, pattern: #""MaxPowerState"=([0-9]+)"#) ?? "1") ?? 1
        let activeClientCount = max(text.components(separatedBy: "IOUserClientCreator").count - 1, 0)
        let capacityBytes = sysctlInt("hw.memsize").map { max($0, 1_073_741_824) } ?? 1_073_741_824
        return ANEDeviceInfo(
            modelName: modelName,
            npuCount: npuCount,
            coreCount: coreCount,
            capacityBytes: capacityBytes,
            architecture: architecture,
            firmwareLoaded: firmwareLoaded,
            currentPowerState: currentPowerState,
            maxPowerState: maxPowerState,
            activeClientCount: activeClientCount
        )
    }

    func currentNeuralUsageTotals() -> NeuralUsageTotals {
        let pids = listPIDs()
        var total: UInt64 = 0
        var peak: UInt64 = 0
        for pid in pids where pid > 0 {
            var usage = rusage_info_current()
            let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
                }
            }
            if usageResult == 0 {
                total += usage.ri_neural_footprint
                peak = max(peak, usage.ri_interval_max_neural_footprint)
            }
        }
        return NeuralUsageTotals(currentBytes: total, intervalPeakBytes: peak)
    }

    func collectThermalSnapshot() -> ThermalSnapshot {
        let smc = thermalSMCReader ?? {
            let reader = SMCReader()
            thermalSMCReader = reader
            if let reader {
                let names = reader.readAllKeys()
                thermalFanActualKeys = names.filter { $0.count == 4 && $0.hasPrefix("F") && $0.hasSuffix("Ac") }.sorted()
                thermalFanMaxKeys = names.filter { $0.count == 4 && $0.hasPrefix("F") && $0.hasSuffix("Mx") }.sorted()
                thermalCPUTempKeys = names.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") || $0.hasPrefix("Ts") }.sorted()
                thermalGPUTempKeys = names.filter { $0.hasPrefix("Tg") }.sorted()
            }
            return reader
        }()
        let smcTemps = readSMCTemperatures(using: smc)
        let ioHIDTemps: (cpu: [Double], gpu: [Double]) = (smcTemps.cpu.isEmpty || smcTemps.gpu.isEmpty) ? readIOHIDTemperatures() : ([], [])
        let cpuTemperature = averageTemperature(from: smcTemps.cpu.isEmpty ? ioHIDTemps.cpu : smcTemps.cpu)
        let efficiencyCoreTemperature = averageTemperature(from: smcTemps.efficiencyCores)
        let performanceCoreTemperature = averageTemperature(from: smcTemps.performanceCores)
        let gpuTemperature = averageTemperature(from: smcTemps.gpu.isEmpty ? ioHIDTemps.gpu : smcTemps.gpu)
        let diskTemperature: Double?
        if Date().timeIntervalSince(lastThermalDiskProbeDate) >= 5 || cachedDiskTemperatureCelsius == nil {
            cachedDiskTemperatureCelsius = readDiskTemperatureCelsius()
            lastThermalDiskProbeDate = Date()
            diskTemperature = cachedDiskTemperatureCelsius
        } else {
            diskTemperature = cachedDiskTemperatureCelsius
        }
        let networkTemperature = readMappedSMCTemperature(using: smc, key: "TW0P")
        let logicBoardTemperature = readMappedSMCTemperature(using: smc, key: "TH0a") ?? readMappedSMCTemperature(using: smc, key: "TH0x")
        let socTemperature = readMappedSMCTemperature(using: smc, key: "TSCD")
        let powerSupplyTemperature = readMappedSMCTemperature(using: smc, key: "TPD0")
        let powerSurfaceTemperature = readMappedSMCTemperature(using: smc, key: "TCMb")
        let enclosureTemperature = readMappedSMCTemperature(using: smc, key: "Tm0p") ?? readMappedSMCTemperature(using: smc, key: "Tm2p")
        let systemTemperature = averageTemperature(
            from: [cpuTemperature, gpuTemperature, diskTemperature, networkTemperature, logicBoardTemperature, socTemperature, powerSupplyTemperature, enclosureTemperature].compactMap { $0 }
        )

        return ThermalSnapshot(
            currentFanRPM: readCurrentFanRPM(using: smc),
            maximumFanRPM: readMaximumFanRPM(using: smc),
            cpuTemperatureCelsius: cpuTemperature,
            efficiencyCoreTemperatureCelsius: efficiencyCoreTemperature,
            performanceCoreTemperatureCelsius: performanceCoreTemperature,
            gpuTemperatureCelsius: gpuTemperature,
            diskTemperatureCelsius: diskTemperature,
            networkTemperatureCelsius: networkTemperature,
            logicBoardTemperatureCelsius: logicBoardTemperature,
            socTemperatureCelsius: socTemperature,
            powerSupplyTemperatureCelsius: powerSupplyTemperature,
            powerSurfaceTemperatureCelsius: powerSurfaceTemperature,
            enclosureTemperatureCelsius: enclosureTemperature,
            systemTemperatureCelsius: systemTemperature
        )
    }

    private func readCurrentFanRPM(using smc: SMCReader?) -> UInt32 {
        guard let smc else { return 0 }
        let values = thermalFanActualKeys.compactMap { key -> UInt32? in
            guard let value = smc.readNumericValue(for: key) else { return nil }
            return UInt32(max(value, 0))
        }
        return values.max() ?? 0
    }

    private func readMaximumFanRPM(using smc: SMCReader?) -> UInt32 {
        guard let smc else { return 6000 }
        let values = thermalFanMaxKeys.compactMap { key -> UInt32? in
            guard let value = smc.readNumericValue(for: key) else { return nil }
            return UInt32(max(value, 0))
        }
        return values.max() ?? 6000
    }

    private func readSMCTemperatures(using smc: SMCReader?) -> (cpu: [Double], efficiencyCores: [Double], performanceCores: [Double], gpu: [Double]) {
        guard let smc else { return ([], [], [], []) }
        var cpuValues: [Double] = []
        var efficiencyCoreValues: [Double] = []
        var performanceCoreValues: [Double] = []
        var gpuValues: [Double] = []

        for name in thermalCPUTempKeys {
            guard let value = smc.readFloatValue(for: name), value > 0, value <= 150 else { continue }
            cpuValues.append(value)
            if name.hasPrefix("Te") {
                efficiencyCoreValues.append(value)
            } else if name.hasPrefix("Tp") {
                performanceCoreValues.append(value)
            }
        }
        for name in thermalGPUTempKeys {
            guard let value = smc.readFloatValue(for: name), value > 0, value <= 150 else { continue }
            gpuValues.append(value)
        }

        return (cpuValues, efficiencyCoreValues, performanceCoreValues, gpuValues)
    }

    private func readMappedSMCTemperature(using smc: SMCReader?, key: String) -> Double? {
        guard let smc else { return nil }
        guard let value = smc.readFloatValue(for: key), value > 0, value <= 150 else { return nil }
        return value
    }

    func readIOHIDTemperatures() -> (cpu: [Double], gpu: [Double]) {
        guard let system = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return ([], [])
        }
        defer { CFReleaseShim(unsafeBitCast(system, to: CFTypeRef.self)) }

        let matching = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 0x0005
        ] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(system, matching)
        guard let services = IOHIDEventSystemClientCopyServices(system)?.takeRetainedValue() else {
            return ([], [])
        }

        var cpuValues: [Double] = []
        var gpuValues: [Double] = []
        let count = CFArrayGetCount(services)
        for index in 0..<count {
            let rawService = CFArrayGetValueAtIndex(services, index)
            guard let service = UnsafeRawPointer(rawService) else { continue }
            guard let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() else { continue }
            let name = nameRef as! String
            guard let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) else { continue }
            let temp = IOHIDEventGetFloatValue(event, 15 << 16)
            CFReleaseShim(unsafeBitCast(event, to: CFTypeRef.self))
            guard temp > 0, temp <= 150 else { continue }
            if name.hasPrefix("pACC MTR Temp Sensor") || name.hasPrefix("eACC MTR Temp Sensor") {
                cpuValues.append(temp)
            } else if name.hasPrefix("GPU MTR Temp Sensor") {
                gpuValues.append(temp)
            }
        }

        return (cpuValues, gpuValues)
    }

    func readDiskTemperatureCelsius() -> Double? {
        guard let system = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return nil
        }
        defer { CFReleaseShim(unsafeBitCast(system, to: CFTypeRef.self)) }
        guard let services = IOHIDEventSystemClientCopyServices(system)?.takeRetainedValue() else {
            return nil
        }

        var values: [Double] = []
        let count = CFArrayGetCount(services)
        for index in 0..<count {
            let rawService = CFArrayGetValueAtIndex(services, index)
            guard let service = UnsafeRawPointer(rawService) else { continue }

            guard let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() else { continue }
            let name = nameRef as! String
            let lowercased = name.lowercased()
            guard lowercased.contains("temp") else { continue }
            guard lowercased.contains("nand") || lowercased.contains("ssd") || lowercased.contains("nvme") else { continue }
            guard let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) else { continue }
            let temp = IOHIDEventGetFloatValue(event, 15 << 16)
            CFReleaseShim(unsafeBitCast(event, to: CFTypeRef.self))
            guard temp > 0, temp <= 150 else { continue }
            values.append(temp)
        }

        return averageTemperature(from: values)
    }

    func averageTemperature(from values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func thermalTemperatureText(_ value: Double?) -> String {
        temperatureUnit.format(value)
    }

    func thermalSubtitle(from snapshot: ThermalSnapshot) -> String {
        language.text("温度", "Temperature") + ": " + thermalTemperatureText(snapshot.systemTemperatureCelsius)
    }

    func thermalStatusText(currentFanRPM: UInt32, systemTemperatureCelsius: Double?, cpuTemperatureCelsius: Double?, gpuTemperatureCelsius: Double?) -> String {
        let reference = max(systemTemperatureCelsius ?? 0, cpuTemperatureCelsius ?? 0, gpuTemperatureCelsius ?? 0)
        if reference >= 90 || currentFanRPM >= 5000 {
            return language.text("非常热", "Very hot")
        }
        if reference >= 80 || currentFanRPM >= 4000 {
            return language.text("热", "Hot")
        }
        if reference >= 60 || currentFanRPM >= 2500 {
            return language.text("正常", "Normal")
        }
        if reference >= 40 || currentFanRPM >= 1200 {
            return language.text("凉", "Cool")
        }
        return language.text("凉爽", "Very cool")
    }

    func thermalStatusEnglish(from value: String) -> String {
        switch value {
        case "非常热": return "Very hot"
        case "热": return "Hot"
        case "正常": return "Normal"
        case "凉": return "Cool"
        case "凉爽": return "Very cool"
        default: return value
        }
    }

    func extractFirstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    func frontWindowApplications() -> [NSRunningApplication] {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { app in
                guard !app.isTerminated else { return false }
                if let path = app.bundleURL?.path, path.contains("MacOS-TSKMGR/.build") {
                    return false
                }
                return app.activationPolicy == .regular
            }
        let appByPID = Dictionary(runningApps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { _, latest in latest })

        var orderedPIDs: [Int32] = []
        var seenPIDs = Set<Int32>()
        if let windowInfo = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for window in windowInfo {
                guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32 else { continue }
                guard appByPID[ownerPID] != nil else { continue }

                let layer = window[kCGWindowLayer as String] as? Int ?? 0
                guard layer == 0 else { continue }

                let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
                guard alpha > 0.01 else { continue }

                if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
                    let width = bounds["Width"] ?? 0
                    let height = bounds["Height"] ?? 0
                    guard width > 80, height > 60 else { continue }
                }

                if seenPIDs.insert(ownerPID).inserted {
                    orderedPIDs.append(ownerPID)
                }
            }
        }

        for app in runningApps where seenPIDs.insert(app.processIdentifier).inserted {
            orderedPIDs.append(app.processIdentifier)
        }

        return orderedPIDs.compactMap { appByPID[$0] }
    }

    func childProcessesMap(allRows: [Int32: ProcessRowData]) -> [Int32: [Int32]] {
        var result: [Int32: [Int32]] = [:]
        for pid in allRows.keys {
            let children = listChildPIDs(parentPID: pid).filter { allRows[$0] != nil }
            if !children.isEmpty {
                result[pid] = children
            }
        }
        return result
    }

    func listChildPIDs(parentPID: Int32) -> [Int32] {
        let size = proc_listchildpids(parentPID, nil, 0)
        guard size > 0 else { return [] }
        let count = size / Int32(MemoryLayout<pid_t>.size)
        var buffer = Array(repeating: pid_t(0), count: Int(count))
        let bytes = proc_listchildpids(parentPID, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return buffer.filter { $0 > 0 }
    }

    func processRowSort(_ lhs: ProcessRowData, _ rhs: ProcessRowData) -> Bool {
        if abs(lhs.cpuPercent - rhs.cpuPercent) > 0.05 {
            return lhs.cpuPercent > rhs.cpuPercent
        }
        return lhs.memoryBytes > rhs.memoryBytes
    }

    func processNetworkSnapshot(interfaceFilter: String?) -> [Int32: UInt64] {
        interfaceFilter == "expensive" ? meteredProcessNetworkTotals : processNetworkTotals
    }

    func listPIDs() -> [Int32] {
        let bufferSize = proc_listallpids(nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = bufferSize / Int32(MemoryLayout<pid_t>.size)
        var buffer = Array(repeating: pid_t(0), count: Int(count))
        let bytes = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return buffer.filter { $0 > 0 }
    }

    func processInfo(pid: Int32) -> ProcessSnapshot? {
        var taskInfo = proc_taskinfo()
        let taskResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
        guard taskResult == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }

        var bsdInfo = proc_bsdinfo()
        let bsdResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard bsdResult == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }

        var usage = rusage_info_current()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }

        let startSeconds = Int64(bsdInfo.pbi_start_tvsec)
        let startMicroseconds = Int64(bsdInfo.pbi_start_tvusec)
        let metadata: ProcessStaticMetadata
        if let cached = processStaticMetadata[pid],
           cached.startSeconds == startSeconds,
           cached.startMicroseconds == startMicroseconds {
            metadata = cached
        } else {
            var nameBuffer = Array(repeating: CChar(0), count: 256)
            let named = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let command = named > 0 ? stringFromCBuffer(nameBuffer) : stringFromCArray(&bsdInfo.pbi_name.0)
            let fallback = stringFromCArray(&bsdInfo.pbi_comm.0)
            let displayName = command.isEmpty ? fallback : command
            let path = pidPath(pid: pid)
            var archInfo = proc_archinfo()
            let archResult = proc_pidinfo(pid, PROC_PIDARCHINFO, 0, &archInfo, Int32(MemoryLayout<proc_archinfo>.size))
            let processCPUType: cpu_type_t? = archResult == Int32(MemoryLayout<proc_archinfo>.size) ? archInfo.p_cputype : nil
            let app = path.hasSuffix(".app") || path.contains("/Applications/") || path.contains("/System/Applications/")
            metadata = ProcessStaticMetadata(
                startSeconds: startSeconds,
                startMicroseconds: startMicroseconds,
                displayName: displayName,
                path: path,
                isApplication: app,
                processCPUType: processCPUType
            )
            processStaticMetadata[pid] = metadata
        }

        return ProcessSnapshot(
            pid: pid,
            displayName: metadata.displayName,
            path: metadata.path,
            residentSize: taskInfo.pti_resident_size,
            totalCPUTime: taskInfo.pti_total_user + taskInfo.pti_total_system,
            diskReadBytes: usageResult == 0 ? usage.ri_diskio_bytesread : 0,
            diskWriteBytes: usageResult == 0 ? usage.ri_diskio_byteswritten : 0,
            energyNanojoules: usageResult == 0 ? usage.ri_energy_nj : 0,
            packageIdleWakeups: usageResult == 0 ? usage.ri_pkg_idle_wkups : 0,
            interruptWakeups: usageResult == 0 ? usage.ri_interrupt_wkups : 0,
            processCPUType: metadata.processCPUType,
            threadCount: Int(taskInfo.pti_threadnum),
            openFiles: Int(bsdInfo.pbi_nfiles),
            isApplication: metadata.isApplication,
            uid: bsdInfo.pbi_uid,
            bsdStatus: bsdInfo.pbi_status,
            flags: bsdInfo.pbi_flags
        )
    }

    func processCPUDisplayPercent(pid: Int32, totalCPUTime: UInt64) -> Double {
        let previousCPU = previousProcessCPUTime[pid] ?? totalCPUTime
        let delta = totalCPUTime >= previousCPU ? totalCPUTime - previousCPU : 0
        let logicalCores = max(cpu.logicalCores, 1)
        var cpuPercent = min(max((Double(delta) / max(refreshSpeed.interval ?? 1.0, 0.5) / 1_000_000_000.0) / Double(logicalCores) * 100, 0), 999)
        if cpuPercent > 0 && cpuPercent < 0.1 {
            cpuPercent = 0.1
        }
        return cpuPercent
    }

    func processStatusText(_ status: UInt32) -> String {
        switch status {
        case UInt32(SIDL): return "Starting"
        case UInt32(SRUN): return "Running"
        case UInt32(SSLEEP): return "Sleeping"
        case UInt32(SSTOP): return "Stopped"
        case UInt32(SZOMB): return "Zombie"
        default: return "Unknown"
        }
    }

    func userName(for uid: uid_t) -> String {
        if let pw = getpwuid(uid) {
            return String(cString: pw.pointee.pw_name)
        }
        return "\(uid)"
    }

    func processPlatform(flags: UInt32, processCPUType: cpu_type_t?) -> String {
        let is64Bit = (flags & UInt32(PROC_FLAG_LP64)) != 0
        if let processCPUType {
            switch processCPUType {
            case cpu_type_t(CPU_TYPE_X86_64), cpu_type_t(CPU_TYPE_X86):
                return cpuArchitecture == .appleSilicon ? "Rosetta 2" : "x86_64"
            case cpu_type_t(CPU_TYPE_ARM64):
                return "ARM64"
            default:
                break
            }
        }

        switch cpuArchitecture {
        case .appleSilicon:
            if is64Bit {
                return "Rosetta 2"
            }
            return "ARM64"
        case .intelLike, .unknown:
            return is64Bit ? "64-bit" : "32-bit"
        }
    }

    func pidPath(pid: Int32) -> String {
        var pathBuffer = Array(repeating: CChar(0), count: pidPathInfoMaxSize)
        let result = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard result > 0 else { return "" }
        return stringFromCBuffer(pathBuffer)
    }

    func iconForProcess(path: String) -> NSImage? {
        iconForResolvedPath(path)
    }

    private func iconForResolvedPath(_ path: String) -> NSImage? {
        guard let iconPath = resolvedIconPath(from: path) else { return nil }
        let key = iconPath as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: iconPath)
        let thumbnail = resizedIcon(icon, sideLength: 16)
        iconCache.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    private func resolvedIconPath(from path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if path.hasSuffix(".app") {
            return path
        }
        let nsPath = path as NSString
        let range = nsPath.range(of: ".app/")
        if range.location != NSNotFound, let swiftRange = Range(range, in: path) {
            let appPath = String(path[..<swiftRange.upperBound]).dropLast()
            return String(appPath)
        }
        return path
    }

    private func resizedIcon(_ icon: NSImage, sideLength: CGFloat) -> NSImage {
        let targetSize = NSSize(width: sideLength, height: sideLength)
        let result = NSImage(size: targetSize)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(origin: .zero, size: targetSize),
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .copy,
                  fraction: 1)
        result.unlockFocus()
        return result
    }

    func networkInterfaces() -> [InterfaceSnapshot] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var byteCounters: [String: (UInt64, UInt64)] = [:]
        var ipv4Map: [String: String] = [:]
        var ipv6Map: [String: String] = [:]

        var current = first
        while true {
            let ifa = current.pointee
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    let existing = byteCounters[name] ?? (0, 0)
                    byteCounters[name] = (max(existing.0, UInt64(data.pointee.ifi_ibytes)), max(existing.1, UInt64(data.pointee.ifi_obytes)))
                }
                if let addr = ifa.ifa_addr {
                    let family = addr.pointee.sa_family
                    if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                        var hostBuffer = Array(repeating: CChar(0), count: Int(NI_MAXHOST))
                        let length = socklen_t(addr.pointee.sa_len)
                        let result = getnameinfo(addr, length, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
                        if result == 0 {
                            let text = stringFromCBuffer(hostBuffer)
                            if family == UInt8(AF_INET) {
                                ipv4Map[name] = text
                            } else if !text.hasPrefix("fe80") {
                                ipv6Map[name] = text
                            }
                        }
                    }
                }
            }
            guard let next = ifa.ifa_next else { break }
            current = next
        }

        return byteCounters.keys.map { name in
            let hardwarePort = hardwarePortMap[name] ?? ""
            let medium: String
            let displayName: String
            let groupKey: String

            if hardwarePort == "Wi-Fi" {
                displayName = "Wi-Fi"
                medium = "Wi-Fi"
                groupKey = "wifi"
            } else if hardwarePort.localizedCaseInsensitiveContains("Ethernet") || hardwarePort.localizedCaseInsensitiveContains("LAN") {
                displayName = "Ethernet"
                medium = hardwarePort
                groupKey = "ethernet"
            } else if name.hasPrefix("utun") {
                displayName = name
                medium = "VPN tunnel"
                groupKey = name
            } else if name.hasPrefix("bridge") || name.hasPrefix("vmenet") {
                displayName = name
                medium = "Virtual network"
                groupKey = name
            } else if name.hasPrefix("awdl") || name.hasPrefix("llw") {
                displayName = name
                medium = "Apple Wireless"
                groupKey = name
            } else {
                displayName = name
                medium = hardwarePort.isEmpty ? "Network interface" : hardwarePort
                groupKey = name
            }
            return InterfaceSnapshot(
                name: name,
                groupKey: groupKey,
                displayName: displayName,
                medium: medium,
                isPrimaryCandidate: hardwarePort == "Wi-Fi" || hardwarePort.localizedCaseInsensitiveContains("Ethernet") || hardwarePort.localizedCaseInsensitiveContains("LAN"),
                ipv4: ipv4Map[name] ?? "",
                ipv6: ipv6Map[name] ?? "",
                inBytes: byteCounters[name]?.0 ?? 0,
                outBytes: byteCounters[name]?.1 ?? 0,
                packetsIn: interfaceCounter(name: name, keyPath: \.ifi_ipackets),
                packetsOut: interfaceCounter(name: name, keyPath: \.ifi_opackets),
                multicastIn: interfaceCounter(name: name, keyPath: \.ifi_imcasts),
                multicastOut: interfaceCounter(name: name, keyPath: \.ifi_omcasts),
                errorsIn: interfaceCounter(name: name, keyPath: \.ifi_ierrors),
                errorsOut: interfaceCounter(name: name, keyPath: \.ifi_oerrors),
                dropsIn: interfaceCounter(name: name, keyPath: \.ifi_iqdrops),
                dropsOut: 0,
                mtu: interfaceMTU(name: name),
                lineSpeedBitsPerSecond: interfaceLineSpeed(name: name, medium: medium)
            )
        }
    }

    func shouldHideNetworkInterface(_ item: InterfaceSnapshot, send: UInt64, receive: UInt64) -> Bool {
        if item.name.hasPrefix("awdl") || item.name.hasPrefix("llw") || item.name.hasPrefix("anpi") || item.name.hasPrefix("ap") {
            return true
        }

        let hasAddress = !item.ipv4.isEmpty || !item.ipv6.isEmpty
        let hasTraffic = send > 0 || receive > 0

        if item.medium == "Wi-Fi" || item.medium == "以太网" || item.medium.localizedCaseInsensitiveContains("Ethernet") || item.medium.localizedCaseInsensitiveContains("LAN") {
            return !(hasAddress || hasTraffic)
        }

        if item.medium.localizedCaseInsensitiveContains("Thunderbolt") {
            return true
        }

        if item.name.hasPrefix("bridge") || item.name.hasPrefix("vmenet") {
            return true
        }

        if item.name.hasPrefix("utun") {
            return !(hasAddress || hasTraffic)
        }

        return true
    }

    func shouldPreferNetworkRepresentative(candidate: InterfaceSnapshot, over current: InterfaceSnapshot, send: UInt64, receive: UInt64) -> Bool {
        let candidateHasAddress = !candidate.ipv4.isEmpty || !candidate.ipv6.isEmpty
        let currentHasAddress = !current.ipv4.isEmpty || !current.ipv6.isEmpty
        if candidateHasAddress != currentHasAddress {
            return candidateHasAddress
        }

        let candidateTraffic = send + receive
        let currentTraffic = (previousNetworkCounters[current.name]?.0 ?? 0) + (previousNetworkCounters[current.name]?.1 ?? 0)
        if candidateTraffic != currentTraffic {
            return candidateTraffic > currentTraffic
        }

        return candidate.name.localizedStandardCompare(current.name) == .orderedAscending
    }

    func networkSortOrder(for groupKey: String) -> Int {
        if groupKey == "wifi" { return 0 }
        if groupKey == "ethernet" { return 1 }
        if groupKey.hasPrefix("utun") { return 2 }
        if groupKey.hasPrefix("bridge") || groupKey.hasPrefix("vmenet") { return 3 }
        return 4
    }

    func networkStatusText(for snapshot: InterfaceSnapshot) -> String {
        (!snapshot.ipv4.isEmpty || !snapshot.ipv6.isEmpty || snapshot.inBytes > 0 || snapshot.outBytes > 0) ? language.text("已连接", "Connected") : language.text("未连接", "Disconnected")
    }

    func networkLinkSpeedText(for snapshot: InterfaceSnapshot) -> String {
        if snapshot.lineSpeedBitsPerSecond > 0 {
            return DisplayFormat.linkSpeed(bitsPerSecond: snapshot.lineSpeedBitsPerSecond)
        }
        if snapshot.medium.localizedCaseInsensitiveContains("VPN") {
            return language.text("虚拟", "Virtual")
        }
        return snapshot.medium
    }

    func interfaceLineSpeed(name: String, medium: String) -> UInt64 {
        if medium == "Wi-Fi" {
            return wifiTransmitRateBitsPerSecond(interfaceName: name)
        }
        return interfaceBaudRate(name: name)
    }

    func interfaceBaudRate(name: String) -> UInt64 {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return 0 }
        defer { freeifaddrs(pointer) }

        var current = first
        while true {
            let ifa = current.pointee
            let currentName = String(cString: ifa.ifa_name)
            if currentName == name, let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                return UInt64(data.pointee.ifi_baudrate)
            }
            guard let next = ifa.ifa_next else { break }
            current = next
        }
        return 0
    }

    func wifiTransmitRateBitsPerSecond(interfaceName: String) -> UInt64 {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            return 0
        }
        let rateMbps = interface.transmitRate()
        guard rateMbps > 0 else { return 0 }
        return UInt64(rateMbps * 1_000_000)
    }

    func interfaceCounter(name: String, keyPath: KeyPath<if_data, UInt32>) -> UInt64 {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return 0 }
        defer { freeifaddrs(pointer) }

        var current = first
        while true {
            let ifa = current.pointee
            let currentName = String(cString: ifa.ifa_name)
            if currentName == name, let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                return UInt64(data.pointee[keyPath: keyPath])
            }
            guard let next = ifa.ifa_next else { break }
            current = next
        }
        return 0
    }

    func interfaceMTU(name: String) -> UInt32 {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return 0 }
        defer { freeifaddrs(pointer) }

        var current = first
        while true {
            let ifa = current.pointee
            let currentName = String(cString: ifa.ifa_name)
            if currentName == name, let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                return data.pointee.ifi_mtu
            }
            guard let next = ifa.ifa_next else { break }
            current = next
        }
        return 0
    }

    func currentPrimaryCPUSpeedText() -> String {
        if cpu.performanceCoreSpeedText != "--" {
            return cpu.performanceCoreSpeedText
        }
        if cpu.baseSpeedText != "--" {
            return cpu.baseSpeedText
        }
        return cpu.modelName
    }

    private func refreshGPUs(ifNeededAt now: Date) {
        scheduleGPURefresh(ifNeededAt: now, force: true)
    }

    func refreshGPUs() {
        refreshGPUs(ifNeededAt: Date())
    }

    func metalLabel(from raw: String) -> String {
        switch raw {
        case "spdisplays_metal4":
            return "Metal 4"
        case "spdisplays_metal3":
            return "Metal 3"
        case "spdisplays_metal2":
            return "Metal 2"
        default:
            return raw.isEmpty ? "Metal" : raw
        }
    }

    func diskMetadata() -> [DiskMeta] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [DiskMeta] = []
        var index = 0

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard
                let stats = registryPropertyDictionary(service, key: "Statistics"),
                let media = wholeMediaChild(of: service)
            else {
                continue
            }
            defer { IOObjectRelease(media) }

            let mediaProps = registryProperties(media)
            let deviceIdentifier = mediaProps["BSD Name"] as? String ?? ""
            guard !deviceIdentifier.isEmpty else { continue }

            let size = (mediaProps["Size"] as? NSNumber)?.uint64Value ?? 0
            let model = ioRegistryName(media).isEmpty ? deviceIdentifier : ioRegistryName(media)
            let detailedMetadata = detailedDiskMetadataCache[deviceIdentifier]
            let kind = detailedMetadata?.kind ?? {
                let resolved = diskKindCache[deviceIdentifier] ?? lightweightDiskKind(
                    mediaProps: mediaProps,
                    model: model,
                    service: service,
                    media: media
                )
                diskKindCache[deviceIdentifier] = resolved
                return resolved
            }()
            let label = detailedMetadata?.subtitle ?? ""
            let available = detailedMetadata?.availableBytes ?? 0
            let isSystemDisk = detailedMetadata?.isSystemDisk ?? (deviceIdentifier == rootWholeDiskID)

            result.append(DiskMeta(
                id: deviceIdentifier,
                title: "Disk \(index) (\(deviceIdentifier))",
                subtitle: label,
                kind: kind,
                model: model,
                capacityBytes: size,
                availableBytes: available,
                isSystemDisk: isSystemDisk,
                hasDetailedMetadata: detailedMetadata != nil,
                counters: (
                    (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0,
                    (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0,
                    (stats["Operations (Read)"] as? NSNumber)?.uint64Value ?? 0,
                    (stats["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0,
                    (stats["Total Time (Read)"] as? NSNumber)?.uint64Value ?? 0,
                    (stats["Total Time (Write)"] as? NSNumber)?.uint64Value ?? 0
                )
            ))
            index += 1
        }

        return result
    }

    private func resolveDiskKind(
        deviceIdentifier: String,
        mediaProps: [String: Any],
        model: String,
        service: io_registry_entry_t,
        media: io_registry_entry_t
    ) -> String {
        let registryHints = registryHintStrings(for: service) + registryHintStrings(for: media)

        if let info = diskutilInfo(deviceIdentifier: deviceIdentifier) {
            let isInternal = (info["Internal"] as? Bool) ?? false
            let removableExternal = (info["RemovableMediaOrExternalDevice"] as? Bool) ?? false
            let removableMedia = (info["RemovableMedia"] as? Bool) ?? false
            let ejectable = (info["Ejectable"] as? Bool) ?? false
            let busProtocol = (info["BusProtocol"] as? String) ?? ""
            let deviceTreePath = (info["DeviceTreePath"] as? String) ?? ""
            let solidState = (info["SolidState"] as? Bool) ?? model.localizedCaseInsensitiveContains("SSD")

            if !isInternal || removableExternal || removableMedia || ejectable {
                return "Removable"
            }

            return normalizedInternalDiskInterface(
                busProtocol: busProtocol,
                deviceTreePath: deviceTreePath,
                solidState: solidState,
                registryHints: registryHints
            )
        }

        let removable = (mediaProps["Removable"] as? Bool) ?? false || ((mediaProps["Ejectable"] as? Bool) ?? false)
        if removable {
            return "Removable"
        }

        if isLikelyExternalDisk(registryHints: registryHints) {
            return "Removable"
        }

        return normalizedInternalDiskInterface(
            busProtocol: "",
            deviceTreePath: "",
            solidState: model.localizedCaseInsensitiveContains("SSD"),
            registryHints: registryHints,
            fallbackLabel: "Unknown"
        )
    }

    private func lightweightDiskKind(
        mediaProps: [String: Any],
        model: String,
        service: io_registry_entry_t,
        media: io_registry_entry_t
    ) -> String {
        let removable = (mediaProps["Removable"] as? Bool) ?? false || ((mediaProps["Ejectable"] as? Bool) ?? false)
        if removable {
            return "Removable"
        }

        let registryHints = registryHintStrings(for: service) + registryHintStrings(for: media)
        if isLikelyExternalDisk(registryHints: registryHints) {
            return "Removable"
        }
        return normalizedInternalDiskInterface(
            busProtocol: "",
            deviceTreePath: "",
            solidState: model.localizedCaseInsensitiveContains("SSD"),
            registryHints: registryHints,
            fallbackLabel: "Unknown"
        )
    }

    private func diskutilInfo(deviceIdentifier: String) -> [String: Any]? {
        guard let data = try? Process.runAndCapture("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(deviceIdentifier)"]) else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    private func probeDetailedDiskMetadata(forDiskID diskID: String) -> DiskDetailMetadata? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let mountInfo = mountedDiskInfoByWholeDisk()

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let media = wholeMediaChild(of: service) else { continue }
            defer { IOObjectRelease(media) }

            let mediaProps = registryProperties(media)
            let deviceIdentifier = mediaProps["BSD Name"] as? String ?? ""
            guard deviceIdentifier == diskID else { continue }

            let model = ioRegistryName(media).isEmpty ? deviceIdentifier : ioRegistryName(media)
            let kind = resolveDiskKind(
                deviceIdentifier: deviceIdentifier,
                mediaProps: mediaProps,
                model: model,
                service: service,
                media: media
            )
            let label = mountInfo[deviceIdentifier]?.label ?? ""
            let available = mountInfo[deviceIdentifier]?.availableBytes ?? 0

            return DiskDetailMetadata(
                subtitle: label,
                kind: kind,
                availableBytes: available,
                isSystemDisk: deviceIdentifier == rootWholeDiskID
            )
        }

        return nil
    }

    private func normalizedInternalDiskInterface(
        busProtocol: String,
        deviceTreePath: String,
        solidState: Bool,
        registryHints: [String],
        fallbackLabel: String = "Internal"
    ) -> String {
        let lowerBus = busProtocol.lowercased()
        let lowerTreePath = deviceTreePath.lowercased()
        let lowerHints = registryHints.joined(separator: " ").lowercased()
        let combinedHints = [lowerBus, lowerTreePath, lowerHints]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if combinedHints.contains("ionvmefamily")
            || combinedHints.contains("nvmexpress")
            || combinedHints.contains("ioembeddednvmeblockdevice")
            || combinedHints.contains("appleembeddednvmetemperaturesensor")
            || combinedHints.contains("nvme")
            || combinedHints.contains("appleans")
            || combinedHints.contains("apple fabric")
        {
            return "NVMe"
        }
        if solidState && (combinedHints.contains("pci") || combinedHints.contains("pcie")) {
            return "NVMe"
        }
        if combinedHints.contains("sata")
            || combinedHints.contains("ata")
            || combinedHints.contains("ahci")
        {
            return "SATA"
        }
        if combinedHints.contains("ide") {
            return "IDE"
        }
        return busProtocol.isEmpty ? fallbackLabel : busProtocol
    }

    private func isLikelyExternalDisk(registryHints: [String]) -> Bool {
        let combinedHints = registryHints.joined(separator: " ").lowercased()
        let externalMarkers = [
            "external",
            "usb",
            "thunderbolt",
            "firewire",
            "sdxc",
            "sd card",
            "card reader",
            "cardreader",
            "mass storage",
            "removable",
            "portable"
        ]
        return externalMarkers.contains { combinedHints.contains($0) }
    }

    private func registryHintStrings(for entry: io_registry_entry_t, maxDepth: Int = 8) -> [String] {
        var hints: [String] = []
        var current = entry
        var depth = 0
        var releaseCurrent = false

        while current != 0, depth < maxDepth {
            hints.append(ioRegistryName(current))
            appendRegistryHintProperties(from: current, into: &hints)

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
                break
            }

            if releaseCurrent {
                IOObjectRelease(current)
            }
            current = parent
            releaseCurrent = true
            depth += 1
        }

        if releaseCurrent, current != 0 {
            IOObjectRelease(current)
        }

        return hints
    }

    private func appendRegistryHintProperties(from entry: io_registry_entry_t, into hints: inout [String]) {
        let properties = registryProperties(entry)
        let stringKeys = [
            "IOClass",
            "CFBundleIdentifier",
            "Physical Interconnect",
            "Physical Interconnect Location",
            "device-type",
            "Protocol",
            "Model Number",
            "MediaName"
        ]

        for key in stringKeys {
            if let value = properties[key] as? String, !value.isEmpty {
                hints.append(value)
            }
        }

        if let protocolCharacteristics = properties["Protocol Characteristics"] as? [String: Any] {
            if let interconnect = protocolCharacteristics["Physical Interconnect"] as? String, !interconnect.isEmpty {
                hints.append(interconnect)
            }
            if let location = protocolCharacteristics["Physical Interconnect Location"] as? String, !location.isEmpty {
                hints.append(location)
            }
        }
    }

    func wholeMediaChild(of service: io_registry_entry_t) -> io_registry_entry_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            let props = registryProperties(child)
            if let bsd = props["BSD Name"] as? String, !bsd.isEmpty, (props["Whole"] as? Bool) == true {
                return child
            }
            IOObjectRelease(child)
        }

        return nil
    }

    func registryProperties(_ entry: io_registry_entry_t) -> [String: Any] {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else {
            return [:]
        }
        return dictionary
    }

    func registryPropertyDictionary(_ entry: io_registry_entry_t, key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }

    func ioRegistryName(_ entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { return "" }
        return stringFromCBuffer(name)
    }

    func detectRootWholeDiskIdentifier() -> String? {
        if let data = try? Process.runAndCapture("/usr/sbin/diskutil", ["info", "-plist", "/"]),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        {
            if let physicalStores = plist["APFSPhysicalStores"] as? [[String: Any]] {
                for store in physicalStores {
                    if let physicalStore = store["APFSPhysicalStore"] as? String ?? store["DeviceIdentifier"] as? String,
                       let wholeDisk = wholeDiskIdentifier(fromDevicePath: "/dev/\(physicalStore)")
                    {
                        return wholeDisk
                    }
                }
            }

            if let parentWholeDisk = plist["ParentWholeDisk"] as? String,
               let wholeDisk = wholeDiskIdentifier(fromDevicePath: "/dev/\(parentWholeDisk)")
            {
                return wholeDisk
            }
        }

        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let source = withUnsafePointer(to: &stats.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { pointer in
                String(cString: pointer)
            }
        }
        return wholeDiskIdentifier(fromDevicePath: source)
    }

    func loadHardwarePortMap() -> [String: String] {
        guard let data = try? Process.runAndCapture("/usr/sbin/networksetup", ["-listallhardwareports"]),
              let text = String(data: data, encoding: .utf8)
        else {
            return [:]
        }

        var result: [String: String] = [:]
        var currentPort: String?

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("Hardware Port:") {
                currentPort = line.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:"), let currentPort {
                let device = line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                if !device.isEmpty {
                    result[device] = currentPort
                }
            }
        }

        return result
    }

    func mountedDiskInfoByWholeDisk() -> [String: (availableBytes: UInt64, label: String)] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeNameKey, .volumeAvailableCapacityKey]
        let urls = manager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var result: [String: (availableBytes: UInt64, label: String)] = [:]

        for url in urls {
            var stats = statfs()
            guard statfs(url.path, &stats) == 0 else { continue }
            let source = withUnsafePointer(to: &stats.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { pointer in
                    String(cString: pointer)
                }
            }
            guard let wholeDisk = wholeDiskIdentifier(fromDevicePath: source) else { continue }

            let values = try? url.resourceValues(forKeys: keys)
            let label = values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent
            let available = UInt64(values?.volumeAvailableCapacity ?? 0)

            if var existing = result[wholeDisk] {
                existing.availableBytes += available
                if existing.label == wholeDisk {
                    existing.label = label
                }
                result[wholeDisk] = existing
            } else {
                result[wholeDisk] = (available, label)
            }
        }

        return result
    }

    func wholeDiskIdentifier(fromDevicePath devicePath: String) -> String? {
        guard devicePath.hasPrefix("/dev/disk") else { return nil }
        let raw = String(devicePath.dropFirst("/dev/".count))
        let prefix = "disk"
        guard raw.hasPrefix(prefix) else { return nil }

        var result = prefix
        var index = raw.index(raw.startIndex, offsetBy: prefix.count)
        while index < raw.endIndex, raw[index].isNumber {
            result.append(raw[index])
            index = raw.index(after: index)
        }
        return result.count > prefix.count ? result : raw
    }

    func swapUsageBytes() -> UInt64 {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let result = sysctlbyname("vm.swapusage", &xsw, &size, nil, 0)
        guard result == 0 else { return 0 }
        return xsw.xsu_used
    }

    func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        var buffer = Array<CChar>(repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return stringFromCBuffer(buffer)
    }

    func sysctlInt(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    func shifted(_ values: [Double], adding value: Double) -> [Double] {
        var history = values
        if history.isEmpty {
            history = Array(repeating: 0, count: 60)
        }
        history.append(value)
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }
        return history
    }

    func percent(_ value: UInt64, _ total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total) * 100
    }

    func smoothedDynamicCeiling(previous: Double, latest: Double, minimum: Double) -> Double {
        let paddedTarget = max(latest * 1.2, minimum)
        if previous <= 0 {
            return paddedTarget
        }
        if paddedTarget > previous {
            return previous * 0.72 + paddedTarget * 0.28
        }
        return previous * 0.88 + paddedTarget * 0.12
    }

    func resolveCPUArchitecture() -> CPUArchitecture {
        if let brand = sysctlString("machdep.cpu.brand_string")?.lowercased(), !brand.isEmpty {
            if brand.contains("intel") || brand.contains("xeon") {
                return .intelLike
            }
            if brand.contains("apple")
                || brand.contains("m1")
                || brand.contains("m2")
                || brand.contains("m3")
                || brand.contains("m4")
                || brand.contains("m5")
            {
                return .appleSilicon
            }
        }

        if let translated = sysctlInt("sysctl.proc_translated"), translated == 1,
           let arm64 = sysctlInt("hw.optional.arm64"), arm64 == 1
        {
            return .appleSilicon
        }

        if let arm64 = sysctlInt("hw.optional.arm64"), arm64 == 1 {
            return .appleSilicon
        }

        if let translated = sysctlInt("sysctl.proc_translated"), translated == 1 {
            return .intelLike
        }

        if let cpuType = sysctlInt("hw.cputype") {
            let x86_64CPUType = UInt64(UInt32(bitPattern: cpu_type_t(CPU_TYPE_X86_64)))
            let x86CPUType = UInt64(UInt32(bitPattern: cpu_type_t(CPU_TYPE_X86)))
            if cpuType == x86_64CPUType || cpuType == x86CPUType {
                return .intelLike
            }
        }

        if let machine = sysctlString("hw.machine")?.lowercased() {
            if machine.contains("arm64") {
                return .appleSilicon
            }
            if machine.contains("x86") || machine.contains("i386") {
                return .intelLike
            }
        }

        return .unknown
    }

    func detectCPUFrequencyInfo() -> (base: String, primary: String, secondary: String, mode: AppleSiliconCoreTierMode) {
        switch cpuArchitecture {
        case .appleSilicon:
            let candidates = collectAppleSiliconFrequencyCandidates()
            let candidateByName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.propertyName, $0.displayText) })
            let primaryClassic = candidateByName["voltage-states5-sram"] ?? "--"
            let efficiencyClassic = candidateByName["voltage-states1-sram"] ?? "--"
            let performanceModern = candidateByName["voltage-states22-sram"]
                ?? candidateByName["voltage-states23-sram"]
                ?? candidateByName["voltage-states24-sram"]
                ?? "--"

            let mode: AppleSiliconCoreTierMode
            let primary: String
            let secondary: String
            switch candidates.count {
            case 0:
                mode = .singlePerformanceTier
                primary = "--"
                secondary = "--"
            case 1:
                mode = .singlePerformanceTier
                primary = primaryClassic != "--" ? primaryClassic : (candidates.first?.displayText ?? "--")
                secondary = "--"
            default:
                if primaryClassic != "--" && efficiencyClassic != "--" && performanceModern != "--" {
                    mode = .superEfficiency
                    primary = primaryClassic
                    secondary = efficiencyClassic
                } else if primaryClassic != "--" && efficiencyClassic != "--" {
                    mode = .performanceEfficiency
                    primary = primaryClassic
                    secondary = efficiencyClassic
                } else if primaryClassic != "--" && performanceModern != "--" {
                    mode = .superPerformance
                    primary = primaryClassic
                    secondary = performanceModern
                } else {
                    mode = .genericPrimarySecondary
                    primary = candidates.first?.displayText ?? "--"
                    secondary = candidates.dropFirst().first?.displayText ?? "--"
                }
            }

            let base = primary != "--" ? primary : secondary
            return (base, primary, secondary, mode)
        case .intelLike, .unknown:
            let base = DisplayFormat.frequency(sysctlInt("hw.cpufrequency"))
            return (base, "--", "--", .singlePerformanceTier)
        }
    }

    private struct FrequencyCandidate {
        let propertyName: String
        let hertz: UInt32
        let displayText: String
    }

    private func collectAppleSiliconFrequencyCandidates() -> [FrequencyCandidate] {
        let candidateKeys = [
            "voltage-states5-sram",
            "voltage-states1-sram",
            "voltage-states22-sram",
            "voltage-states23-sram",
            "voltage-states24-sram"
        ]

        return candidateKeys.compactMap { propertyName in
            guard let hertz = detectAppleSiliconFrequencyValue(propertyName: propertyName), hertz > 0 else {
                return nil
            }
            let mhz: Double = hertz > 100_000_000 ? Double(hertz) / 1_000_000 : Double(hertz) / 1_000
            return FrequencyCandidate(
                propertyName: propertyName,
                hertz: hertz,
                displayText: String(format: "%.2f GHz", mhz / 1000.0)
            )
        }
        .sorted { lhs, rhs in
            if lhs.hertz != rhs.hertz {
                return lhs.hertz > rhs.hertz
            }
            return lhs.propertyName < rhs.propertyName
        }
    }

    func detectAppleSiliconFrequencyText(propertyName: String) -> String? {
        guard let maxFrequency = detectAppleSiliconFrequencyValue(propertyName: propertyName), maxFrequency > 0 else {
            return nil
        }

        let mhz: Double
        if maxFrequency > 100_000_000 {
            mhz = Double(maxFrequency) / 1_000_000
        } else {
            mhz = Double(maxFrequency) / 1_000
        }

        return String(format: "%.2f GHz", mhz / 1000.0)
    }

    func detectAppleSiliconFrequencyValue(propertyName: String) -> UInt32? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        guard IOObjectConformsTo(service, "AppleARMIODevice") != 0 else {
            return nil
        }

        guard
            let property = IORegistryEntryCreateCFProperty(service, propertyName as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
            CFGetTypeID(property) == CFDataGetTypeID(),
            let data = property as? Data,
            data.count >= MemoryLayout<UInt32>.size * 2,
            data.count % (MemoryLayout<UInt32>.size * 2) == 0
        else {
            return nil
        }

        let values = data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: UInt32.self))
        }
        guard !values.isEmpty else { return nil }

        var maxFrequency = values[0]
        var index = 2
        while index < values.count, values[index] > 0 {
            maxFrequency = max(maxFrequency, values[index])
            index += 2
        }

        return maxFrequency > 0 ? maxFrequency : nil
    }

    func loadCachePresentation() {
        appleCachePairs = []
        legacyCachePairs = []

        if let l1i = sysctlInt("hw.l1icachesize"), l1i > 0 {
            appleCachePairs.append(.init(label: language.text("L1 指令缓存", "L1 instruction cache"), value: DisplayFormat.decimalBytes(l1i)))
        }
        if let l1d = sysctlInt("hw.l1dcachesize"), l1d > 0 {
            appleCachePairs.append(.init(label: language.text("L1 数据缓存", "L1 data cache"), value: DisplayFormat.decimalBytes(l1d)))
            legacyCachePairs.append(.init(label: language.text("L1 缓存", "L1 cache"), value: DisplayFormat.decimalBytes(l1d)))
        }
        if let l2 = sysctlInt("hw.l2cachesize"), l2 > 0 {
            appleCachePairs.append(.init(label: language.text("L2 缓存", "L2 cache"), value: DisplayFormat.decimalBytes(l2)))
            legacyCachePairs.append(.init(label: language.text("L2 缓存", "L2 cache"), value: DisplayFormat.decimalBytes(l2)))
        }
        if let l3 = sysctlInt("hw.l3cachesize"), l3 > 0 {
            legacyCachePairs.append(.init(label: language.text("L3 缓存", "L3 cache"), value: DisplayFormat.decimalBytes(l3)))
        }
    }

    func stringFromCBuffer(_ buffer: [CChar]) -> String {
        let prefix = buffer.prefix { $0 != 0 }
        return String(decoding: prefix.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func stringFromCArray(_ pointer: UnsafePointer<CChar>) -> String {
        String(cString: pointer)
    }
}

enum CPUArchitecture {
    case appleSilicon
    case intelLike
    case unknown
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

extension Process {
    static func runAndCapture(_ launchPath: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

private enum MonitorProbe {
    private final class GPUProfilerCache: @unchecked Sendable {
        private struct Snapshot {
            let date: Date
            let items: [[String: Any]]
        }

        private let lock = NSLock()
        private var snapshot: Snapshot?

        func items(maxAge: TimeInterval = 60) -> [[String: Any]] {
            lock.lock()
            if let snapshot, Date().timeIntervalSince(snapshot.date) < maxAge {
                let items = snapshot.items
                lock.unlock()
                return items
            }
            let fallback = snapshot?.items ?? []
            lock.unlock()

            guard
                let profilerData = try? Process.runAndCapture("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"]),
                let profilerJSON = try? JSONSerialization.jsonObject(with: profilerData) as? [String: Any],
                let profilerItems = profilerJSON["SPDisplaysDataType"] as? [[String: Any]]
            else {
                return fallback
            }

            lock.lock()
            snapshot = Snapshot(date: Date(), items: profilerItems)
            lock.unlock()
            return profilerItems
        }
    }

    private static let gpuProfilerCache = GPUProfilerCache()

    struct StaticProbeSnapshot {
        let rootWholeDiskID: String?
        let hardwarePortMap: [String: String]
    }

    struct StartupRowSnapshot {
        let id: String
        let name: String
        let iconProgramPath: String?
        let publisher: String
        let status: String
        let startupImpact: String
    }

    struct StartupSnapshot {
        let disabledLaunchdByGroup: [String: Set<String>]
        let rows: [StartupRowSnapshot]
    }

    struct ServiceRowSnapshot {
        let id: String
        let name: String
        let iconProgramPath: String?
        let pid: Int32?
        let serviceDescription: String
        let status: String
        let group: String
        let label: String
    }

    static func probeDetailedDiskMetadata(
        forDiskID diskID: String,
        rootWholeDiskID: String?
    ) -> SystemMonitor.DiskDetailMetadata? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let mountInfo = mountedDiskInfoByWholeDisk()

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let media = wholeMediaChild(of: service) else { continue }
            defer { IOObjectRelease(media) }

            let mediaProps = registryProperties(media)
            let deviceIdentifier = mediaProps["BSD Name"] as? String ?? ""
            guard deviceIdentifier == diskID else { continue }

            let model = ioRegistryName(media).isEmpty ? deviceIdentifier : ioRegistryName(media)
            let kind = resolveDiskKind(
                deviceIdentifier: deviceIdentifier,
                mediaProps: mediaProps,
                model: model,
                service: service,
                media: media
            )
            let label = mountInfo[deviceIdentifier]?.label ?? ""
            let available = mountInfo[deviceIdentifier]?.availableBytes ?? 0

            return SystemMonitor.DiskDetailMetadata(
                subtitle: label,
                kind: kind,
                availableBytes: available,
                isSystemDisk: deviceIdentifier == rootWholeDiskID
            )
        }

        return nil
    }

    static func collectStaticProbeSnapshot() -> StaticProbeSnapshot {
        StaticProbeSnapshot(
            rootWholeDiskID: detectRootWholeDiskIdentifier(),
            hardwarePortMap: loadHardwarePortMap()
        )
    }

    static func collectProcessNetworkSnapshot(interfaceFilter: String?) -> [Int32: UInt64] {
        var arguments = ["-x", "-P", "-L", "1"]
        if let interfaceFilter {
            arguments.append(contentsOf: ["-t", interfaceFilter])
        }
        guard let data = try? Process.runAndCapture("/usr/bin/nettop", arguments),
              let text = String(data: data, encoding: .utf8)
        else {
            return [:]
        }

        var result: [Int32: UInt64] = [:]
        let apps = NSWorkspace.shared.runningApplications
        let pidsByName = apps.reduce(into: [String: [Int32]]()) { result, app in
            guard let name = app.localizedName, !name.isEmpty else { return }
            result[name, default: []].append(app.processIdentifier)
        }

        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let header = lines.first else { return result }
        let columns = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard
            let bytesInIndex = columns.firstIndex(of: "bytes_in"),
            let bytesOutIndex = columns.firstIndex(of: "bytes_out")
        else {
            return result
        }

        for line in lines.dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > max(bytesInIndex, bytesOutIndex) else { continue }

            let processToken = parts[1]
            let bytesIn = UInt64(parts[bytesInIndex]) ?? 0
            let bytesOut = UInt64(parts[bytesOutIndex]) ?? 0
            let total = bytesIn + bytesOut

            if let dotIndex = processToken.lastIndex(of: "."),
               let pid = Int32(processToken[processToken.index(after: dotIndex)...]) {
                result[pid] = total
            } else if let pids = pidsByName[processToken], pids.count == 1, let pid = pids.first {
                result[pid] = total
            }
        }
        return result
    }

    static func wholeMediaChild(of service: io_registry_entry_t) -> io_registry_entry_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            let props = registryProperties(child)
            if let bsd = props["BSD Name"] as? String, !bsd.isEmpty, (props["Whole"] as? Bool) == true {
                return child
            }
            IOObjectRelease(child)
        }

        return nil
    }

    static func registryProperties(_ entry: io_registry_entry_t) -> [String: Any] {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else {
            return [:]
        }
        return dictionary
    }

    static func ioRegistryName(_ entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { return "" }
        let prefix = name.prefix { $0 != 0 }
        return String(decoding: prefix.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func diskutilInfo(deviceIdentifier: String) -> [String: Any]? {
        guard let data = try? Process.runAndCapture("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(deviceIdentifier)"]) else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    static func resolveDiskKind(
        deviceIdentifier: String,
        mediaProps: [String: Any],
        model: String,
        service: io_registry_entry_t,
        media: io_registry_entry_t
    ) -> String {
        let registryHints = registryHintStrings(for: service) + registryHintStrings(for: media)

        if let info = diskutilInfo(deviceIdentifier: deviceIdentifier) {
            let isInternal = (info["Internal"] as? Bool) ?? false
            let removableExternal = (info["RemovableMediaOrExternalDevice"] as? Bool) ?? false
            let removableMedia = (info["RemovableMedia"] as? Bool) ?? false
            let ejectable = (info["Ejectable"] as? Bool) ?? false
            let busProtocol = (info["BusProtocol"] as? String) ?? ""
            let deviceTreePath = (info["DeviceTreePath"] as? String) ?? ""
            let solidState = (info["SolidState"] as? Bool) ?? model.localizedCaseInsensitiveContains("SSD")

            if !isInternal || removableExternal || removableMedia || ejectable {
                return "Removable"
            }

            return normalizedInternalDiskInterface(
                busProtocol: busProtocol,
                deviceTreePath: deviceTreePath,
                solidState: solidState,
                registryHints: registryHints
            )
        }

        let removable = (mediaProps["Removable"] as? Bool) ?? false || ((mediaProps["Ejectable"] as? Bool) ?? false)
        if removable {
            return "Removable"
        }
        if isLikelyExternalDisk(registryHints: registryHints) {
            return "Removable"
        }
        return normalizedInternalDiskInterface(
            busProtocol: "",
            deviceTreePath: "",
            solidState: model.localizedCaseInsensitiveContains("SSD"),
            registryHints: registryHints,
            fallbackLabel: "Unknown"
        )
    }

    static func normalizedInternalDiskInterface(
        busProtocol: String,
        deviceTreePath: String,
        solidState: Bool,
        registryHints: [String],
        fallbackLabel: String = "Internal"
    ) -> String {
        let lowerBus = busProtocol.lowercased()
        let lowerTreePath = deviceTreePath.lowercased()
        let lowerHints = registryHints.joined(separator: " ").lowercased()
        let combinedHints = [lowerBus, lowerTreePath, lowerHints]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if combinedHints.contains("ionvmefamily")
            || combinedHints.contains("nvmexpress")
            || combinedHints.contains("ioembeddednvmeblockdevice")
            || combinedHints.contains("appleembeddednvmetemperaturesensor")
            || combinedHints.contains("nvme")
            || combinedHints.contains("appleans")
            || combinedHints.contains("apple fabric")
        {
            return "NVMe"
        }
        if solidState && (combinedHints.contains("pci") || combinedHints.contains("pcie")) {
            return "NVMe"
        }
        if combinedHints.contains("sata")
            || combinedHints.contains("ata")
            || combinedHints.contains("ahci")
        {
            return "SATA"
        }
        if combinedHints.contains("ide") {
            return "IDE"
        }
        return busProtocol.isEmpty ? fallbackLabel : busProtocol
    }

    static func registryHintStrings(for entry: io_registry_entry_t, maxDepth: Int = 8) -> [String] {
        var hints: [String] = []
        var current = entry
        var depth = 0
        var releaseCurrent = false

        while current != 0, depth < maxDepth {
            hints.append(ioRegistryName(current))
            appendRegistryHintProperties(from: current, into: &hints)

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
                break
            }

            if releaseCurrent {
                IOObjectRelease(current)
            }
            current = parent
            releaseCurrent = true
            depth += 1
        }

        if releaseCurrent, current != 0 {
            IOObjectRelease(current)
        }

        return hints
    }

    static func appendRegistryHintProperties(from entry: io_registry_entry_t, into hints: inout [String]) {
        let properties = registryProperties(entry)
        let stringKeys = [
            "IOClass",
            "CFBundleIdentifier",
            "Physical Interconnect",
            "Physical Interconnect Location",
            "device-type",
            "Protocol",
            "Model Number",
            "MediaName"
        ]

        for key in stringKeys {
            if let value = properties[key] as? String, !value.isEmpty {
                hints.append(value)
            }
        }

        if let protocolCharacteristics = properties["Protocol Characteristics"] as? [String: Any] {
            if let interconnect = protocolCharacteristics["Physical Interconnect"] as? String, !interconnect.isEmpty {
                hints.append(interconnect)
            }
            if let location = protocolCharacteristics["Physical Interconnect Location"] as? String, !location.isEmpty {
                hints.append(location)
            }
        }
    }

    static func isLikelyExternalDisk(registryHints: [String]) -> Bool {
        let combinedHints = registryHints.joined(separator: " ").lowercased()
        let externalMarkers = [
            "external",
            "usb",
            "thunderbolt",
            "firewire",
            "sdxc",
            "sd card",
            "card reader",
            "cardreader",
            "mass storage",
            "removable",
            "portable"
        ]
        return externalMarkers.contains { combinedHints.contains($0) }
    }

    static func mountedDiskInfoByWholeDisk() -> [String: (availableBytes: UInt64, label: String)] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeNameKey, .volumeAvailableCapacityKey]
        let urls = manager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var result: [String: (availableBytes: UInt64, label: String)] = [:]

        for url in urls {
            var stats = statfs()
            guard statfs(url.path, &stats) == 0 else { continue }
            let source = withUnsafePointer(to: &stats.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { pointer in
                    String(cString: pointer)
                }
            }
            guard let wholeDisk = wholeDiskIdentifier(fromDevicePath: source) else { continue }

            let values = try? url.resourceValues(forKeys: keys)
            let label = values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent
            let available = UInt64(values?.volumeAvailableCapacity ?? 0)

            if var existing = result[wholeDisk] {
                existing.availableBytes += available
                if existing.label == wholeDisk {
                    existing.label = label
                }
                result[wholeDisk] = existing
            } else {
                result[wholeDisk] = (available, label)
            }
        }

        return result
    }

    static func collectANEDeviceInfo(cpuArchitecture: CPUArchitecture) -> SystemMonitor.ANEDeviceInfo? {
        guard cpuArchitecture != .intelLike else {
            return nil
        }
        guard let data = try? Process.runAndCapture("/usr/sbin/ioreg", ["-l", "-w0"]) else {
            return nil
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        guard text.localizedCaseInsensitiveContains("ANE") else { return nil }

        let npuCount = text.localizedCaseInsensitiveContains("ANEDevicePropertyNumANEs") ? 1 : 1
        let coreCount = 16
        let modelName = "Apple Neural Engine"
        let architecture = extractFirstMatch(in: text, pattern: #"ANEDevicePropertyTypeANEArchitectureTypeStr"="([^"]+)""#) ?? "h16g"
        let firmwareLoaded = text.localizedCaseInsensitiveContains(#""FirmwareLoaded" = Yes"#) || text.localizedCaseInsensitiveContains(#""FirmwareLoaded" = true"#)
        let aneBlock = extractFirstMatch(in: text, pattern: #"(?s)\+\-o H11ANE .*?\{(.*?)\n\s*\}"#) ?? text
        let currentPowerState = Int(extractFirstMatch(in: aneBlock, pattern: #""CurrentPowerState"=([0-9]+)"#) ?? "0") ?? 0
        let maxPowerState = Int(extractFirstMatch(in: aneBlock, pattern: #""MaxPowerState"=([0-9]+)"#) ?? "1") ?? 1
        let activeClientCount = max(text.components(separatedBy: "IOUserClientCreator").count - 1, 0)
        let capacityBytes = sysctlInt("hw.memsize").map { max($0, 1_073_741_824) } ?? 1_073_741_824
        return SystemMonitor.ANEDeviceInfo(
            modelName: modelName,
            npuCount: npuCount,
            coreCount: coreCount,
            capacityBytes: capacityBytes,
            architecture: architecture,
            firmwareLoaded: firmwareLoaded,
            currentPowerState: currentPowerState,
            maxPowerState: maxPowerState,
            activeClientCount: activeClientCount
        )
    }

    static func collectNPUState(
        previous: NPUState?,
        aneInfo: SystemMonitor.ANEDeviceInfo?,
        totalMemory: UInt64,
        activeTimePercent: Double,
        powerWatts: Double,
        dataReadBytesPerSecond: UInt64,
        dataWriteBytesPerSecond: UInt64,
        dataMovementBytesPerSecond: UInt64
    ) -> NPUState? {
        guard let aneInfo else { return nil }

        let usage = currentNeuralUsageTotals()
        let peakFootprint = max(previous?.peakNeuralFootprintBytes ?? 0, usage.intervalPeakBytes, usage.currentBytes, 1)
        let peakPowerWatts = max(previous?.peakPowerWatts ?? 0, powerWatts)
        let peakDataMovement = max(previous?.peakDataMovementBytesPerSecond ?? 0, dataMovementBytesPerSecond, 1)
        let historyActiveTime = shifted(previous?.historyActiveTime ?? Array(repeating: 0, count: 60), adding: activeTimePercent)
        let historyPowerWatts = shifted(previous?.historyPowerWatts ?? Array(repeating: 0, count: 60), adding: powerWatts)
        let historyDataMovementBytes = shifted(previous?.historyDataMovementBytes ?? Array(repeating: 0, count: 60), adding: Double(dataMovementBytesPerSecond))
        let historyFootprint = shifted(
            previous?.historyFootprint ?? Array(repeating: 0, count: 60),
            adding: Double(usage.currentBytes)
        )
        let historyMemoryPressure = shifted(
            previous?.historyMemoryPressure ?? Array(repeating: 0, count: 60),
            adding: min(Double(usage.currentBytes) / Double(max(totalMemory, 1)) * 100, 100)
        )

        return NPUState(
            id: "npu0",
            title: "NPU 0",
            subtitle: aneInfo.modelName,
            modelName: aneInfo.modelName,
            npuCount: aneInfo.npuCount,
            coreCount: aneInfo.coreCount,
            architecture: aneInfo.architecture,
            firmwareLoaded: aneInfo.firmwareLoaded,
            currentPowerState: aneInfo.currentPowerState,
            maxPowerState: aneInfo.maxPowerState,
            activeClientCount: aneInfo.activeClientCount,
            activeTimePercent: activeTimePercent,
            powerWatts: powerWatts,
            peakPowerWatts: peakPowerWatts,
            dataReadBytesPerSecond: dataReadBytesPerSecond,
            dataWriteBytesPerSecond: dataWriteBytesPerSecond,
            dataMovementBytesPerSecond: dataMovementBytesPerSecond,
            peakDataMovementBytesPerSecond: peakDataMovement,
            neuralFootprintBytes: usage.currentBytes,
            peakNeuralFootprintBytes: peakFootprint,
            historyActiveTime: historyActiveTime,
            historyPowerWatts: historyPowerWatts,
            historyDataMovementBytes: historyDataMovementBytes,
            historyFootprint: historyFootprint,
            historyMemoryPressure: historyMemoryPressure
        )
    }

    static func statisticDouble(_ dictionary: [String: Any]?, keys: [String]) -> Double? {
        guard let dictionary else { return nil }
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                return number.doubleValue
            }
            if let text = dictionary[key] as? String {
                let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Double(cleaned) {
                    return value
                }
            }
        }
        return nil
    }

    static func statisticUInt64(_ dictionary: [String: Any]?, keys: [String]) -> UInt64? {
        guard let dictionary else { return nil }
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                return number.uint64Value
            }
            if let text = dictionary[key] as? String {
                let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = UInt64(cleaned) {
                    return value
                }
            }
        }
        return nil
    }

    static func byteCount(fromProfilerValue value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        guard let text = value as? String else { return nil }
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"([0-9]+(?:\.[0-9]+)?)"#
        guard let match = extractFirstMatch(in: cleaned, pattern: pattern),
              let numericValue = Double(match)
        else {
            return nil
        }

        let uppercased = cleaned.uppercased()
        let multiplier: Double
        if uppercased.contains("TB") {
            multiplier = 1_099_511_627_776
        } else if uppercased.contains("GB") {
            multiplier = 1_073_741_824
        } else if uppercased.contains("MB") {
            multiplier = 1_048_576
        } else if uppercased.contains("KB") {
            multiplier = 1_024
        } else {
            multiplier = 1
        }

        return UInt64(max(numericValue * multiplier, 0))
    }

    static func dedicatedVRAMTotalBytes(profilerItem: [String: Any]?, ioEntry: [String: Any]?) -> UInt64 {
        if let profileValue = byteCount(fromProfilerValue: profilerItem?["spdisplays_vram"])
            ?? byteCount(fromProfilerValue: profilerItem?["sppci_vram"]),
           profileValue > 0
        {
            return profileValue
        }

        if let vramMB = statisticUInt64(ioEntry, keys: ["VRAM,totalMB"]), vramMB > 0 {
            return vramMB * 1_048_576
        }

        return 0
    }

    static func isAMDGPU(model: String, device: any MTLDevice, profilerItem: [String: Any]?, ioEntry: [String: Any]?) -> Bool {
        let candidates = [
            model,
            device.name,
            profilerItem?["spdisplays_vendor"] as? String ?? "",
            profilerItem?["sppci_model"] as? String ?? "",
            profilerItem?["_name"] as? String ?? "",
            ioEntry?["IOClass"] as? String ?? "",
            ioEntry?["IOObjectClass"] as? String ?? "",
            ioEntry?["CFBundleIdentifier"] as? String ?? ""
        ]
        let haystack = candidates.joined(separator: " ").lowercased()
        return haystack.contains("amd") || haystack.contains("radeon")
    }

    static func isIntelGPU(model: String, device: any MTLDevice, profilerItem: [String: Any]?) -> Bool {
        let candidates = [
            model,
            device.name,
            profilerItem?["spdisplays_vendor"] as? String ?? "",
            profilerItem?["sppci_model"] as? String ?? "",
            profilerItem?["_name"] as? String ?? ""
        ]
        let haystack = candidates.joined(separator: " ").lowercased()
        return haystack.contains("intel")
            || haystack.contains("iris")
            || haystack.contains("uhd")
            || haystack.contains("hd graphics")
    }

    static func profilerIdentityScore(device: any MTLDevice, profilerItem: [String: Any], cpuArchitecture: CPUArchitecture) -> Int {
        let model = (profilerItem["sppci_model"] as? String ?? profilerItem["_name"] as? String ?? "").lowercased()
        let vendor = (profilerItem["spdisplays_vendor"] as? String ?? "").lowercased()
        let deviceName = device.name.lowercased()
        var score = 0

        if !model.isEmpty {
            if model == deviceName {
                score += 200
            } else if model.contains(deviceName) || deviceName.contains(model) {
                score += 120
            }
        }

        if cpuArchitecture == .intelLike {
            let itemLooksAMD = model.contains("radeon") || vendor.contains("amd")
            let itemLooksIntel = model.contains("intel") || model.contains("iris") || model.contains("uhd") || vendor.contains("intel")
            let deviceLooksAMD = deviceName.contains("radeon") || deviceName.contains("amd")
            let deviceLooksIntel = deviceName.contains("intel") || deviceName.contains("iris") || deviceName.contains("uhd")

            if itemLooksAMD && deviceLooksAMD {
                score += 80
            }
            if itemLooksIntel && deviceLooksIntel {
                score += 80
            }
        }

        return score
    }

    static func profilerItemIndex(for device: any MTLDevice, profilerItems: [[String: Any]], availableIndices: [Int], cpuArchitecture: CPUArchitecture) -> Int? {
        guard !availableIndices.isEmpty else { return nil }
        let scored = availableIndices.map { index in
            (index, profilerIdentityScore(device: device, profilerItem: profilerItems[index], cpuArchitecture: cpuArchitecture))
        }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }
        return availableIndices.first
    }

    static func gpuTypeText(
        cpuArchitecture: CPUArchitecture,
        device: any MTLDevice,
        profilerItem: [String: Any]?,
        ioEntry: [String: Any]?,
        model: String,
        dedicatedMemoryTotalBytes: UInt64,
        language: AppLanguage
    ) -> String {
        if cpuArchitecture == .intelLike {
            let amd = isAMDGPU(model: model, device: device, profilerItem: profilerItem, ioEntry: ioEntry)
            let intel = isIntelGPU(model: model, device: device, profilerItem: profilerItem)
            if dedicatedMemoryTotalBytes > 0 || amd {
                return language.text("独立", "Discrete")
            }
            if intel || device.isLowPower {
                return language.text("集成", "Integrated")
            }
        }
        return resolvedGPUType(device: device, profilerItem: profilerItem, language: language)
    }

    static func cachedGPUProfilerItems(maxAge: TimeInterval = 60) -> [[String: Any]] {
        gpuProfilerCache.items(maxAge: maxAge)
    }

    static func collectGPUStates(previous: [GPUState], language: AppLanguage, cpuArchitecture: CPUArchitecture) -> [GPUState] {
        guard
            let acceleratorData = try? Process.runAndCapture("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "IOAccelerator", "-a", "-l"]),
            let acceleratorArray = try? PropertyListSerialization.propertyList(from: acceleratorData, options: [], format: nil) as? [[String: Any]]
        else {
            return previous
        }

        let profilerItems = cachedGPUProfilerItems()
        let devices = MTLCopyAllDevices()
        let acceleratorByRegistryID = Dictionary(
            acceleratorArray.compactMap { entry -> (UInt64, [String: Any])? in
                guard let registryID = (entry["IORegistryEntryID"] as? NSNumber)?.uint64Value else { return nil }
                return (registryID, entry)
            },
            uniquingKeysWith: { current, _ in current }
        )

        var next: [GPUState] = []
        var availableProfilerIndices = Array(profilerItems.indices)
        let gpuCount = devices.count

        for (index, device) in devices.enumerated() {
            let ioEntry = acceleratorByRegistryID[device.registryID]
            let matchedProfilerIndex = profilerItemIndex(
                for: device,
                profilerItems: profilerItems,
                availableIndices: availableProfilerIndices,
                cpuArchitecture: cpuArchitecture
            )
            if let matchedProfilerIndex {
                availableProfilerIndices.removeAll { $0 == matchedProfilerIndex }
            }
            let matchedProfilerItem = matchedProfilerIndex.flatMap { profilerItems[safe: $0] }

            let model = matchedProfilerItem?["sppci_model"] as? String
                ?? matchedProfilerItem?["_name"] as? String
                ?? device.name
            let metalRaw = matchedProfilerItem?["spdisplays_mtlgpufamilysupport"] as? String ?? ""
            let metalVersion = resolvedMetalVersion(raw: metalRaw, device: device)
            let coreCount = Int(matchedProfilerItem?["sppci_cores"] as? String ?? "") ?? 0

            let performance = ioEntry?["PerformanceStatistics"] as? [String: Any]
            let deviceUtil = statisticDouble(
                performance,
                keys: ["Device Utilization %", "GPU Activity(%)", "Device Utilization % at cur p-state"]
            ) ?? 0
            let rawRendererUtil = statisticDouble(
                performance,
                keys: ["Renderer Utilization %", "3D Utilization %", "3D Engine Utilization %"]
            )
            let rawTilerUtil = statisticDouble(
                performance,
                keys: ["Tiler Utilization %", "Tiler/Copy Utilization %", "Copy Engine Utilization %"]
            )
            let inUseMemory = statisticUInt64(
                performance,
                keys: ["In use system memory", "inUseSysMemoryBytes", "gartUsedBytes"]
            ) ?? 0
            let performanceAllocatedMemory = statisticUInt64(
                performance,
                keys: ["Alloc system memory", "allocSysMemoryBytes", "gartSizeBytes"]
            ) ?? 0
            let recommendedWorkingSet = device.recommendedMaxWorkingSetSize
            let allocatedMemory = max(
                inUseMemory,
                recommendedWorkingSet > 0 ? recommendedWorkingSet : performanceAllocatedMemory
            )
            let dedicatedTotalMemory = cpuArchitecture == .intelLike
                ? dedicatedVRAMTotalBytes(profilerItem: matchedProfilerItem, ioEntry: ioEntry)
                : 0
            let dedicatedUsedMemory = dedicatedTotalMemory > 0
                ? min(
                    statisticUInt64(performance, keys: ["In use video memory", "inUseVidMemoryBytes"]) ?? 0,
                    dedicatedTotalMemory
                )
                : 0
            let supportsEngineBreakdown = rawRendererUtil != nil && rawTilerUtil != nil && dedicatedTotalMemory == 0
            let rendererUtil = supportsEngineBreakdown ? (rawRendererUtil ?? 0) : 0
            let tilerUtil = supportsEngineBreakdown ? (rawTilerUtil ?? 0) : 0
            let gpuType = gpuTypeText(
                cpuArchitecture: cpuArchitecture,
                device: device,
                profilerItem: matchedProfilerItem,
                ioEntry: ioEntry,
                model: model,
                dedicatedMemoryTotalBytes: dedicatedTotalMemory,
                language: language
            )
            let openGLVersion: String? = nil

            let id = "gpu\(index)"
            let previousState = previous.first(where: { $0.id == id })
            let historyOverall = shifted(previousState?.historyOverall ?? Array(repeating: 0, count: 60), adding: deviceUtil)
            let history3D = shifted(previousState?.history3D ?? Array(repeating: 0, count: 60), adding: rendererUtil)
            let historyTiler = shifted(previousState?.historyTiler ?? Array(repeating: 0, count: 60), adding: tilerUtil)
            let displayedMemoryUsed = dedicatedTotalMemory > 0 ? dedicatedUsedMemory : inUseMemory
            let displayedMemoryTotal = dedicatedTotalMemory > 0 ? dedicatedTotalMemory : allocatedMemory
            let memoryPercent = displayedMemoryTotal > 0 ? min(Double(displayedMemoryUsed) / Double(displayedMemoryTotal) * 100, 100) : 0
            let memoryHistory = shifted(previousState?.memoryHistory ?? Array(repeating: 0, count: 60), adding: memoryPercent)

            next.append(GPUState(
                id: id,
                title: "GPU \(index)",
                subtitle: model,
                modelName: model,
                gpuCount: gpuCount,
                gpuType: gpuType,
                coreCount: coreCount,
                utilizationPercent: deviceUtil,
                rendererUtilizationPercent: rendererUtil,
                tilerUtilizationPercent: tilerUtil,
                sharedMemoryUsedBytes: inUseMemory,
                sharedMemoryAllocatedBytes: allocatedMemory,
                dedicatedMemoryUsedBytes: dedicatedUsedMemory,
                dedicatedMemoryTotalBytes: dedicatedTotalMemory,
                supportsEngineBreakdown: supportsEngineBreakdown,
                metalVersion: metalVersion,
                openGLVersion: openGLVersion,
                historyOverall: historyOverall,
                history3D: history3D,
                historyTiler: historyTiler,
                memoryHistory: memoryHistory
            ))
        }

        return next
    }

    static func collectStartupRows() -> StartupSnapshot {
        let uid = getuid()
        var disabledLaunchdByGroup: [String: Set<String>] = [:]
        disabledLaunchdByGroup["system"] = disabledLaunchdLabels(domain: "system")
        disabledLaunchdByGroup["gui/\(uid)"] = disabledLaunchdLabels(domain: "gui/\(uid)")

        let directories = [
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            ("~/Library/LaunchAgents" as NSString).expandingTildeInPath
        ]

        var rows: [StartupRowSnapshot] = []
        if let loginItemNames = try? Process.runAndCapture("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get the name of every login item"]),
           let namesString = String(data: loginItemNames, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !namesString.isEmpty
        {
            let names = namesString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            rows.append(contentsOf: names.map {
                StartupRowSnapshot(
                    id: "login-\($0)",
                    name: $0,
                    iconProgramPath: nil,
                    publisher: "Login item",
                    status: "Enabled",
                    startupImpact: "N/A"
                )
            })
        }

        let fileManager = FileManager.default
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".plist") {
                let path = (directory as NSString).appendingPathComponent(entry)
                guard let data = fileManager.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                else { continue }

                let label = plist["Label"] as? String ?? entry.replacingOccurrences(of: ".plist", with: "")
                let program = (plist["Program"] as? String)
                    ?? (plist["ProgramArguments"] as? [String])?.first
                    ?? ""
                let name = URL(fileURLWithPath: program).deletingPathExtension().lastPathComponent.isEmpty
                    ? label
                    : URL(fileURLWithPath: program).deletingPathExtension().lastPathComponent
                let publisher = program.isEmpty ? directoryLabel(directory) : URL(fileURLWithPath: program).deletingLastPathComponent().lastPathComponent
                let group = launchdGroupForStartupDirectory(directory)
                let labelDisabled = disabledLaunchdByGroup[group]?.contains(label) ?? false
                let plistDisabled = (plist["Disabled"] as? Bool) ?? false
                let enabled = !(plistDisabled || labelDisabled)
                let impact = directory.contains("Daemons") ? "High" : "N/A"

                let row = StartupRowSnapshot(
                    id: path,
                    name: name,
                    iconProgramPath: program.isEmpty ? nil : program,
                    publisher: publisher,
                    status: enabled ? "Enabled" : "Disabled",
                    startupImpact: impact
                )
                if rows.contains(where: { $0.id == row.id || $0.name == row.name }) { continue }
                rows.append(row)
            }
        }

        return StartupSnapshot(
            disabledLaunchdByGroup: disabledLaunchdByGroup,
            rows: rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    static func collectServiceRows(uid: uid_t) -> [ServiceRowSnapshot] {
        let runtimeEntries = launchdRuntimeEntries(uid: uid)
        let metadataByKey = launchdPlistMetadata(uid: uid)
        var merged: [String: ServiceRowSnapshot] = [:]

        for entry in runtimeEntries {
            let key = serviceCompositeKey(label: entry.label, group: entry.group)
            let metadata = metadataByKey[key]
            let status = serviceStatusText(pid: entry.pid, stateToken: entry.stateToken, disabled: metadata?.disabled ?? false)
            merged[key] = ServiceRowSnapshot(
                id: key,
                name: metadata?.name ?? serviceNameFallback(label: entry.label),
                iconProgramPath: metadata?.program,
                pid: entry.pid,
                serviceDescription: metadata?.serviceDescription ?? entry.label,
                status: status,
                group: entry.group,
                label: entry.label
            )
        }

        for (key, metadata) in metadataByKey where merged[key] == nil {
            merged[key] = ServiceRowSnapshot(
                id: key,
                name: metadata.name,
                iconProgramPath: metadata.program,
                pid: nil,
                serviceDescription: metadata.serviceDescription,
                status: metadata.disabled ? "Disabled" : "Not loaded",
                group: metadata.group,
                label: metadata.label
            )
        }

        return merged.values.sorted { lhs, rhs in
            let nameCompare = lhs.name.localizedStandardCompare(rhs.name)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            let labelCompare = lhs.label.localizedStandardCompare(rhs.label)
            if labelCompare != .orderedSame {
                return labelCompare == .orderedAscending
            }
            return lhs.group.localizedStandardCompare(rhs.group) == .orderedAscending
        }
    }

    static func rootWholeDiskIdentifierFromMountedRoot() -> String? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let source = withUnsafePointer(to: &stats.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { pointer in
                String(cString: pointer)
            }
        }
        return wholeDiskIdentifier(fromDevicePath: source)
    }

    static func detectRootWholeDiskIdentifier() -> String? {
        if let data = try? Process.runAndCapture("/usr/sbin/diskutil", ["info", "-plist", "/"]),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        {
            if let physicalStores = plist["APFSPhysicalStores"] as? [[String: Any]] {
                for store in physicalStores {
                    if let physicalStore = store["APFSPhysicalStore"] as? String ?? store["DeviceIdentifier"] as? String,
                       let wholeDisk = wholeDiskIdentifier(fromDevicePath: "/dev/\(physicalStore)")
                    {
                        return wholeDisk
                    }
                }
            }

            if let parentWholeDisk = plist["ParentWholeDisk"] as? String,
               let wholeDisk = wholeDiskIdentifier(fromDevicePath: "/dev/\(parentWholeDisk)")
            {
                return wholeDisk
            }
        }

        return rootWholeDiskIdentifierFromMountedRoot()
    }

    static func loadHardwarePortMap() -> [String: String] {
        guard let data = try? Process.runAndCapture("/usr/sbin/networksetup", ["-listallhardwareports"]),
              let text = String(data: data, encoding: .utf8)
        else {
            return [:]
        }

        var result: [String: String] = [:]
        var currentPort: String?

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("Hardware Port:") {
                currentPort = line.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:"), let currentPort {
                let device = line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                if !device.isEmpty {
                    result[device] = currentPort
                }
            }
        }

        return result
    }

    static func disabledLaunchdLabels(domain: String) -> Set<String> {
        guard let data = try? Process.runAndCapture("/bin/launchctl", ["print-disabled", domain]),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }

        var labels: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.contains("=> disabled") else { continue }
            if let end = trimmed.dropFirst().firstIndex(of: "\"") {
                labels.insert(String(trimmed.dropFirst()[..<end]))
            }
        }
        return labels
    }

    static func launchdRuntimeEntries(uid: uid_t) -> [SystemMonitor.LaunchdRuntimeEntry] {
        let systemEntries = parseLaunchctlPrintDomain("system", group: "system")
        let guiEntries = parseLaunchctlPrintDomain("gui/\(uid)", group: "gui/\(uid)")
        var merged: [String: SystemMonitor.LaunchdRuntimeEntry] = [:]

        for entry in systemEntries + guiEntries {
            guard shouldIncludeServiceLabel(entry.label) else { continue }
            let key = serviceCompositeKey(label: entry.label, group: entry.group)
            merged[key] = entry
        }

        return Array(merged.values)
    }

    static func parseLaunchctlPrintDomain(_ domain: String, group: String) -> [SystemMonitor.LaunchdRuntimeEntry] {
        guard let data = try? Process.runAndCapture("/bin/launchctl", ["print", domain]),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }

        var result: [SystemMonitor.LaunchdRuntimeEntry] = []
        var inServicesBlock = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" {
                inServicesBlock = true
                continue
            }
            if inServicesBlock, trimmed == "}" {
                break
            }
            guard inServicesBlock else { continue }

            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }

            let label = String(parts.last!)
            guard shouldIncludeServiceLabel(label) else { continue }

            let pidToken = String(parts[0])
            let stateToken = String(parts[1])
            let pid: Int32?
            if let value = Int32(pidToken), value > 0 {
                pid = value
            } else {
                pid = nil
            }

            result.append(
                SystemMonitor.LaunchdRuntimeEntry(
                    label: label,
                    pid: pid,
                    stateToken: stateToken,
                    group: group
                )
            )
        }

        return result
    }

    static func launchdPlistMetadata(uid: uid_t) -> [String: LaunchdPlistMetadataSnapshot] {
        let directories = [
            "/System/Library/LaunchDaemons",
            "/System/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            ("~/Library/LaunchAgents" as NSString).expandingTildeInPath
        ]

        let fileManager = FileManager.default
        var result: [String: LaunchdPlistMetadataSnapshot] = [:]

        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".plist") {
                let path = (directory as NSString).appendingPathComponent(entry)
                guard let data = fileManager.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                else {
                    continue
                }

                let label = plist["Label"] as? String ?? entry.replacingOccurrences(of: ".plist", with: "")
                guard shouldIncludeServiceLabel(label) else { continue }

                let program = (plist["Program"] as? String)
                    ?? (plist["ProgramArguments"] as? [String])?.first
                    ?? ""
                let executableName = serviceExecutableName(fromProgramPath: program)
                let name = executableName.isEmpty ? serviceNameFallback(label: label) : executableName
                let description = serviceDescriptionText(label: label, program: program, plist: plist)
                let disabled = (plist["Disabled"] as? Bool) ?? false
                let group = launchdGroup(forDirectory: directory, uid: uid)
                let key = serviceCompositeKey(label: label, group: group)

                result[key] = LaunchdPlistMetadataSnapshot(
                    label: label,
                    name: name,
                    program: program.isEmpty ? nil : program,
                    serviceDescription: description,
                    group: group,
                    disabled: disabled
                )
            }
        }

        return result
    }

    struct LaunchdPlistMetadataSnapshot {
        let label: String
        let name: String
        let program: String?
        let serviceDescription: String
        let group: String
        let disabled: Bool
    }

    static func launchdGroup(forDirectory directory: String, uid: uid_t) -> String {
        if directory.contains("LaunchDaemons") {
            return "system"
        }
        return "gui/\(uid)"
    }

    static func launchdGroupForStartupDirectory(_ directory: String) -> String {
        if directory.contains("LaunchDaemons") {
            return "system"
        }
        return "gui/\(getuid())"
    }

    static func directoryLabel(_ path: String) -> String {
        if path.contains("LaunchDaemons") { return "System daemon" }
        if path.contains("/Library/LaunchAgents") { return "System agent" }
        return "User agent"
    }

    static func serviceCompositeKey(label: String, group: String) -> String {
        "\(group)|\(label)"
    }

    static func shouldIncludeServiceLabel(_ label: String) -> Bool {
        guard !label.isEmpty else { return false }
        if label.hasPrefix("application.") { return false }
        if label.hasPrefix("com.apple.xpc.") { return false }
        return true
    }

    static func serviceExecutableName(fromProgramPath program: String) -> String {
        guard !program.isEmpty else { return "" }
        if program.hasSuffix(".app") {
            return URL(fileURLWithPath: program).deletingPathExtension().lastPathComponent
        }

        let nsPath = program as NSString
        let range = nsPath.range(of: ".app/")
        if range.location != NSNotFound, let swiftRange = Range(range, in: program) {
            let appPath = String(program[..<swiftRange.upperBound]).dropLast()
            let appName = URL(fileURLWithPath: String(appPath)).deletingPathExtension().lastPathComponent
            if !appName.isEmpty {
                return appName
            }
        }

        return URL(fileURLWithPath: program).lastPathComponent
    }

    static func serviceNameFallback(label: String) -> String {
        let parts = label.split(separator: ".")
        if let last = parts.last, !last.isEmpty {
            return String(last)
        }
        return label
    }

    static func serviceDescriptionText(label: String, program: String, plist: [String: Any]) -> String {
        if let bundleName = plist["CFBundleDisplayName"] as? String, !bundleName.isEmpty {
            return bundleName
        }
        if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
            return bundleName
        }
        if !program.isEmpty {
            let executable = serviceExecutableName(fromProgramPath: program)
            if !executable.isEmpty {
                return "\(label) (\(executable))"
            }
        }
        if let machServices = plist["MachServices"] as? [String: Any], !machServices.isEmpty {
            return "\(label) (Mach Service)"
        }
        return label
    }

    static func serviceStatusText(pid: Int32?, stateToken: String, disabled: Bool) -> String {
        if disabled {
            return "Disabled"
        }
        if pid != nil {
            return "Running"
        }
        if stateToken == "0" {
            return "Stopped"
        }
        if stateToken == "-" || stateToken.hasPrefix("(") {
            return "On demand"
        }
        return "Loaded"
    }

    static func currentNeuralUsageTotals() -> SystemMonitor.NeuralUsageTotals {
        let pids = listPIDs()
        var total: UInt64 = 0
        var peak: UInt64 = 0
        for pid in pids where pid > 0 {
            var usage = rusage_info_current()
            let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
                }
            }
            if usageResult == 0 {
                total += usage.ri_neural_footprint
                peak = max(peak, usage.ri_interval_max_neural_footprint)
            }
        }
        return SystemMonitor.NeuralUsageTotals(currentBytes: total, intervalPeakBytes: peak)
    }

    static func listPIDs() -> [Int32] {
        let bufferSize = proc_listallpids(nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = bufferSize / Int32(MemoryLayout<pid_t>.size)
        var buffer = Array(repeating: pid_t(0), count: Int(count))
        let bytes = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return buffer.filter { $0 > 0 }
    }

    static func extractFirstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    static func sysctlInt(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func shifted(_ values: [Double], adding value: Double) -> [Double] {
        var history = values
        if history.isEmpty {
            history = Array(repeating: 0, count: 60)
        }
        history.append(value)
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }
        return history
    }

    static func metalLabel(from raw: String) -> String {
        switch raw {
        case "spdisplays_metal4":
            return "Metal 4"
        case "spdisplays_metal3":
            return "Metal 3"
        case "spdisplays_metal2":
            return "Metal 2"
        default:
            return raw.isEmpty ? "Metal" : raw
        }
    }

    static func resolvedMetalVersion(raw: String, device: any MTLDevice) -> String {
        if !raw.isEmpty {
            return metalLabel(from: raw)
        }
        if #available(macOS 26.0, *) {
            if device.supportsFamily(.metal4) {
                return "Metal 4"
            }
        }
        if #available(macOS 13.0, *) {
            if device.supportsFamily(.metal3) {
                return "Metal 3"
            }
        }
        return "Metal"
    }

    static func resolvedGPUType(device: any MTLDevice, profilerItem: [String: Any]?, language: AppLanguage) -> String {
        if #available(macOS 10.15, *) {
            switch device.location {
            case .builtIn:
                return language.text("内建", "Internal")
            case .external:
                return language.text("外建", "External")
            default:
                break
            }
        }

        if let bus = profilerItem?["sppci_bus"] as? String {
            return bus == "spdisplays_builtin"
                ? language.text("内建", "Internal")
                : language.text("外建", "External")
        }

        if device.isRemovable {
            return language.text("外建", "External")
        }
        return language.text("内建", "Internal")
    }

    static func wholeDiskIdentifier(fromDevicePath devicePath: String) -> String? {
        guard devicePath.hasPrefix("/dev/disk") else { return nil }
        let raw = String(devicePath.dropFirst("/dev/".count))
        let prefix = "disk"
        guard raw.hasPrefix(prefix) else { return nil }

        var result = prefix
        var index = raw.index(raw.startIndex, offsetBy: prefix.count)
        while index < raw.endIndex, raw[index].isNumber {
            result.append(raw[index])
            index = raw.index(after: index)
        }
        return result.count > prefix.count ? result : raw
    }
}
