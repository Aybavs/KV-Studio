import SwiftUI

extension View {
    // Honours Reduce Motion: the same state change still happens, it just stops sliding.
    func kvAnimation<V: Equatable>(_ animation: Animation?, value: V, reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}

enum MotionPreference {
    static func animation(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
