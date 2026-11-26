import Foundation
import UniformTypeIdentifiers

/// Exports and imports standalone `.omsstudio` project packages containing a Studio recording's source movie,
/// telemetry, project settings, and optional sidecar assets (camera, separate audio tracks, custom background image).
nonisolated public enum StudioPackage {
    public static let fileExtension = "omsstudio"
    public static var contentType: UTType {
        UTType(filenameExtension: fileExtension, conformingTo: .package) ?? .folder
    }
    public static let movieFileName = "movie.mp4"

    public enum PackageError: LocalizedError, Equatable, Sendable {
        case invalidPackage
        case missingMovie
        case missingTelemetry
        case invalidFileName

        public var errorDescription: String? {
            switch self {
            case .invalidPackage:
                String(localized: "This file isn’t a valid OhMyShot Studio project package.", bundle: .module)
            case .missingMovie:
                String(localized: "The project package is missing its recorded movie.", bundle: .module)
            case .missingTelemetry:
                String(localized: "The project package is missing its recording telemetry.", bundle: .module)
            case .invalidFileName:
                String(localized: "The project references an invalid asset filename.", bundle: .module)
            }
        }
    }

    private static let optionalSidecars: [String] = [
        StudioFiles.camera,
        StudioFiles.systemAudio,
        StudioFiles.microphone,
    ]

    /// Stages a self-contained `.omsstudio` package directory and replaces `destinationURL` atomically.
    public static func export(
        sourceMovie: URL, studioFolder: URL, project: StudioProject, to destinationURL: URL
    ) throws {
        let fm = FileManager.default
        guard isRegularFile(at: sourceMovie, fm: fm) else { throw PackageError.missingMovie }
        let telemetryURL = studioFolder.appending(path: StudioFiles.telemetry)
        guard isRegularFile(at: telemetryURL, fm: fm) else { throw PackageError.missingTelemetry }

        var backgroundAsset: String?
        if case .picture(let name) = project.background {
            guard StudioFiles.isValidAssetName(name) else { throw PackageError.invalidFileName }
            backgroundAsset = name
        }

        let parent = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging: URL
        let localStaging = parent.appending(path: ".\(UUID().uuidString).\(fileExtension).tmp")
        if (try? fm.createDirectory(at: localStaging, withIntermediateDirectories: true)) != nil {
            staging = localStaging
        } else {
            let tempStaging = fm.temporaryDirectory.appending(path: "\(UUID().uuidString).\(fileExtension).tmp")
            try fm.createDirectory(at: tempStaging, withIntermediateDirectories: true)
            staging = tempStaging
        }

        var moved = false
        defer {
            if !moved { try? fm.removeItem(at: staging) }
        }

        try fm.copyItem(at: sourceMovie, to: staging.appending(path: movieFileName))
        try fm.copyItem(at: telemetryURL, to: staging.appending(path: StudioFiles.telemetry))

        let projectData = try JSONEncoder().encode(project)
        try projectData.write(to: staging.appending(path: StudioFiles.project), options: .atomic)

        for name in optionalSidecars {
            let source = studioFolder.appending(path: name)
            if isRegularFile(at: source, fm: fm) {
                try fm.copyItem(at: source, to: staging.appending(path: name))
            }
        }

        if let backgroundAsset {
            let source = studioFolder.appending(path: backgroundAsset)
            if isRegularFile(at: source, fm: fm) {
                try fm.copyItem(at: source, to: staging.appending(path: backgroundAsset))
            }
        }

        if fm.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            do {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: staging)
            } catch {
                try fm.removeItem(at: destinationURL)
                try fm.moveItem(at: staging, to: destinationURL)
            }
        } else {
            try fm.moveItem(at: staging, to: destinationURL)
        }
        moved = true
    }

    /// Validates an `.omsstudio` package directory and copies its movie, telemetry, project, and optional assets
    /// into `movieURL` and `studioFolder`.
    public static func importPackage(
        at packageURL: URL, toMovieURL movieURL: URL, studioFolder: URL
    ) throws -> (telemetry: StudioTelemetry, project: StudioProject) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: packageURL.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PackageError.invalidPackage
        }

        let packageMovie = packageURL.appending(path: movieFileName)
        guard isRegularFile(at: packageMovie, fm: fm) else { throw PackageError.missingMovie }

        let packageTelemetry = packageURL.appending(path: StudioFiles.telemetry)
        guard isRegularFile(at: packageTelemetry, fm: fm) else { throw PackageError.missingTelemetry }

        let telemetry: StudioTelemetry
        do {
            let data = try Data(contentsOf: packageTelemetry)
            telemetry = try JSONDecoder().decode(StudioTelemetry.self, from: data)
        } catch {
            throw PackageError.invalidPackage
        }

        let packageProject = packageURL.appending(path: StudioFiles.project)
        let project: StudioProject
        if fm.fileExists(atPath: packageProject.path(percentEncoded: false)) {
            guard isRegularFile(at: packageProject, fm: fm) else { throw PackageError.invalidPackage }
            do {
                let data = try Data(contentsOf: packageProject)
                project = try JSONDecoder().decode(StudioProject.self, from: data)
            } catch {
                throw PackageError.invalidPackage
            }
        } else {
            project = StudioProject()
        }

        var backgroundAsset: String?
        if case .picture(let name) = project.background {
            guard StudioFiles.isValidAssetName(name) else { throw PackageError.invalidFileName }
            backgroundAsset = name
        }

        try fm.createDirectory(at: movieURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: studioFolder, withIntermediateDirectories: true)

        try copyReplacing(from: packageMovie, to: movieURL, fm: fm)
        try copyReplacing(from: packageTelemetry, to: studioFolder.appending(path: StudioFiles.telemetry), fm: fm)

        let projectData = try JSONEncoder().encode(project)
        try projectData.write(to: studioFolder.appending(path: StudioFiles.project), options: .atomic)

        for name in optionalSidecars {
            let source = packageURL.appending(path: name)
            if isRegularFile(at: source, fm: fm) {
                try copyReplacing(from: source, to: studioFolder.appending(path: name), fm: fm)
            }
        }

        if let backgroundAsset {
            let source = packageURL.appending(path: backgroundAsset)
            if isRegularFile(at: source, fm: fm) {
                try copyReplacing(from: source, to: studioFolder.appending(path: backgroundAsset), fm: fm)
            }
        }

        return (telemetry, project)
    }

    private static func isRegularFile(at url: URL, fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func copyReplacing(from source: URL, to destination: URL, fm: FileManager) throws {
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}
