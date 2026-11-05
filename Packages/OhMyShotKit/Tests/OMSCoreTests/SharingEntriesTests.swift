import Foundation
import Testing
@testable import OMSCore

/// The upload entries a capture's menu and VoiceOver actions offer, on a Quick Access card and in History.
struct SharingEntriesTests {
    private let work = UploadTarget(id: UUID(), name: "Work", isDefault: false)
    private let home = UploadTarget(id: UUID(), name: "Home", isDefault: true)

    @Test func withNoDestinationNothingIsOffered() {
        #expect(UploadMenu.hidden.entries(state: .idle, hasLink: false, canDelete: false).isEmpty)
    }

    @Test func oneDestinationIsAPlainUpload() {
        #expect(UploadMenu.upload.entries(state: .idle, hasLink: false, canDelete: false) == [.upload(named: nil)])
    }

    /// With several, Upload says where it goes, and Upload To lists every destination.
    @Test func severalDestinationsNameTheDefaultAndOfferTheChoice() {
        let menu = UploadMenu(targets: [work, home])
        #expect(menu.entries(state: .idle, hasLink: false, canDelete: false) == [.upload(named: "Home"), .uploadTo([work, home])])
    }

    @Test func theDefaultTargetIsTheDefaultElseTheFirst() {
        #expect(UploadMenu(targets: [work, home]).defaultTarget == home)
        let other = UploadTarget(id: UUID(), name: "Other", isDefault: false)
        #expect(UploadMenu(targets: [work, other]).defaultTarget == work)
        #expect(UploadMenu.upload.defaultTarget == nil)
        #expect(UploadMenu.hidden.defaultTarget == nil)
    }

    @Test func anUploadUnderWayCanOnlyBeCancelled() {
        let menu = UploadMenu(targets: [work, home])
        #expect(menu.entries(state: .uploading, hasLink: false, canDelete: false) == [.cancelUpload])
    }

    /// Retrying is uploading again: once the last destination is gone, only the error can be copied.
    @Test func aFailedUploadOffersRetryWhileThereIsADestination() {
        #expect(UploadMenu.upload.entries(state: .failed, hasLink: false, canDelete: false) == [.retryUpload, .copyError])
        #expect(UploadMenu.hidden.entries(state: .failed, hasLink: false, canDelete: false) == [.copyError])
    }

    /// A link and an upload in storage outlive the destinations: they are offered without one.
    @Test func theLinkAndTheStorageComeLast() {
        #expect(UploadMenu.hidden.entries(state: .idle, hasLink: true, canDelete: true) == [.copyLink, .deleteFromStorage])
        #expect(UploadMenu.upload.entries(state: .uploading, hasLink: true, canDelete: false) == [.cancelUpload, .copyLink])
        #expect(UploadMenu.upload.entries(state: .idle, hasLink: false, canDelete: true) == [.upload(named: nil), .deleteFromStorage])
    }
}
