// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// The stale `{titleId}-loading.flag` guard: parse a title ID, delete only that
/// flag, and recognize the ErrorShaderCacheCrash status text. Uses synthetic
/// NCSD/NCCH headers — no real ROMs.
final class ShaderCacheCrashRecoveryTests: XCTestCase {

    private let land = "0004000000054000"
    private let kart = "0004000000030800"

    func testReadsProgramIdFromNCCH() {
        XCTAssertEqual(ShaderCacheCrashRecovery.titleId(from3DSImage: ncch(titleId: 0x0004000000054000)), land)
    }

    func testReadsProgramIdFromNCSDPartition() {
        XCTAssertEqual(ShaderCacheCrashRecovery.titleId(from3DSImage: ncsd(titleId: 0x0004000000054000)), land)
    }

    func testReadsProgramIdFromNCSDFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp-flag-ncsd-\(UUID().uuidString).cci")
        defer { try? FileManager.default.removeItem(at: url) }
        try! ncsd(titleId: 0x0004000000054000).write(to: url)
        XCTAssertEqual(ShaderCacheCrashRecovery.titleId(from3DSFile: url), land)
    }

    func testRejectsEmptyOrNon3DSData() {
        XCTAssertNil(ShaderCacheCrashRecovery.titleId(from3DSImage: Data()))
        XCTAssertNil(ShaderCacheCrashRecovery.titleId(from3DSImage: Data(repeating: 0, count: 0x200)))
        XCTAssertNil(ShaderCacheCrashRecovery.titleId(from3DSImage: ncch(titleId: 0)))
    }

    func testParsesShaderCacheCrashError() {
        XCTAssertEqual(
            ShaderCacheCrashRecovery.titleId(fromCoreError: "The 3DS core reported an error. 0004000000054000"),
            land
        )
        XCTAssertEqual(
            ShaderCacheCrashRecovery.titleId(fromCoreError: "The 3DS core reported an error. 0004000000054000
"),
            land
        )
        XCTAssertEqual(
            ShaderCacheCrashRecovery.titleId(fromCoreError: "The 3DS core reported an error. 0004000000054000"),
            land
        )
        XCTAssertNil(ShaderCacheCrashRecovery.titleId(fromCoreError: "The 3DS core reported an error."))
        XCTAssertNil(ShaderCacheCrashRecovery.titleId(fromCoreError: "The 3DS core could not load this game."))
        XCTAssertNil(ShaderCacheCrashRecovery.titleId(fromCoreError: "The 3DS core reported an error. 0004000000054000 extra"))
        XCTAssertNil(ShaderCacheCrashRecovery.titleId(fromCoreError: "fatal 0004000000054000"))
    }

    func testFlagPathMatchesAzaharLayout() {
        let user = URL(fileURLWithPath: "/tmp/tp-azahar-user")
        let url = ShaderCacheCrashRecovery.flagPath(titleId: land, userDir: user)
        XCTAssertEqual(
            url?.path,
            "/tmp/tp-azahar-user/shaders/vulkan/pipeline/0004000000054000-loading.flag"
        )
        XCTAssertNil(ShaderCacheCrashRecovery.flagPath(titleId: "not-a-title", userDir: user))
        XCTAssertNil(ShaderCacheCrashRecovery.flagPath(titleId: "000400000005400", userDir: user))
    }

    func testClearsOnlyThatTitlesFlag() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tp-shader-flag-\(UUID().uuidString)")
        let pipeline = root.appendingPathComponent("shaders/vulkan/pipeline", isDirectory: true)
        try! fm.createDirectory(at: pipeline, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let flag = pipeline.appendingPathComponent("0004000000054000-loading.flag")
        let otherFlag = pipeline.appendingPathComponent("0004000000030800-loading.flag")
        let bin = pipeline.appendingPathComponent("0004000000054000-106B1B020009.bin")
        try! Data().write(to: flag)
        try! Data([1, 2, 3]).write(to: otherFlag)
        try! Data([9, 9]).write(to: bin)

        XCTAssertTrue(ShaderCacheCrashRecovery.clearStaleFlag(titleId: land, userDir: root))
        XCTAssertFalse(fm.fileExists(atPath: flag.path))
        XCTAssertTrue(fm.fileExists(atPath: otherFlag.path), "other title flags must stay")
        XCTAssertTrue(fm.fileExists(atPath: bin.path), "pipeline .bin caches must stay")
        XCTAssertEqual(try! Data(contentsOf: bin), Data([9, 9]))

        // Second clear is a no-op.
        XCTAssertFalse(ShaderCacheCrashRecovery.clearStaleFlag(titleId: land, userDir: root))
    }

    func testRefusesToDeleteADirectoryOrInvalidId() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tp-shader-flag-dir-\(UUID().uuidString)")
        let pipeline = root.appendingPathComponent("shaders/vulkan/pipeline", isDirectory: true)
        let asDir = pipeline.appendingPathComponent("0004000000054000-loading.flag", isDirectory: true)
        try! fm.createDirectory(at: asDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        XCTAssertFalse(ShaderCacheCrashRecovery.clearStaleFlag(titleId: land, userDir: root))
        XCTAssertTrue(fm.fileExists(atPath: asDir.path))
        XCTAssertFalse(ShaderCacheCrashRecovery.clearStaleFlag(titleId: "zzzzzzzzzzzzzzzz", userDir: root))
        XCTAssertFalse(ShaderCacheCrashRecovery.clearStaleFlag(titleId: land, userDir: root.appendingPathComponent("missing")))
    }

    // MARK: - Synthetic 3DS headers (not real games)

    private func ncch(titleId: UInt64) -> Data {
        var d = Data(count: 0x200)
        d.replaceSubrange(0x100..<0x104, with: Array("NCCH".utf8))
        var le = titleId.littleEndian
        withUnsafeBytes(of: &le) { d.replaceSubrange(0x118..<0x120, with: $0) }
        return d
    }

    private func ncsd(titleId: UInt64) -> Data {
        // Partition 0 starts at media unit 1 (byte 0x200).
        var d = Data(count: 0x400)
        d.replaceSubrange(0x100..<0x104, with: Array("NCSD".utf8))
        var off: UInt32 = 1
        var len: UInt32 = 1
        withUnsafeBytes(of: &off) { d.replaceSubrange(0x120..<0x124, with: $0) }
        withUnsafeBytes(of: &len) { d.replaceSubrange(0x124..<0x128, with: $0) }
        d.replaceSubrange(0x200..<0x400, with: ncch(titleId: titleId))
        return d
    }
}
