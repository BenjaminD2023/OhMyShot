import CoreML
import Foundation

// Loads a Core ML package the way the app would (compiled once to a fixed place), reports load time,
// where each operation runs, and the warm prediction time for one input shape.
// Usage: probe PACKAGE COMPILED_DIR UNITS(cpu_ne|cpu) SHAPE(e.g. 1x3x736x1280) [RUNS]
let arguments = CommandLine.arguments
let package = URL(filePath: arguments[1])
let compiledDirectory = URL(filePath: arguments[2], directoryHint: .isDirectory)
let units: MLComputeUnits = arguments[3] == "cpu" ? .cpuOnly : .cpuAndNeuralEngine
let shape = arguments[4].split(separator: "x").map { Int($0)! }
let runs = arguments.count > 5 ? Int(arguments[5])! : 20

func ms(_ d: Duration) -> String { String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }

let compiled = compiledDirectory.appending(path: package.deletingPathExtension().lastPathComponent + ".mlmodelc")
if !FileManager.default.fileExists(atPath: compiled.path) {
    let started = ContinuousClock.now
    let temporary = try await MLModel.compileModel(at: package)
    try FileManager.default.moveItem(at: temporary, to: compiled)
    print("compiled to \(compiled.lastPathComponent) in \(ms(ContinuousClock.now - started))")
}
let configuration = MLModelConfiguration()
configuration.computeUnits = units
let loadStarted = ContinuousClock.now
let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
print("load (\(arguments[3])): \(ms(ContinuousClock.now - loadStarted))")

let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: configuration)
if case .program(let program) = plan.modelStructure, let main = program.functions["main"] {
    var devices: [String: Int] = [:]
    var costs: [String: Double] = [:]
    for operation in main.block.operations {
        let device: String
        switch plan.deviceUsage(for: operation)?.preferred {
        case .cpu: device = "CPU"
        case .gpu: device = "GPU"
        case .neuralEngine: device = "ANE"
        default: device = "none"
        }
        devices[device, default: 0] += 1
        costs[device, default: 0] += plan.estimatedCost(of: operation)?.weight ?? 0
    }
    print("operations by device: \(devices.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) (cost \(String(format: "%.0f%%", $0.value == 0 ? 0 : (costs[$0.key] ?? 0) * 100)))" }.joined(separator: ", "))")
}

let input = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
for index in 0..<input.count { input[index] = NSNumber(value: Float.random(in: -1...1)) }
let name = model.modelDescription.inputDescriptionsByName.keys.first!
let provider = try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: input)])
let firstStarted = ContinuousClock.now
_ = try await model.prediction(from: provider)
print("first prediction \(arguments[4]): \(ms(ContinuousClock.now - firstStarted))")
var times: [Duration] = []
for _ in 0..<runs {
    let started = ContinuousClock.now
    _ = try await model.prediction(from: provider)
    times.append(ContinuousClock.now - started)
}
times.sort()
print("warm prediction \(arguments[4]): p50 \(ms(times[times.count / 2])), min \(ms(times[0]))")
