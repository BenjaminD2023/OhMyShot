import Foundation
import Testing
@testable import OMSCore

struct LogTests {
    @Test func aFileErrorsKindLeavesOutTheFileItNames() {
        let error = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/Users/someone/Desktop/Acme Contract.png"])
        #expect(error.localizedDescription.contains("Acme Contract"))
        #expect(Log.kind(of: error) == "NSCocoaErrorDomain 513")
    }

    @Test func aSwiftErrorsKindLeavesOutWhatItCarries() {
        let kind = Log.kind(of: AutomationURLError.invalidParameter(name: "filepath", value: "Acme Contract.png"))
        #expect(kind.hasPrefix("OMSCore.AutomationURLError "))
        #expect(!kind.contains("Acme"))
        #expect(!kind.contains("filepath"))
    }
}
