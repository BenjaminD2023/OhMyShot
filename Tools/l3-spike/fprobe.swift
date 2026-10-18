// fprobe COMPILED_DIR ENC_UNITS DEC_UNITS [STEPS]
// Loads compiled encoder.mlmodelc and decoder.mlmodelc as the app would (fixed path, so the system's
// compile cache applies), then times the encoder and the stateful decoder step with dummy inputs.
// fprobe compile MLPACKAGE OUT_DIR   compiles a package once to OUT_DIR/<name>.mlmodelc
import CoreML
import Foundation

func units(_ s: String) -> MLComputeUnits {
    switch s { case "cpu": .cpuOnly; case "gpu": .cpuAndGPU; case "ne": .cpuAndNeuralEngine; default: .all }
}
func ms(_ t: ContinuousClock.Duration) -> Double { Double(t.components.attoseconds) / 1e15 + Double(t.components.seconds) * 1000 }
func footprintMB() -> Double {
    var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / 4)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return Double(info.ledger_phys_footprint_peak) / 1048576
}
func neuralPeakMB() -> Double {
    var ri = rusage_info_v6()
    let r = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
    return r == 0 ? Double(ri.ri_lifetime_max_neural_footprint) / 1048576 : -1
}

let args = CommandLine.arguments
if args[1] == "compile" {
    let t = ContinuousClock.now
    let url = try await MLModel.compileModel(at: URL(fileURLWithPath: args[2]))
    let dest = URL(fileURLWithPath: args[3]).appendingPathComponent(url.lastPathComponent)
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: url, to: dest)
    print("compiled \(dest.lastPathComponent) in \(Int(ms(ContinuousClock.now - t))) ms")
    exit(0)
}
let dir = URL(fileURLWithPath: args[1])
let steps = args.count > 4 ? Int(args[4])! : 60
let ec = MLModelConfiguration(); ec.computeUnits = units(args[2])
let dc = MLModelConfiguration(); dc.computeUnits = units(args[3])
var t = ContinuousClock.now
let enc = try MLModel(contentsOf: dir.appendingPathComponent("encoder.mlmodelc"), configuration: ec)
let encLoad = ms(ContinuousClock.now - t)
t = ContinuousClock.now
let dec = try MLModel(contentsOf: dir.appendingPathComponent("decoder.mlmodelc"), configuration: dc)
let decLoad = ms(ContinuousClock.now - t)

let pix = try MLMultiArray(shape: [1, 3, 768, 768], dataType: .float32)
for i in 0..<pix.count { pix[i] = 0.5 }
var encTimes: [Double] = []
var eout: MLFeatureProvider!
for _ in 0..<4 {
    t = ContinuousClock.now
    eout = try await enc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["pixel_values": pix]))
    encTimes.append(ms(ContinuousClock.now - t))
}
let ck = eout.featureValue(for: "cross_k")!.multiArrayValue!, cv = eout.featureValue(for: "cross_v")!.multiArrayValue!
let maxLen = 1024
let mask = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: maxLen)], dataType: .float16)
for i in 0..<maxLen { mask[i] = -65504 }
let ids = try MLMultiArray(shape: [1, 1], dataType: .int32), pos = try MLMultiArray(shape: [1], dataType: .int32)
let state = dec.makeState()
var stepTimes: [Double] = []
var tok: Int32 = 2
for i in 0..<steps {
    mask[i] = 0; ids[0] = NSNumber(value: tok); pos[0] = NSNumber(value: i)
    t = ContinuousClock.now
    let o = try await dec.prediction(from: MLDictionaryFeatureProvider(dictionary: ["ids": ids, "pos": pos, "mask": mask, "cross_k": ck, "cross_v": cv]), using: state)
    stepTimes.append(ms(ContinuousClock.now - t))
    tok = o.featureValue(for: "next")!.multiArrayValue![0].int32Value
}
let s = stepTimes.dropFirst(2).sorted()
print(String(format: "[%@/%@] load enc %.0f ms dec %.0f ms; encoder first %.0f ms then %.0f ms; step p50 %.2f ms p95 %.2f ms; peak footprint %.0f MB, neural %.0f MB",
             args[2], args[3], encLoad, decLoad, encTimes[0], encTimes.dropFirst().sorted()[1], s[s.count / 2], s[Int(Double(s.count) * 0.95)], footprintMB(), neuralPeakMB()))
