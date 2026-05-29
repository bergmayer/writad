import XCTest
@testable import Ayyyy

@MainActor
final class RevisionStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RevisionStore!
    private let key = "test-key"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ayyyy-revisions-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RevisionStore(
            supportDirOverride: tempRoot,
            maxRevisions: 5,             // small cap so tests stay fast
            autoCoalesceWindow: 60
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        store = nil
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - original anchor

    func test_recordOriginalIfNeeded_writesOriginalOnce() throws {
        let first = try XCTUnwrap(store.recordOriginalIfNeeded("v0", forKey: key))
        XCTAssertEqual(first.kind, .original)
        let second = try store.recordOriginalIfNeeded("v0-again", forKey: key)
        XCTAssertNil(second, "Subsequent calls return nil — original is sticky")
        let originals = store.entries(forKey: key).filter { $0.kind == .original }
        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(store.loadText(of: originals[0], forKey: key), "v0")
    }

    // MARK: - kinds + coalescing

    func test_recordRevision_manualNeverCoalesces() throws {
        try store.recordOriginalIfNeeded("v0", forKey: key)
        try store.recordRevision("v1", kind: .manual, forKey: key)
        try store.recordRevision("v2", kind: .manual, forKey: key)
        let manuals = store.entries(forKey: key).filter { $0.kind == .manual }
        XCTAssertEqual(manuals.count, 2)
        XCTAssertEqual(store.loadText(of: manuals[0], forKey: key), "v1")
        XCTAssertEqual(store.loadText(of: manuals[1], forKey: key), "v2")
    }

    func test_recordRevision_consecutiveAutosCoalesce() throws {
        try store.recordOriginalIfNeeded("v0", forKey: key)
        try store.recordRevision("a1", kind: .auto, forKey: key)
        try store.recordRevision("a2", kind: .auto, forKey: key)
        try store.recordRevision("a3", kind: .auto, forKey: key)
        let autos = store.entries(forKey: key).filter { $0.kind == .auto }
        XCTAssertEqual(autos.count, 1, "Consecutive autos within window collapse onto one entry")
        XCTAssertEqual(store.loadText(of: autos[0], forKey: key), "a3")
    }

    func test_recordRevision_manualBreaksAutoCoalesceChain() throws {
        try store.recordOriginalIfNeeded("v0", forKey: key)
        try store.recordRevision("a1", kind: .auto, forKey: key)
        try store.recordRevision("m1", kind: .manual, forKey: key)
        try store.recordRevision("a2", kind: .auto, forKey: key)
        let kinds = store.entries(forKey: key).map(\.kind)
        XCTAssertEqual(kinds, [.original, .auto, .manual, .auto])
    }

    func test_recordRevision_autoOutsideWindowDoesNotCoalesce() throws {
        // 0-second coalesce window guarantees every auto adds a fresh entry.
        let strict = RevisionStore(
            supportDirOverride: tempRoot,
            maxRevisions: 10,
            autoCoalesceWindow: 0
        )
        try strict.recordOriginalIfNeeded("v0", forKey: key)
        try strict.recordRevision("a1", kind: .auto, forKey: key)
        try strict.recordRevision("a2", kind: .auto, forKey: key)
        let autos = strict.entries(forKey: key).filter { $0.kind == .auto }
        XCTAssertEqual(autos.count, 2)
    }

    // MARK: - cap

    func test_evict_keepsOriginalAndDropsOldestNonOriginal() throws {
        // maxRevisions is 5 (non-original cap). Write 7 manuals.
        try store.recordOriginalIfNeeded("v0", forKey: key)
        for i in 1...7 {
            try store.recordRevision("v\(i)", kind: .manual, forKey: key)
        }
        let all = store.entries(forKey: key)
        XCTAssertEqual(all.filter { $0.kind == .original }.count, 1,
                       "Original survives every eviction pass")
        let manuals = all.filter { $0.kind == .manual }
        XCTAssertEqual(manuals.count, 5)
        // The two oldest manuals (v1, v2) should be the ones evicted.
        let previews = manuals.map(\.preview)
        XCTAssertFalse(previews.contains("v1"))
        XCTAssertFalse(previews.contains("v2"))
        XCTAssertTrue(previews.contains("v7"))
    }

    func test_clearAll_removesEveryEntryForKey() throws {
        try store.recordOriginalIfNeeded("v0", forKey: key)
        try store.recordRevision("v1", kind: .manual, forKey: key)
        store.clearAll(forKey: key)
        XCTAssertTrue(store.entries(forKey: key).isEmpty)
    }

    // MARK: - keys

    func test_key_forURL_isStableAcrossEqualPaths() {
        let a = URL(fileURLWithPath: "/tmp/foo/bar.txt")
        let b = URL(fileURLWithPath: "/tmp/foo/./bar.txt").standardizedFileURL
        XCTAssertEqual(RevisionStore.key(for: a), RevisionStore.key(for: b))
    }

    func test_key_forURL_differsByPath() {
        XCTAssertNotEqual(
            RevisionStore.key(for: URL(fileURLWithPath: "/tmp/foo.txt")),
            RevisionStore.key(for: URL(fileURLWithPath: "/tmp/bar.txt"))
        )
    }

    func test_keyForUntitledTab_distinctPerUUID() {
        let a = RevisionStore.keyForUntitledTab(UUID())
        let b = RevisionStore.keyForUntitledTab(UUID())
        XCTAssertNotEqual(a, b)
    }

    // MARK: - missing snapshot

    func test_loadText_returnsNilIfSnapshotFileGone() throws {
        try store.recordOriginalIfNeeded("v0", forKey: key)
        let entry = try XCTUnwrap(store.entries(forKey: key).first)
        // Manually delete the snapshot file to simulate disk corruption.
        let snapshotURL = tempRoot
            .appendingPathComponent("Revisions")
            .appendingPathComponent(key)
            .appendingPathComponent("\(entry.index).bin")
        try FileManager.default.removeItem(at: snapshotURL)
        XCTAssertNil(store.loadText(of: entry, forKey: key))
    }

    // MARK: - manifest persistence

    func test_manifest_survivesAcrossStoreInstances() throws {
        try store.recordOriginalIfNeeded("v0", forKey: key)
        try store.recordRevision("v1", kind: .manual, forKey: key)
        let fresh = RevisionStore(
            supportDirOverride: tempRoot,
            maxRevisions: 5,
            autoCoalesceWindow: 60
        )
        let entries = fresh.entries(forKey: key)
        XCTAssertEqual(entries.map(\.kind), [.original, .manual])
        XCTAssertEqual(fresh.loadText(of: entries[1], forKey: key), "v1")
    }
}
