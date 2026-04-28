import XCTest
@testable import Omi_Computer

final class LocalModeGuardrailTests: XCTestCase {
    override func tearDown() {
        unsetenv("OMI_LOCAL_MODE")
        UserDefaults.standard.removeObject(forKey: "chatBridgeMode")
        super.tearDown()
    }

    func testAIChatNavigationIsLocalOnly() {
        unsetenv("OMI_LOCAL_MODE")
        XCTAssertFalse(SidebarNavItem.mainItems.contains(.chat))

        setenv("OMI_LOCAL_MODE", "1", 1)
        XCTAssertTrue(SidebarNavItem.mainItems.contains(.chat))
    }

    func testLocalModeDoesNotUseOmiAccountProviderForQuota() async {
        setenv("OMI_LOCAL_MODE", "1", 1)
        UserDefaults.standard.set(ChatProvider.BridgeMode.piMono.rawValue, forKey: "chatBridgeMode")

        await MainActor.run {
            let provider = ChatProvider()
            XCTAssertFalse(provider.isUsingOmiAccountProvider)
        }
    }

    func testCloudPiMonoUsesOmiAccountProviderForQuota() async {
        unsetenv("OMI_LOCAL_MODE")
        UserDefaults.standard.set(ChatProvider.BridgeMode.piMono.rawValue, forKey: "chatBridgeMode")

        await MainActor.run {
            let provider = ChatProvider()
            XCTAssertTrue(provider.isUsingOmiAccountProvider)
        }
    }

    func testUserClaudeDoesNotUseOmiAccountProviderForQuota() async {
        unsetenv("OMI_LOCAL_MODE")
        UserDefaults.standard.set(ChatProvider.BridgeMode.userClaude.rawValue, forKey: "chatBridgeMode")

        await MainActor.run {
            let provider = ChatProvider()
            XCTAssertFalse(provider.isUsingOmiAccountProvider)
        }
    }
}
