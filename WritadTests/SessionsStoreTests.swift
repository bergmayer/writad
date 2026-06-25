import XCTest
@testable import Writad

@MainActor
final class SessionsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SessionsStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "writad-sessions-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        // observesScenes: false skips the global UIScene observer that
        // the singleton wires up — the test harness has no live scenes.
        store = SessionsStore(defaults: defaults, observesScenes: false)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Codable round-trip

    func test_record_serializationRoundTrip() throws {
        let original = SessionRecord(
            sceneUUID: "scene-1",
            tabs: [
                TabSnapshot(
                    fileBookmark: Data([0x01, 0x02, 0x03]),
                    draftFilename: "draft-1.txt",
                    isPinned: true
                ),
                TabSnapshot(
                    fileBookmark: nil,
                    draftFilename: nil,
                    isPinned: false
                ),
            ],
            activeIndex: 1,
            lastModified: Date(timeIntervalSince1970: 1_700_000_000),
            launchID: "launch-A",
            persistentIdentifier: "pid-abc"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)
        XCTAssertEqual(decoded.sceneUUID, original.sceneUUID)
        XCTAssertEqual(decoded.activeIndex, original.activeIndex)
        XCTAssertEqual(decoded.launchID, original.launchID)
        XCTAssertEqual(decoded.persistentIdentifier, original.persistentIdentifier)
        XCTAssertEqual(decoded.lastModified, original.lastModified)
        XCTAssertEqual(decoded.tabs.count, 2)
        XCTAssertEqual(decoded.tabs[0].fileBookmark, original.tabs[0].fileBookmark)
        XCTAssertEqual(decoded.tabs[0].draftFilename, original.tabs[0].draftFilename)
        XCTAssertTrue(decoded.tabs[0].isPinned)
        XCTAssertFalse(decoded.tabs[1].isPinned)
    }

    // MARK: - save / lookup

    func test_save_replacesPriorRecordForSameSceneUUID() {
        let v1 = makeRecord(sceneUUID: "scene-1", launchID: "L1", tabs: 1)
        let v2 = makeRecord(sceneUUID: "scene-1", launchID: "L1", tabs: 3)
        store.save(v1)
        store.save(v2)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(forScene: "scene-1")?.tabs.count, 3)
    }

    func test_save_newestRecordSortsToFront() {
        let a = makeRecord(sceneUUID: "scene-A", launchID: "L1", tabs: 1)
        let b = makeRecord(sceneUUID: "scene-B", launchID: "L1", tabs: 2)
        store.save(a)
        store.save(b)
        XCTAssertEqual(store.records.first?.sceneUUID, "scene-B")
    }

    func test_remove_byScene_removesRecord() {
        store.save(makeRecord(sceneUUID: "scene-A", launchID: "L1"))
        store.save(makeRecord(sceneUUID: "scene-B", launchID: "L1"))
        store.remove(forScene: "scene-A")
        XCTAssertNil(store.record(forScene: "scene-A"))
        XCTAssertNotNil(store.record(forScene: "scene-B"))
    }

    // MARK: - cap

    func test_save_evictsPastCap() {
        for i in 0..<(SessionsStore.cap + 5) {
            store.save(makeRecord(sceneUUID: "scene-\(i)", launchID: "L1"))
        }
        XCTAssertEqual(store.records.count, SessionsStore.cap)
    }

    // MARK: - persistence

    func test_persistence_recordsSurviveAcrossInstances() {
        store.save(makeRecord(sceneUUID: "scene-A", launchID: "L1"))
        store.save(makeRecord(sceneUUID: "scene-B", launchID: "L1"))
        let fresh = SessionsStore(defaults: defaults, observesScenes: false)
        XCTAssertEqual(fresh.records.map(\.sceneUUID).sorted(), ["scene-A", "scene-B"])
    }

    // MARK: - persistentIdentifier lookup

    func test_hasRecord_forPersistentIdentifier() {
        store.save(makeRecord(
            sceneUUID: "scene-A",
            launchID: "L1",
            persistentIdentifier: "pid-1"
        ))
        XCTAssertTrue(store.hasRecord(forPersistentIdentifier: "pid-1"))
        XCTAssertFalse(store.hasRecord(forPersistentIdentifier: "pid-other"))
    }

    func test_removeRecord_forPersistentIdentifier_dropsRecord() {
        let pid = "pid-doomed"
        store.save(makeRecord(sceneUUID: "scene-A", launchID: "L1", persistentIdentifier: pid))
        store.save(makeRecord(sceneUUID: "scene-B", launchID: "L1", persistentIdentifier: "pid-other"))
        store.removeRecord(forPersistentIdentifier: pid)
        XCTAssertFalse(store.hasRecord(forPersistentIdentifier: pid))
        XCTAssertTrue(store.hasRecord(forPersistentIdentifier: "pid-other"))
    }

    // MARK: - restore sweep

    func test_initiateRestoreSweep_returnsCountOfPriorLaunchRecords() {
        // Simulate a previous launch: two records tagged with a launchID
        // that differs from the store's currentLaunchID.
        let priorLaunch = "previous-launch-id"
        store.save(makeRecord(sceneUUID: "scene-A", launchID: priorLaunch, tabs: 1))
        store.save(makeRecord(sceneUUID: "scene-B", launchID: priorLaunch, tabs: 2))
        // And a current-launch record that must NOT be in the sweep.
        store.save(makeRecord(sceneUUID: "scene-C", launchID: store.currentLaunchID))
        let count = store.initiateRestoreSweep()
        XCTAssertEqual(count, 2)
    }

    func test_initiateRestoreSweep_isIdempotentPerLaunch() {
        store.save(makeRecord(sceneUUID: "scene-A", launchID: "L_prev"))
        _ = store.initiateRestoreSweep()
        XCTAssertEqual(store.initiateRestoreSweep(), 0,
                       "Second call returns 0 — only one scene should seed the queue")
    }

    func test_consumePendingRestore_drainsInFIFOOrder() {
        store.save(makeRecord(
            sceneUUID: "scene-A",
            launchID: "L_prev",
            lastModified: Date(timeIntervalSince1970: 100)
        ))
        store.save(makeRecord(
            sceneUUID: "scene-B",
            launchID: "L_prev",
            lastModified: Date(timeIntervalSince1970: 200)
        ))
        _ = store.initiateRestoreSweep()
        // Older-first per docstring on recordsFromPreviousLaunch.
        XCTAssertEqual(store.consumePendingRestore()?.sceneUUID, "scene-A")
        XCTAssertEqual(store.consumePendingRestore()?.sceneUUID, "scene-B")
        XCTAssertNil(store.consumePendingRestore())
    }

    func test_initiateRestoreSweep_picksMostRecentPriorLaunchOnly() {
        // Two prior launches' records coexist. The sweep should restore
        // only the most recent prior launch's set.
        store.save(makeRecord(sceneUUID: "scene-old", launchID: "L_old",
                              lastModified: Date(timeIntervalSince1970: 100)))
        store.save(makeRecord(sceneUUID: "scene-recent-1", launchID: "L_recent",
                              lastModified: Date(timeIntervalSince1970: 500)))
        store.save(makeRecord(sceneUUID: "scene-recent-2", launchID: "L_recent",
                              lastModified: Date(timeIntervalSince1970: 600)))
        XCTAssertEqual(store.initiateRestoreSweep(), 2,
                       "Only L_recent records get restored; L_old stays dormant")
        let drained = (0..<2).compactMap { _ in store.consumePendingRestore()?.sceneUUID }
        XCTAssertEqual(Set(drained), ["scene-recent-1", "scene-recent-2"])
    }

    // MARK: - consumeOpen (palette/multi-scene gating)

    func test_consumeOpen_isRouterAPI_butLivesInSceneRouterTests() {
        // Documenting that consumeOpen is on SceneRouter, not SessionsStore.
        // Left here intentionally as a breadcrumb for future readers.
    }

    // MARK: - Helpers

    private func makeRecord(
        sceneUUID: String,
        launchID: String,
        tabs: Int = 1,
        lastModified: Date = Date(),
        persistentIdentifier: String? = nil
    ) -> SessionRecord {
        let snapshots = (0..<tabs).map { _ in
            TabSnapshot(fileBookmark: nil, draftFilename: nil, isPinned: false)
        }
        return SessionRecord(
            sceneUUID: sceneUUID,
            tabs: snapshots,
            activeIndex: 0,
            lastModified: lastModified,
            launchID: launchID,
            persistentIdentifier: persistentIdentifier
        )
    }
}
