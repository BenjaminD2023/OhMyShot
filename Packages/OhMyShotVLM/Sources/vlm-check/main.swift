// vlm-check MODEL_DIR STAGES.safetensors IMAGE.png [VOCABULARY.json]
//
// Reads IMAGE with the Swift PaddleOCR-VL and compares each stage with what Tools/l3-spike/vlm_stages.py wrote for the
// same picture: the pixels (exactly), the prompt's tokens and positions (exactly), the vision tower's stages and the
// first logits (largest difference), and the greedy tokens.

import CoreGraphics
import Foundation
import ImageIO
import MLX
import MLXNN
@testable import OMSVLM

let arguments = Array(CommandLine.arguments.dropFirst())

// vlm-check read PACK_DIR TASK OUT.json IMAGE...: each picture read as TASK, written as Tools/l3-spike/vlm_mlx.py writes
// its results ({name: {"text", "tokens", "wall"}}), for vlm_score.py.
if arguments.first == "read", arguments.count >= 5 {
    let reader = try PaddleOCRVLReader.load(from: URL(filePath: arguments[1]))
    let task = PaddleOCRVLReader.Task(rawValue: arguments[2])!
    var results: [String: [String: String]] = [:]
    var walls: [Double] = []
    for path in arguments.dropFirst(4) {
        let url = URL(filePath: path)
        let start = ContinuousClock.now
        let reading = try reader.read(fileAt: url, task: task)
        let wall = Double((ContinuousClock.now - start).components.attoseconds) / 1e18 + Double((ContinuousClock.now - start).components.seconds)
        walls.append(wall)
        results[url.deletingPathExtension().lastPathComponent] = ["text": reading.text, "tokens": "\(reading.tokens)", "wall": "\(wall)", "ending": reading.ending.rawValue]
        print(String(format: "%@: %.2f s, %d tokens (%@)", url.lastPathComponent, wall, reading.tokens, reading.ending.rawValue))
    }
    try JSONEncoder().encode(results).write(to: URL(filePath: arguments[3]))
    walls.sort()
    print(String(format: "p50 %.2f s, p95 %.2f s, MLX peak %.2f GB", walls[walls.count / 2], walls[min(walls.count - 1, Int(Double(walls.count) * 0.95))], Double(Memory.peakMemory) / 1e9))
    exit(0)
}

guard arguments.count >= 3 else {
    print("vlm-check MODEL_DIR STAGES.safetensors IMAGE.png [VOCABULARY.json]")
    exit(2)
}
let folder = URL(filePath: arguments[0])
let stages = try loadArrays(url: URL(filePath: arguments[1]))
guard let source = CGImageSourceCreateWithURL(URL(filePath: arguments[2]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("no image") }

func report(_ name: String, _ ours: MLXArray, _ theirs: MLXArray?) {
    guard let theirs else { print("\(name): not in the stages"); return }
    let a = ours.asType(.float32), b = theirs.asType(.float32)
    guard a.shape == b.shape else { print("\(name): shape \(a.shape) vs \(b.shape)"); return }
    let difference = abs(a - b).max().item(Float.self)
    let scale = abs(b).max().item(Float.self)
    let mean = abs(a - b).mean().item(Float.self), meanValue = abs(b).mean().item(Float.self)
    print("\(name): \(a.shape) max difference \(difference) (largest value \(scale)), mean \(mean) (mean value \(meanValue))")
}

var clock = ContinuousClock.now
let picture = try PaddleOCRVLPicture(image)
print("picture \(picture.height)x\(picture.width) patches, \(picture.tokens) tokens, \(ContinuousClock.now - clock)")
let pixels = MLXArray(picture.values, [picture.height * picture.width, 3, 14, 14])
let theirPixels = stages["pixel_values"]!.reshaped(-1, 3, 14, 14)
let pixelDifference = abs(pixels - theirPixels).max().item(Float.self)
print("pixel values: max difference \(pixelDifference)", pixelDifference == 0 ? "(equal)" : "(DIFFERENT)")
let grid = stages["grid_thw"]!.asArray(Int32.self)
print("grid \(grid) vs ours [1, \(picture.height), \(picture.width)]")

clock = .now
let reader = try PaddleOCRVL.load(from: folder)
print("loaded in \(ContinuousClock.now - clock)")
let modelType = reader.model.visual.embeddings.patchEmbedding.weight.dtype
report("pixels in the model's type", pixels.asType(modelType), stages["pixels_model_dtype"].map { $0.reshaped(-1, 3, 14, 14) })

let theirIDs = stages["input_ids"]!.asArray(Int32.self).map(Int.init)
let first = theirIDs.firstIndex(of: reader.configuration.imageToken)!
let last = theirIDs.lastIndex(of: reader.configuration.imageToken)!
let prompt = PaddleOCRVL.Prompt(before: Array(theirIDs[..<first]), after: Array(theirIDs[(last + 1)...]))
print("prompt before \(prompt.before) after \(prompt.after)")
let tokens = reader.tokens(prompt, picture: picture)
print("tokens", tokens == theirIDs ? "equal" : "DIFFERENT (\(tokens.count) vs \(theirIDs.count))")
let (positions, delta) = reader.positions(tokens, picture: picture)
let theirPositions = stages["position_ids"]!.reshaped(3, -1).asArray(Int32.self)
print("positions", positions.flatMap { $0 } == theirPositions ? "equal" : "DIFFERENT", "delta \(delta) vs \(stages["rope_deltas"]!.asArray(Int32.self))")

let visual = reader.model.visual
let patches = pixels.asType(modelType)
let (h, w) = (picture.height, picture.width)
report("position embeddings", visual.embeddings.positions(height: h, width: w), stages["position_embeddings"])
var hidden = visual.embeddings(patches, height: h, width: w)
report("embeddings", hidden, stages["embeddings"])
let angles = visual.rotaryAngles(height: h, width: w)
report("vision rotary", angles, stages["vision_rotary"])
let cos = tiled(MLX.cos(angles).expandedDimensions(axis: 1), repetitions: [1, 1, 2]).expandedDimensions(axis: 0)
let sin = tiled(MLX.sin(angles).expandedDimensions(axis: 1), repetitions: [1, 1, 2]).expandedDimensions(axis: 0)
for (index, layer) in visual.layers.enumerated() {
    hidden = layer(hidden, cos: cos, sin: sin)
    if index == 0 { report("layer 0", hidden, stages["layer0"]) }
}
hidden = visual.postNorm(hidden)
report("after the last norm", hidden, stages["post_layernorm"])
report("projector", visual.projector(hidden, height: h, width: w), stages["projector"])

report("vision tower", reader.seen(picture), stages["vision_whole"])

clock = .now
let (read, ending) = reader.read(picture, prompt: prompt, maximum: 256)
let elapsed = ContinuousClock.now - clock
let theirTokens = stages["tokens"]!.asArray(Int32.self).map(Int.init).filter { $0 != reader.configuration.endToken }
let same = zip(read, theirTokens).prefix { $0 == $1 }.count
print("read \(read.count) tokens (\(ending)) in \(elapsed); Python \(theirTokens.count); the same for the first \(same)")
if arguments.count > 3 {
    let vocabulary = try PaddleOCRVLTokens(contentsOf: URL(filePath: arguments[3]))
    print("--- ours\n\(vocabulary.text(read))")
    if same < max(read.count, theirTokens.count) { print("--- Python\n\(vocabulary.text(theirTokens))") }
}
