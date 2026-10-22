import XCTest
import Network
@testable import GooglyShared

final class PairingTransportTests: XCTestCase {
    func testAuthenticatedLoopbackDeliversEncryptedPacket() async throws {
        let authenticated = expectation(description: "Both peers authenticated")
        authenticated.expectedFulfillmentCount = 2
        let delivered = expectation(description: "Encrypted packet delivered")
        let secret = Data(repeating: 17, count: 32)
        let listener = try NWListener(using: .googly)
        var mac: LineConnection?
        var phone: LineConnection?
        listener.newConnectionHandler = { connection in
            let link = LineConnection(connection, secret: secret, server: true)
            mac = link
            link.onAuthenticated = { authenticated.fulfill() }
            link.onPacket = { packet in
                XCTAssertEqual(packet.command, "focusStart")
                XCTAssertEqual(packet.text, "A private focus task")
                delivered.fulfill()
            }
            link.start()
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port else { return }
            let link = LineConnection(NWConnection(host: "127.0.0.1", port: port, using: .googly), secret: secret, server: false)
            phone = link
            link.onAuthenticated = {
                authenticated.fulfill()
                link.send(Packet(command: "focusStart", text: "A private focus task"))
            }
            link.start()
        }
        listener.start(queue: .main)
        await fulfillment(of: [authenticated, delivered], timeout: 8)
        mac?.cancel(); phone?.cancel(); listener.cancel()
    }
}
