// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation
import UIKit

// #19 iCloud saves. Cartridge saves (Documents/Saves) and save states with their thumbnails
// (Documents/States) are mirrored into TwinPlay's private iCloud container
// (iCloud.com.charlie.dsemu, folders Saves/ and States/), so every device signed in to the same
// Apple Account sees the same saves. Rules:
//  • The local files are the source of truth: the game always reads and writes the local copy;
//    without iCloud (signed out, iCloud Drive off, setting off) nothing changes.
//  • A local file is never deleted or replaced without first copying the old version to
//    Documents/iCloud Backups (newest 3 per file), visible in the Files app.
//  • A file missing from iCloud never deletes the local copy.
//  • Both sides changed since the last sync: the newer file wins, the other one is backed up.
//  • The cartridge save of the game being played is never replaced while it runs.

/// Size and modification time of one file.
struct CloudFileStat: Codable, Equatable {
    var mtime: Double
    var size: Int64

    init(mtime: Double, size: Int64) { self.mtime = mtime; self.size = size }
    init(date: Date, size: Int64) { self.init(mtime: date.timeIntervalSince1970, size: size) }

    /// Same file as last seen (10 ms tolerance for file-system timestamp rounding).
    func matches(_ other: CloudFileStat?) -> Bool {
        guard let other else { return false }
        return size == other.size && abs(mtime - other.mtime) < 0.01
    }
}

/// What both sides looked like right after the last successful sync of a file.
struct CloudSyncRecord: Codable, Equatable {
    var local: CloudFileStat?
    var cloud: CloudFileStat?
}

/// What to do with one file (pure, unit-tested).
enum CloudSyncAction: Equatable {
    case nothing
    case upload            // local is new or changed; iCloud copy is unchanged (or missing)
    case download          // iCloud copy is new or changed; local is unchanged (or missing)
    case resolveConflict   // both changed (or first meeting with different files): newest wins, loser backed up
    case deleteCloud       // deleted here on purpose; iCloud copy unchanged since: remove it there (backed up first)
    case forget            // gone on both sides

    static func decide(local: CloudFileStat?, cloud: CloudFileStat?, record: CloudSyncRecord?) -> CloudSyncAction {
        switch (local, cloud) {
        case (nil, nil):
            return .forget
        case (let l?, nil):
            // Removed from iCloud by another device: keep the local file (never deleted because
            // the cloud copy is missing) but don't push it back unless it changes here.
            if let record, l.matches(record.local) { return .nothing }
            return .upload
        case (nil, let c?):
            guard let record, record.local != nil else { return .download }
            return c.matches(record.cloud) ? .deleteCloud : .download
        case (let l?, let c?):
            guard let record else { return .resolveConflict }
            let localChanged = !l.matches(record.local)
            let cloudChanged = !c.matches(record.cloud)
            switch (localChanged, cloudChanged) {
            case (false, false): return .nothing
            case (true, false): return .upload
            case (false, true): return .download
            case (true, true): return .resolveConflict
            }
        }
    }

    /// Newest modification wins; a tie keeps the local file.
    static func cloudWins(local: CloudFileStat, cloud: CloudFileStat) -> Bool { cloud.mtime > local.mtime }
}

/// One synced folder (Saves or States) and which of its files take part.
enum CloudSyncFolder: String, CaseIterable {
    case saves = "Saves"
    case states = "States"

    func isSyncable(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !name.hasSuffix(".bak"), !name.hasSuffix(".tmp") else { return false }
        switch self {
        case .saves: return [".sav", ".dsv", ".srm"].contains { name.hasSuffix($0) }   // battery saves
        case .states: return name.hasSuffix(".state") || name.hasSuffix(".png")
        }
    }
}

/// The sync itself, on plain folders so tests can run it against temporary directories.
/// Not thread-safe: run one sync at a time (CloudSaveSync uses a serial queue).
final class CloudSyncEngine {
    let localRoot: URL         // Documents (has Saves/ and States/)
    let cloudRoot: URL         // the iCloud container (gets Saves/ and States/)
    let backupRoot: URL        // Documents/iCloud Backups
    let manifestURL: URL
    var keepBackups = 3
    /// Files that must not be replaced locally right now ("Saves/Game.sav" while it is played).
    var isBusy: (String) -> Bool = { _ in false }
    private let fm = FileManager.default
    private(set) var records: [String: CloudSyncRecord]

    struct Report: Equatable {
        var uploaded = 0, downloaded = 0, conflicts = 0, backups = 0, deletedInCloud = 0
        var waiting = 0              // iCloud files still downloading, or busy files
        var errors: [String] = []
        var changed: Bool { uploaded + downloaded + conflicts + deletedInCloud > 0 }
    }

