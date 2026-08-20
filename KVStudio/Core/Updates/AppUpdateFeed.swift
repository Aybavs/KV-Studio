import Foundation

// The appcast URL ships in Info.plist so a release can point at its own feed. Until the release
// pipeline sets SUFeedURL there is no feed, and the updater deliberately never starts.
enum AppUpdateFeed {
    static func configured(bundle: Bundle = .main) -> URL? {
        guard let text = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" else { return nil }
        return url
    }
}
