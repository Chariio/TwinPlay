// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// #19 iCloud saves: decision table and the engine on temporary folders ("cloud" = a plain folder).
final class CloudSaveSyncTests: XCTestCase {
    typealias A = CloudSyncAction
    let s1 = CloudFileStat(mtime: 1000, size: 10)
    let s2 = CloudFileStat(mtime: 2000, size: 10)
    let s3 = CloudFileStat(mtime: 3000, size: 12)

    func testDecisionTable() {
        XCTAssertEqual(A.decide(local: nil, cloud: nil, record: nil), .forget)
        XCTAssertEqual(A.decide(local: s1, cloud: nil, record: nil), .upload, "new local file goes up")
        XCTAssertEqual(A.decide(local: nil, cloud: s1, record: nil), .download, "new device gets the cloud file")
        XCTAssertEqual(A.decide(local: s1, cloud: s1, record: nil), .resolveConflict, "first meeting: compare / newest wins")
        let r = CloudSyncRecord(local: s1, cloud: s1)
        XCTAssertEqual(A.decide(local: s1, cloud: s1, record: r), .nothing)
        XCTAssertEqual(A.decide(local: s2, cloud: s1, record: r), .upload)
        XCTAssertEqual(A.decide(local: s1, cloud: s2, record: r), .download)
        XCTAssertEqual(A.decide(local: s2, cloud: s3, record: r), .resolveConflict)
        XCTAssertEqual(A.decide(local: nil, cloud: s1, record: r), .deleteCloud, "deleted here on purpose")
        XCTAssertEqual(A.decide(local: nil, cloud: s2, record: r), .download, "changed elsewhere after the delete: keep it")
    }

    func testCloudMissingNeverDeletesLocal() {
        let r = CloudSyncRecord(local: s1, cloud: s1)
        XCTAssertEqual(A.decide(local: s1, cloud: nil, record: r), .nothing, "keeps the local file, no delete")
        XCTAssertEqual(A.decide(local: s2, cloud: nil, record: r), .upload, "changed here: goes back up")
        for l in [s1, s2, s3] { for c in [nil, s1] as [CloudFileStat?] {
            XCTAssertNotEqual(A.decide(local: l, cloud: c, record: r), .forget)
        } }
    }

    func testNewestWins() {
        XCTAssertTrue(A.cloudWins(local: s1, cloud: s2))
        XCTAssertFalse(A.cloudWins(local: s2, cloud: s1))
        XCTAssertFalse(A.cloudWins(local: s1, cloud: s1), "tie keeps local")
    }

    func testSyncableFiles() {
        XCTAssertTrue(CloudSyncFolder.saves.isSyncable("Pokemon.sav"))
        XCTAssertFalse(CloudSyncFolder.saves.isSyncable("Pokemon.sav.bak"))
        XCTAssertFalse(CloudSyncFolder.saves.isSyncable(".Pokemon.sav.icloud"))
        XCTAssertTrue(CloudSyncFolder.states.isSyncable("Pokemon.slot1.state"))
        XCTAssertTrue(CloudSyncFolder.states.isSyncable("Pokemon.slot1.png"))
        XCTAssertFalse(CloudSyncFolder.states.isSyncable("notes.txt"))
    }