    init(localRoot: URL, cloudRoot: URL, backupRoot: URL, manifestURL: URL) {
        self.localRoot = localRoot; self.cloudRoot = cloudRoot
        self.backupRoot = backupRoot; self.manifestURL = manifestURL
        if let d = try? Data(contentsOf: manifestURL), let r = try? JSONDecoder().decode([String: CloudSyncRecord].self, from: d) {
            records = r
        } else { records = [:] }
    }

    /// Syncs every file, or only those whose key ("Saves/Game.sav") passes `only`.
    @discardableResult
    func sync(only: ((String) -> Bool)? = nil) -> Report {
        var report = Report()
        for folder in CloudSyncFolder.allCases {
            let localDir = localRoot.appendingPathComponent(folder.rawValue, isDirectory: true)
            let cloudDir = cloudRoot.appendingPathComponent(folder.rawValue, isDirectory: true)
            try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: cloudDir, withIntermediateDirectories: true)
            let localNames = Set(((try? fm.contentsOfDirectory(atPath: localDir.path)) ?? []).filter(folder.isSyncable))
            var cloudNames = Set<String>(), placeholders = Set<String>()
            for raw in (try? fm.contentsOfDirectory(atPath: cloudDir.path)) ?? [] {
                // Not yet downloaded iCloud files show up as ".Name.icloud".
                if raw.hasPrefix("."), raw.hasSuffix(".icloud") {
                    let name = String(raw.dropFirst().dropLast(7))
                    if folder.isSyncable(name) { placeholders.insert(name) }
                } else if folder.isSyncable(raw) { cloudNames.insert(raw) }
            }
            let known = Set(records.keys.filter { $0.hasPrefix(folder.rawValue + "/") }.map { String($0.dropFirst(folder.rawValue.count + 1)) })
            for name in localNames.union(cloudNames).union(placeholders).union(known).sorted() {
                let key = folder.rawValue + "/" + name
                if let only, !only(key) { continue }
                syncFile(key: key, local: localDir.appendingPathComponent(name), cloud: cloudDir.appendingPathComponent(name),
                         placeholder: placeholders.contains(name) && !cloudNames.contains(name), report: &report)
            }
        }
        saveManifest()
        return report
    }

    private func syncFile(key: String, local: URL, cloud: URL, placeholder: Bool, report: inout Report) {
        if placeholder || !isDownloaded(cloud) {
            try? fm.startDownloadingUbiquitousItem(at: cloud)
            report.waiting += 1
            return
        }
        let l = stat(local), c = stat(cloud)
        do {
            switch CloudSyncAction.decide(local: l, cloud: c, record: records[key]) {
            case .nothing: break
            case .forget: records[key] = nil
            case .upload:
                try upload(local, to: cloud)
                report.uploaded += 1
                remember(key, local, cloud)
            case .download:
                guard let c else { break }
                if let l, l.size == c.size, sameContents(local, cloud) { remember(key, local, cloud); break }
                guard !isBusy(key) else { report.waiting += 1; break }
                if l != nil { try backUp(local, key: key, tag: "replaced"); report.backups += 1 }
                try download(cloud, to: local)
                report.downloaded += 1
                remember(key, local, cloud)
            case .resolveConflict:
                guard let l, let c else { break }
                if l.size == c.size, sameContents(local, cloud) { remember(key, local, cloud); break }
                if CloudSyncAction.cloudWins(local: l, cloud: c) {
                    guard !isBusy(key) else { report.waiting += 1; break }
                    try backUp(local, key: key, tag: "older-this-device")
                    try download(cloud, to: local)
                } else {
                    try backUp(cloud, key: key, tag: "older-icloud")
                    try upload(local, to: cloud)
                }
                report.backups += 1; report.conflicts += 1
                remember(key, local, cloud)
            case .deleteCloud:
                try backUp(cloud, key: key, tag: "deleted")
                report.backups += 1
                try coordinate(write: cloud, options: .forDeleting) { try self.fm.removeItem(at: $0) }
                records[key] = nil
                report.deletedInCloud += 1
            }
        } catch {
            report.errors.append("\(key): \(error.localizedDescription)")
        }
    }

    // MARK: Files

    private func stat(_ url: URL) -> CloudFileStat? {
        guard let a = try? fm.attributesOfItem(atPath: url.path), let d = a[.modificationDate] as? Date else { return nil }
        return CloudFileStat(date: d, size: (a[.size] as? NSNumber)?.int64Value ?? 0)
    }

    private func isDownloaded(_ url: URL) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return true }      // nothing there: nothing to wait for
        let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = v?.ubiquitousItemDownloadingStatus else { return true }   // not an iCloud file (tests)
        return status == .current
    }

    private func remember(_ key: String, _ local: URL, _ cloud: URL) {
        records[key] = CloudSyncRecord(local: stat(local), cloud: stat(cloud))
    }

    private func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let da = try? Data(contentsOf: a), let db = try? read(b) else { return false }
        return da == db
    }

    private func read(_ cloud: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var ce: NSError?
        NSFileCoordinator().coordinate(readingItemAt: cloud, options: [], error: &ce) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let ce { throw ce }
        return try result.get()
    }

    private func coordinate(write url: URL, options: NSFileCoordinator.WritingOptions, _ body: @escaping (URL) throws -> Void) throws {
        var thrown: Error?
        var ce: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &ce) { u in
            do { try body(u) } catch { thrown = error }
        }
        if let ce { throw ce }
        if let thrown { throw thrown }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func upload(_ local: URL, to cloud: URL) throws {
        let data = try Data(contentsOf: local)
        let date = modificationDate(local)
        try coordinate(write: cloud, options: .forReplacing) { u in
            try data.write(to: u, options: .atomic)
            if let date { try? self.fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path) }
        }
    }

    private func download(_ cloud: URL, to local: URL) throws {
        let data = try read(cloud)
        let date = modificationDate(cloud)
        try data.write(to: local, options: .atomic)
        if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: local.path) }
    }

    /// Copies a version that is about to be replaced/removed into the backups folder
    /// (Saves/Game.sav → iCloud Backups/Saves/Game.sav.<date>.<tag>), keeping the newest few.
    private func backUp(_ url: URL, key: String, tag: String) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        let data = url.path.hasPrefix(localRoot.path) ? try Data(contentsOf: url) : try read(url)
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        let dir = backupRoot.appendingPathComponent(parts[0], isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = f.string(from: modificationDate(url) ?? Date())
        try data.write(to: dir.appendingPathComponent("\(parts[1]).\(stamp).\(tag)"), options: .atomic)
        prune(dir: dir, name: parts[1])
    }

    private func prune(dir: URL, name: String) {
        let ours = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { b in
            guard b.hasPrefix(name + ".") else { return false }
            let rest = b.dropFirst(name.count + 1)
            return rest.count > 9 && rest.prefix(8).allSatisfy(\.isNumber) && rest.dropFirst(8).first == "-"
        }
        for old in ours.sorted(by: >).dropFirst(keepBackups) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }   // stamps sort by time
    }

    func saveManifest() {
        try? fm.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(records) { try? d.write(to: manifestURL, options: .atomic) }
    }
}

