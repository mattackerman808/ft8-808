import XCTest
import FT8808Engine
@testable import HamlibRig

/// Exercises the full Hamlib path against the software "dummy" rig (model 1),
/// which simulates a transceiver entirely in software — so this verifies the
/// bundled dylib, the C shim, and the Swift actor with no hardware attached.
final class HamlibRigTests: XCTestCase {

    private func openDummy() async throws -> HamlibRigController {
        let rig = HamlibRigController(model: HamlibModel.dummy)
        try await rig.open()
        return rig
    }

    func testOpensDummyRig() async throws {
        let rig = try await openDummy()
        let state = await rig.state()
        XCTAssertTrue(state.connected)
        await rig.close()
    }

    func testSetAndReadFrequency() async throws {
        let rig = try await openDummy()
        try await rig.setFrequency(14_074_000)
        let state = await rig.state()
        XCTAssertEqual(state.frequencyHz, 14_074_000)
        await rig.close()
    }

    func testSetModeAndPTT() async throws {
        let rig = try await openDummy()
        try await rig.setMode(.data)
        try await rig.setPTT(true)
        var state = await rig.state()
        XCTAssertEqual(state.mode, .data)
        XCTAssertTrue(state.transmitting)

        try await rig.setPTT(false)
        state = await rig.state()
        XCTAssertFalse(state.transmitting)
        await rig.close()
    }

    func testOperationBeforeOpenThrows() async {
        let rig = HamlibRigController(model: HamlibModel.dummy)
        do {
            try await rig.setFrequency(14_074_000)
            XCTFail("expected notOpen error")
        } catch {
            // expected
        }
    }
}