    // MARK: Engine on folders

    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A device: its Documents folder and its own manifest; all devices share `root/cloud`.
    private func device(_ name: String) -> CloudSyncEngine {
        CloudSyncEngine(localRoot: root.appendingPathComponent(name), cloudRoot: root.appendingPathComponent("cloud"),
                        backupRoot: root.appendingPathComponent(name).appendingPathComponent("iCloud Backups"),
                        manifestURL: root.appendingPathComponent(name).appendingPathComponent("manifest.json"))
    }
    private func write(_ e: CloudSyncEngine, _ key: String, _ text: String, at t: Double) throws {
        let u = e.localRoot.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: u.path)
    }
    private func read(_ e: CloudSyncEngine, _ key: String) -> String? {
        (try? Data(contentsOf: e.localRoot.appendingPathComponent(key))).map { String(decoding: $0, as: UTF8.self) }
    }
    private func backups(_ e: CloudSyncEngine, _ folder: String = "Saves") -> [String] {
        let dir = e.backupRoot.appendingPathComponent(folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().map {
            String(decoding: (try? Data(contentsOf: dir.appendingPathComponent($0))) ?? Data(), as: UTF8.self)
        }
    }

    func testSaveTravelsBetweenDevices() throws {
        let duo = device("duo"), pro = device("pro")
        try write(duo, "Saves/Pokemon.sav", "badge1", at: 1000)
        try write(duo, "States/Pokemon.slot1.state", "state", at: 1000)
        try write(duo, "States/Pokemon.slot1.png", "thumb", at: 1000)
        XCTAssertEqual(duo.sync().uploaded, 3)
        XCTAssertEqual(pro.sync().downloaded, 3)
        XCTAssertEqual(read(pro, "Saves/Pokemon.sav"), "badge1")
        XCTAssertEqual(read(pro, "States/Pokemon.slot1.png"), "thumb")
        // Play on the Pro, come back to the Duo.
        try write(pro, "Saves/Pokemon.sav", "badge2", at: 2000)
        XCTAssertEqual(pro.sync().uploaded, 1)
        let r = duo.sync()
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(read(duo, "Saves/Pokemon.sav"), "badge2")
        XCTAssertEqual(backups(duo), ["badge1"], "the replaced local save is kept")
        XCTAssertFalse(duo.sync().changed, "stable afterwards")
        XCTAssertFalse(pro.sync().changed)
    }

    func testConflictNewestWinsAndLoserIsBackedUp() throws {
        let duo = device("duo"), pro = device("pro")
        try write(duo, "Saves/Zelda.sav", "v1", at: 1000)
        duo.sync(); pro.sync()
        try write(duo, "Saves/Zelda.sav", "duo-older", at: 2000)
        try write(pro, "Saves/Zelda.sav", "pro-newer", at: 3000)
        duo.sync()                                    // duo uploads first
        let r = pro.sync()                            // pro: both changed, pro is newer
        XCTAssertEqual(r.conflicts, 1)
        XCTAssertEqual(read(pro, "Saves/Zelda.sav"), "pro-newer")
        XCTAssertEqual(backups(pro), ["duo-older"], "the older iCloud copy is kept on the Pro")
        duo.sync()
        XCTAssertEqual(read(duo, "Saves/Zelda.sav"), "pro-newer")
        XCTAssertEqual(backups(duo), ["duo-older"])
    }

    func testFirstSyncWithDifferentFilesKeepsBoth() throws {
        let duo = device("duo"), pro = device("pro")
        try write(duo, "Saves/Mario.sav", "duo", at: 5000)
        try write(pro, "Saves/Mario.sav", "pro", at: 4000)
        duo.sync()
        pro.sync()                                   // no record yet: newest (duo) wins
        XCTAssertEqual(read(pro, "Saves/Mario.sav"), "duo")
        XCTAssertEqual(backups(pro), ["pro"])
    }

    func testIdenticalFilesNeedNoCopyOrBackup() throws {
        let duo = device("duo"), pro = device("pro")
        try write(duo, "Saves/Mario.sav", "same", at: 5000)
        try write(pro, "Saves/Mario.sav", "same", at: 4000)
        duo.sync()
        let r = pro.sync()
        XCTAssertEqual(r.backups, 0)
        XCTAssertFalse(r.changed)
    }

    func testCloudFileMissingNeverDeletesLocal() throws {
        let duo = device("duo")
        try write(duo, "Saves/Kirby.sav", "mine", at: 1000)
        duo.sync()
        try FileManager.default.removeItem(at: duo.cloudRoot.appendingPathComponent("Saves/Kirby.sav"))
        duo.sync()
        XCTAssertEqual(read(duo, "Saves/Kirby.sav"), "mine")
        // An empty / wiped cloud with a fresh manifest uploads it again.
        let fresh = CloudSyncEngine(localRoot: duo.localRoot, cloudRoot: duo.cloudRoot, backupRoot: duo.backupRoot,
                                    manifestURL: root.appendingPathComponent("other.json"))
        XCTAssertEqual(fresh.sync().uploaded, 1)
    }

    func testDeletedSlotIsRemovedFromCloudWithBackup() throws {
        let duo = device("duo"), pro = device("pro")
        try write(duo, "States/Kirby.slot2.state", "s", at: 1000)
        duo.sync(); pro.sync()
        try FileManager.default.removeItem(at: duo.localRoot.appendingPathComponent("States/Kirby.slot2.state"))
        XCTAssertEqual(duo.sync().deletedInCloud, 1)
        XCTAssertEqual(backups(duo, "States"), ["s"])
        pro.sync()
        XCTAssertEqual(read(pro, "States/Kirby.slot2.state"), "s", "other devices keep their copy")
        XCTAssertNil(read(duo, "States/Kirby.slot2.state"), "and it does not come back here")
    }

    func testRunningGameSaveIsNotReplaced() throws {
        let duo = device("duo"), pro = device("pro")
        try write(duo, "Saves/Metroid.sav", "a", at: 1000)
        duo.sync(); pro.sync()
        try write(pro, "Saves/Metroid.sav", "b", at: 2000); pro.sync()
        duo.isBusy = { $0 == "Saves/Metroid.sav" }
        XCTAssertEqual(duo.sync().waiting, 1)
        XCTAssertEqual(read(duo, "Saves/Metroid.sav"), "a")
        duo.isBusy = { _ in false }
        duo.sync()
        XCTAssertEqual(read(duo, "Saves/Metroid.sav"), "b")
    }

    func testBackupsArePrunedToNewestThree() throws {
        let duo = device("duo"), pro = device("pro")
        try write(duo, "Saves/Tetris.sav", "v0", at: 1000)
        duo.sync(); pro.sync()
        for i in 1...5 {
            try write(pro, "Saves/Tetris.sav", "v\(i)", at: 1000 + Double(i) * 100); pro.sync()
            duo.sync()
        }
        XCTAssertEqual(read(duo, "Saves/Tetris.sav"), "v5")
        XCTAssertEqual(backups(duo), ["v2", "v3", "v4"])
    }

    func testManifestPersists() throws {
        let duo = device("duo")
        try write(duo, "Saves/Pong.sav", "x", at: 1000)
        duo.sync()
        let again = device("duo")
        XCTAssertFalse(again.sync().changed)
    }
}
