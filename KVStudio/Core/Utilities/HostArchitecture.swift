import Darwin

enum HostArchitecture: String, Equatable, Sendable {
    case arm64
    case amd64

    var assetSuffix: String { "darwin_\(rawValue)" }

    // The brief selects on the machine, not on the running process, so a translated Studio still
    // installs the native backend.
    static var current: HostArchitecture {
        var isAppleSilicon: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &isAppleSilicon, &size, nil, 0) == 0 else { return .amd64 }
        return isAppleSilicon == 1 ? .arm64 : .amd64
    }
}
