import CoreGraphics
import Foundation
import Testing
@testable import OMSCore

struct TextReaderWireTests {
    @Test func persistentCompatibilityJobRoundTripsAllForkFields() throws {
        let job = TextReaderWire.Job(
            id: "compatibility", path: "/tmp/picture.tiff", pressure: .normal,
            visionCompatibility: false, reusesProcess: true,
            visionFormulas: [.init(kind: .inline, box: .zero, latex: "x")],
            visionInputLines: Data("exact lines".utf8)
        )
        let decoded = try JSONDecoder().decode(TextReaderWire.Job.self, from: JSONEncoder().encode(job))
        #expect(decoded.visionCompatibility == false)
        #expect(decoded.reusesProcess == true)
        #expect(decoded.visionFormulas == job.visionFormulas)
        #expect(decoded.visionInputLines == job.visionInputLines)
        let answer = TextReaderWire.Answer(id: job.id, visionLines: job.visionInputLines, retire: true)
        #expect(try JSONDecoder().decode(TextReaderWire.Answer.self, from: JSONEncoder().encode(answer)) == answer)
        #expect(answer.progress == nil)
    }
}