/// App-wide iCloud saves: when to sync, the Settings switch and its status line.
@MainActor final class CloudSaveSync: ObservableObject {
    static let shared = CloudSaveSync()
    static let containerID = "iCloud.com.charlie.dsemu"
    static let enabledKey = "icloudSaves"
    static let lastSyncKey = "icloudSavesLastSync"

    enum Status: Equatable {
        case off, checking, syncing, upToDate, waiting(Int), signedOut, unavailable, failed(String)
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: CloudSaveSync.lastSyncKey) as? Date
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: CloudSaveSync.enabledKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { start(); requestSync(after: 0) } else { stopWatching(); status = .off }
        }
    }

    private let queue = DispatchQueue(label: "TwinPlay.iCloudSaves", qos: .utility)
    private let worker = CloudSyncWorker()
    private var pending: DispatchWorkItem?
    private var started = false
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var retry = 0

    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    private init() {}

    /// Called once at launch: first sync, then keeps watching.
    func start() {
        guard enabled else { status = .off; return }
        if !started {
            started = true
            observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.identityChanged() }
            })
        }
        watchLocalFolders()
        requestSync(after: 0)
    }

    /// The app came to the foreground.
    func foreground() { if enabled { requestSync(after: 0.3) } }

    /// The app went to the background: give the last save / auto state a moment to land, then upload.
    func background() {
        guard enabled else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "iCloud saves") { UIApplication.shared.endBackgroundTask(task) }
        pending?.cancel(); pending = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            CloudSaveSync.shared.runSync(only: nil) { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    /// A save or state was written (the folder watcher also notices).
    func savedLocally() { if enabled { requestSync(after: 2) } }

    /// The cartridge save of the game being played (never replaced while it runs); nil when it ends.
    func setPlaying(saveFile: URL?) {
        worker.setBusy(saveFile.map { [CloudSyncFolder.saves.rawValue + "/" + $0.lastPathComponent] } ?? [])
        if saveFile == nil { savedLocally() }
    }

    /// Before a game starts: fetch its newest save and states from iCloud (gives up after `timeout`).
    func pullBeforePlaying(rom: URL, timeout: Double = 2.5, then open: @escaping @MainActor () -> Void) {
        guard enabled, status != .signedOut, status != .unavailable else { open(); return }
        let base = rom.deletingPathExtension().lastPathComponent
        var done = false
        let finish = { if !done { done = true; open() } }
        Task { @MainActor in try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); finish() }
        runSync(only: { key in key == "Saves/\(base).sav" || key.hasPrefix("States/\(base).slot") }) { finish() }
    }

    func syncNow() { requestSync(after: 0) }

    // MARK: Internals

    private func identityChanged() {
        let w = worker
        queue.async { w.reset() }
        requestSync(after: 0.5)
    }

    private func requestSync(after delay: Double) {
        guard enabled else { return }
        pending?.cancel()
        let item = DispatchWorkItem { Task { @MainActor in CloudSaveSync.shared.runSync(only: nil, completion: nil) } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func runSync(only: ((String) -> Bool)?, completion: (@MainActor () -> Void)?) {
        guard enabled else { completion?(); return }
        if only == nil { status = .syncing }
        let docs = documents, w = worker
        queue.async {
            let result = w.sync(docs: docs, only: only)
            Task { @MainActor in
                CloudSaveSync.shared.finished(result, partial: only != nil)
                completion?()
            }
        }
    }

    fileprivate func finished(_ outcome: CloudSyncWorker.Outcome, partial: Bool) {
        switch outcome {
        case .signedOut: status = .signedOut
        case .unavailable: status = .unavailable
        case .report(let r):
            if query == nil { startQuery() }
            if !partial {
                lastSync = Date()
                UserDefaults.standard.set(lastSync, forKey: Self.lastSyncKey)
            }
            if let e = r.errors.first { status = .failed(e) }
            else if r.waiting > 0 { status = .waiting(r.waiting) }
            else if !partial { status = .upToDate }
            // Files still downloading from iCloud (or busy): look again soon, backing off.
            if r.waiting > 0, retry < 8 { retry += 1; requestSync(after: Double(min(60, 3 << retry))) }
            else if r.waiting == 0 { retry = 0 }
        }
    }

    /// Notices changes other devices make in iCloud.
    private func startQuery() {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        observers.append(NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestSync(after: 2) }
        })
        q.start()
        query = q
    }

    /// Notices saves and states written here (battery-save debounce, save states, auto state).
    private func watchLocalFolders() {
        guard watchers.isEmpty else { return }
        for folder in CloudSyncFolder.allCases {
            let dir = documents.appendingPathComponent(folder.rawValue, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, self.status != .syncing else { return }
                    self.requestSync(after: 3)
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
    }

    private func stopWatching() {
        watchers.forEach { $0.cancel() }; watchers = []
        query?.stop(); query = nil
        pending?.cancel(); pending = nil
    }

    /// One line for Settings.
    var statusText: String {
        switch status {
        case .off: return String(localized: "Off: saves stay on this device only")
        case .checking: return String(localized: "Checking iCloud…")
        case .syncing: return String(localized: "Syncing…")
        case .upToDate, .waiting, .failed:
            var s: String
            if let lastSync {
                s = String(localized: "Last sync \(lastSync.formatted(date: .abbreviated, time: .shortened))")
            } else { s = String(localized: "Up to date") }
            if case .waiting(let n) = status { s += " · " + String(localized: "\(n) files still downloading") }
            if case .failed(let e) = status { s += " · " + e }
            return s
        case .signedOut: return String(localized: "Not signed in to iCloud. Sign in and turn on iCloud Drive in the Settings app; saves stay on this device until then.")
        case .unavailable: return String(localized: "iCloud isn't available for TwinPlay right now (check iCloud Drive in the Settings app). Saves stay on this device.")
        }
    }

    var statusIsGood: Bool {
        switch status { case .upToDate, .syncing, .waiting: return true; default: return false }
    }
}

/// Runs on CloudSaveSync's serial queue: finds the iCloud container and owns the engine.
final class CloudSyncWorker: @unchecked Sendable {
    enum Outcome { case signedOut, unavailable, report(CloudSyncEngine.Report) }
    private let lock = NSLock()
    private var busy = Set<String>()
    private var engine: CloudSyncEngine?

    func setBusy(_ keys: Set<String>) { lock.lock(); busy = keys; lock.unlock() }
    func isBusy(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return busy.contains(key) }
    func reset() { engine = nil }

    func sync(docs: URL, only: ((String) -> Bool)?) -> Outcome {
        let fm = FileManager.default
        guard fm.ubiquityIdentityToken != nil else { engine = nil; return .signedOut }
        if engine == nil {
            guard let container = fm.url(forUbiquityContainerIdentifier: CloudSaveSync.containerID) else { return .unavailable }
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let e = CloudSyncEngine(localRoot: docs, cloudRoot: container,
                                    backupRoot: docs.appendingPathComponent("iCloud Backups", isDirectory: true),
                                    manifestURL: support.appendingPathComponent("iCloudSaves.json"))
            e.isBusy = { [weak self] key in self?.isBusy(key) ?? false }
            engine = e
        }
        return .report(engine!.sync(only: only))
    }
}
