import SwiftUI

struct UnavailableStorageView: View {
    let error: UserFacingError

    var body: some View {
        VStack(spacing: 12) {
            Text(error.message)
                .font(.headline)
                .accessibilityIdentifier("storage.failure.title")
            if let recovery = error.recovery {
                Text(recovery)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let detail = error.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 260)
    }
}

extension Result {
    var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
