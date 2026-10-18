// energy -- COMMAND ARGS...   Runs COMMAND and prints the whole machine's energy over its run, by channel
// (IOReport "Energy Model": CPU, GPU, ANE, DRAM), with the idle power of 3 s before it subtracted.
// energy idle SECONDS          Prints average power per channel over SECONDS.
// On macOS 27.2 beta only the GPU channel counts: CPU and ANE read 0 (CPU energy comes from usage.py instead).
import Foundation

@_silgen_name("IOReportCopyChannelsInGroup")
func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSubscription")
func IOReportCreateSubscription(_ a: UnsafeMutableRawPointer?, _ desired: CFMutableDictionary, _ subbed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, _ id: UInt64, _ b: CFTypeRef?) -> OpaquePointer?
@_silgen_name("IOReportCreateSamples")
func IOReportCreateSamples(_ sub: OpaquePointer, _ subbed: CFMutableDictionary, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ c: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetChannelName")
func IOReportChannelGetChannelName(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel")
func IOReportChannelGetUnitLabel(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportSimpleGetIntegerValue")
func IOReportSimpleGetIntegerValue(_ ch: CFDictionary, _ i: Int32) -> Int64

final class Sampler {
    let sub: OpaquePointer
    let subbed: CFMutableDictionary
    init() {
        let channels = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)!.takeRetainedValue()
        let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels)!
        var subbed: Unmanaged<CFMutableDictionary>?
        sub = IOReportCreateSubscription(nil, desired, &subbed, 0, nil)!
        self.subbed = subbed!.takeRetainedValue()
    }
    func sample() -> CFDictionary { IOReportCreateSamples(sub, subbed, nil)!.takeRetainedValue() }
    /// Joules per channel name between two samples.
    func joules(_ a: CFDictionary, _ b: CFDictionary) -> [String: Double] {
        let delta = IOReportCreateSamplesDelta(a, b, nil)!.takeRetainedValue() as NSDictionary
        var out: [String: Double] = [:]
        for case let ch as NSDictionary in (delta["IOReportChannels"] as? [Any]) ?? [] {
            let c = ch as CFDictionary
            guard let name = IOReportChannelGetChannelName(c)?.takeUnretainedValue() as String? else { continue }
            let unit = (IOReportChannelGetUnitLabel(c)?.takeUnretainedValue() as String?) ?? ""
            let v = Double(IOReportSimpleGetIntegerValue(c, 0))
            let scale: Double = unit == "mJ" ? 1e-3 : unit == "uJ" ? 1e-6 : unit == "nJ" ? 1e-9 : 1
            out[name, default: 0] += v * scale
        }
        return out
    }
}

func groups(_ j: [String: Double]) -> [(String, Double)] {
    // Totals that matter: CPU, GPU, ANE, DRAM (channel names vary by chip).
    var cpu = 0.0, gpu = 0.0, ane = 0.0, dram = 0.0
    for (k, v) in j {
        if k == "CPU Energy" { cpu += v }
        else if k == "GPU Energy" || k == "GPU" { gpu += v }
        else if k.hasPrefix("ANE") { ane += v }
        else if k.hasPrefix("DRAM") { dram += v }
    }
    if cpu == 0 { cpu = j.filter { $0.key.contains("CPU") && !$0.key.contains("SRAM") }.values.reduce(0, +) }
    return [("CPU", cpu), ("GPU", gpu), ("ANE", ane), ("DRAM", dram)]
}

let args = Array(CommandLine.arguments.dropFirst())
let s = Sampler()
if args.first == "idle" {
    let secs = Double(args.dropFirst().first ?? "5") ?? 5
    let a = s.sample(); Thread.sleep(forTimeInterval: secs); let b = s.sample()
    for (k, v) in groups(s.joules(a, b)) { print(String(format: "%@ %.3f W", k, v / secs)) }
    exit(0)
}
guard args.first == "--", args.count > 1 else { print("energy -- CMD ARGS | energy idle S"); exit(2) }
let i0 = s.sample(); Thread.sleep(forTimeInterval: 3); let i1 = s.sample()
let idle = groups(s.joules(i0, i1)).map { ($0.0, $0.1 / 3) }
let p = Process()
p.executableURL = URL(fileURLWithPath: args[1])
p.arguments = Array(args.dropFirst(2))
let start = Date(); let a = s.sample()
try p.run(); p.waitUntilExit()
let b = s.sample(); let secs = Date().timeIntervalSince(start)
let run = groups(s.joules(a, b))
var line = String(format: "[energy] %.2f s;", secs)
var total = 0.0
for ((k, v), (_, w)) in zip(run, idle) {
    let extra = max(0, v - w * secs); total += extra
    line += String(format: " %@ %.1f J (%.2f W over idle %.2f W);", k, extra, extra / secs, w)
}
line += String(format: " total above idle %.1f J", total)
FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
exit(p.terminationStatus)
