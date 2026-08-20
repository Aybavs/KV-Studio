import Foundation
import Testing
@testable import KV_Studio

@Suite
struct AppUpdateFeedTests {

    private final class StubBundle: Bundle, @unchecked Sendable {
        var value: Any?
        override func object(forInfoDictionaryKey key: String) -> Any? {
            key == "SUFeedURL" ? value : nil
        }
    }

    private func bundle(_ value: Any?) -> StubBundle {
        let bundle = StubBundle()
        bundle.value = value
        return bundle
    }

    @Test func hasNoFeedWhenTheKeyIsAbsent() {
        #expect(AppUpdateFeed.configured(bundle: bundle(nil)) == nil)
    }

    @Test func readsAnHTTPSFeed() {
        let url = AppUpdateFeed.configured(bundle: bundle("https://example.com/appcast.xml"))
        #expect(url?.absoluteString == "https://example.com/appcast.xml")
    }

    // An appcast is only as trustworthy as its transport, so plain HTTP is refused outright.
    @Test func refusesAFeedThatIsNotHTTPS() {
        #expect(AppUpdateFeed.configured(bundle: bundle("http://example.com/appcast.xml")) == nil)
    }

    @Test func ignoresSurroundingWhitespace() {
        let url = AppUpdateFeed.configured(bundle: bundle("  https://example.com/appcast.xml  "))
        #expect(url?.absoluteString == "https://example.com/appcast.xml")
    }
}
