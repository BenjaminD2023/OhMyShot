import CoreML
import Foundation

/// A model pack's Core ML model, compiled once into the pack's own folder (`Compiled/`), never to a temporary place:
/// the Neural Engine keeps what it compiles for a model by its path, so only the first load of a pack takes seconds.
enum PackModel {
    static func load(_ file: String, in folder: URL, units: MLComputeUnits) async throws -> MLModel {
        let compiledFolder = folder.appending(path: "Compiled", directoryHint: .isDirectory)
        let compiled = compiledFolder.appending(path: (file as NSString).deletingPathExtension + ".mlmodelc", directoryHint: .isDirectory)
        let manager = FileManager.default
        if !manager.fileExists(atPath: compiled.path(percentEncoded: false)) {
            let made = try await MLModel.compileModel(at: folder.appending(path: file))
            try manager.createDirectory(at: compiledFolder, withIntermediateDirectories: true)
            do {
                try manager.moveItem(at: made, to: compiled)
            } catch where manager.fileExists(atPath: compiled.path(percentEncoded: false)) {
                // Compiled meanwhile by another reader: that one is kept.
                try? manager.removeItem(at: made)
            }
        }
        let options = MLModelConfiguration()
        options.computeUnits = units
        return try await MLModel.load(contentsOf: compiled, configuration: options)
    }

    /// A pack's "computeUnits".
    static func units(_ name: String) -> MLComputeUnits {
        switch name {
        case "cpuOnly": .cpuOnly
        case "cpuAndGPU": .cpuAndGPU
        case "all": .all
        default: .cpuAndNeuralEngine
        }
    }
}
