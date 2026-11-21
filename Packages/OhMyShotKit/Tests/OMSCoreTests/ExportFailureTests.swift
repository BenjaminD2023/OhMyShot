import Darwin
import Foundation
import Testing
@testable import OMSCore

struct ExportFailureTests {
    private let folder = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)

    @Test(arguments: [
        (CocoaError(.fileWriteOutOfSpace) as any Error, ExportFailure.Cause.diskFull),
        (CocoaError(.fileWriteVolumeReadOnly), .readOnly),
        (CocoaError(.fileWriteNoPermission), .noAccess),
        (CocoaError(.fileReadNoPermission), .noAccess),
        (CocoaError(.fileReadNoSuchFile), .sourceMissing),
        (CocoaError(.fileNoSuchFile), .folderUnavailable),
        (POSIXError(.ENOSPC), .diskFull),
        (POSIXError(.EROFS), .readOnly),
        (POSIXError(.EACCES), .noAccess),
        (POSIXError(.ENOENT), .folderUnavailable),
        (URLError(.timedOut), .other),
    ])
    func tellsWhatWentWrong(error: any Error, cause: ExportFailure.Cause) {
        let failure = ExportFailure.saving(error, into: folder)
        #expect(failure.cause == cause)
        #expect(!failure.summary.isEmpty)
        #expect(failure.detail == error.localizedDescription)
    }

    @Test func findsTheSystemCallsErrorUnderFoundations() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(ExportFailure.saving(error, into: folder).cause == .diskFull)
    }

    @Test func aFolderOnADiskThatIsGoneIsUnavailableWhateverTheSystemSays() {
        let gone = URL(filePath: "/Volumes/OhMyShot-\(UUID().uuidString)/Screenshots", directoryHint: .isDirectory)
        #expect(ExportFailure.isOnMissingVolume(gone))
        #expect(ExportFailure.saving(CocoaError(.fileWriteNoPermission), into: gone).cause == .folderUnavailable)
        #expect(!ExportFailure.isOnMissingVolume(folder))
        #expect(!ExportFailure.isOnMissingVolume(URL(filePath: "/Volumes", directoryHint: .isDirectory)))
    }

    @Test func aSaveTellsCancellingApartFromFailing() async throws {
        let saved = URL(filePath: "/tmp/saved.png")
        #expect(await SaveOutcome.saving(into: folder) { saved } == .saved(saved))
        #expect(await SaveOutcome.saving(into: folder) { throw CancellationError() } == .cancelled)
        #expect(await SaveOutcome.saving(into: folder) { throw CocoaError(.userCancelled) } == .cancelled)
        let missing = folder.appending(path: "OhMyShot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outcome = await SaveOutcome.saving(into: missing) {
            let file = missing.appending(path: "copy.png")
            try Data([1]).write(to: file)
            return file
        }
        #expect(outcome.url == nil)
        #expect(outcome.failure?.cause == .folderUnavailable)
    }
}
