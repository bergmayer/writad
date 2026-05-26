import SwiftUI
import UniformTypeIdentifiers

/// `FileDocument` conformance required by SwiftUI's `.fileExporter`.
/// Thin wrapper around the serialized snapshot bytes so the rest of
/// the app can stay on the observable `PlainTextDocument`.
struct TextFileWrapperProxy: FileDocument {
    let snapshot: Data

    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.plainText]

    init() {
        self.snapshot = Data()
    }

    init(snapshot: Data) {
        self.snapshot = snapshot
    }

    init(configuration: ReadConfiguration) throws {
        self.snapshot = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
