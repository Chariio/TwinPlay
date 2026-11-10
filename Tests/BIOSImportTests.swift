// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// BIOS slot detection (no real dumps are used: only sizes, names and the fallback rules).
final class BIOSImportTests: XCTestCase {
    func testDetectBySizeAndName() {
        XCTAssertEqual(BIOSStore.detect(Data(count: 4096), name: "biosnds9.rom"), .ds9)
        XCTAssertEqual(BIOSStore.detect(Data(count: 16384), name: "biosnds7.rom"), .ds7)
        XCTAssertEqual(BIOSStore.detect(Data(count: 16384), name: "BIOSGBA.ROM"), .gba)
        XCTAssertEqual(BIOSStore.detect(Data(count: 16384), name: "gba_bios.bin"), .gba)
        XCTAssertNil(BIOSStore.detect(Data(count: 16384), name: "mystery.bin"))
        XCTAssertEqual(BIOSStore.detect(Data(count: 262144), name: "firmware.bin"), .dsFirmware)
        XCTAssertEqual(BIOSStore.detect(Data(count: 256), name: "dmg.bin"), .gbBoot)
        XCTAssertEqual(BIOSStore.detect(Data(count: 2304), name: "cgb.bin"), .gbcBoot)
        XCTAssertNil(BIOSStore.detect(Data(count: 1000), name: "x.bin"))
    }
    func testCoordinatedReadOfLocalFile() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("b.rom")
        try Data([1, 2, 3]).write(to: u)
        XCTAssertEqual(BIOSStore.readCoordinated(u), Data([1, 2, 3]))
    }
}
