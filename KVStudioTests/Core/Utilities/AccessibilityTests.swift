import AppKit
import Foundation
import SwiftUI
import Testing
@testable import KV_Studio

@Suite
struct PasteboardTests {

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("kv-test-\(UUID().uuidString)"))
    }

    @Test func copiesTextAsItself() {
        let board = scratchPasteboard()
        Pasteboard.copy(Data("hello".utf8), to: board)
        #expect(board.string(forType: .string) == "hello")
    }

    // Copying must not silently mangle bytes that are not text.
    @Test func copiesBinaryAsHexRatherThanLosingBytes() {
        let board = scratchPasteboard()
        Pasteboard.copy(Data([0x00, 0xFF, 0x10]), to: board)
        let copied = board.string(forType: .string)
        #expect(copied?.contains("ff") == true)
        #expect(copied?.contains("\u{FFFD}") == false)
    }

    @Test func replacesWhatWasThereBefore() {
        let board = scratchPasteboard()
        Pasteboard.copy("first", to: board)
        Pasteboard.copy("second", to: board)
        #expect(board.string(forType: .string) == "second")
    }

    @Test func roundTripsMultiByteText() {
        let board = scratchPasteboard()
        Pasteboard.copy(Data("merhaba dünya".utf8), to: board)
        #expect(board.string(forType: .string) == "merhaba dünya")
    }
}

@Suite
struct AccessibilityLabelTests {

    @Test func namesATextKey() {
        #expect(AccessibilityLabels.key(Data("user:1".utf8)) == "Key user:1")
    }

    // VoiceOver cannot read raw bytes, so a binary key is described rather than spoken.
    @Test func describesABinaryKeyByItsSize() {
        let label = AccessibilityLabels.key(Data([0x00, 0xFF]))
        #expect(label == "Binary key, 2 bytes")
    }

    @Test func namesATextValue() {
        #expect(AccessibilityLabels.value(Data("hello".utf8), format: .text) == "Value hello")
    }

    @Test func describesAHexValueAsBinary() {
        let label = AccessibilityLabels.value(Data([0x01]), format: .hex)
        #expect(label == "Binary value shown as hexadecimal, 1 byte")
    }

    @Test func readsTheThreeTTLStatesAsSentences() {
        #expect(AccessibilityLabels.ttl(.missing) == "No such key")
        #expect(AccessibilityLabels.ttl(.persistent) == "No expiry")
        #expect(AccessibilityLabels.ttl(.expiring(seconds: 30)) == "Expires in 30 seconds")
    }
}

@Suite
struct MotionPreferenceTests {

    @Test func keepsAnimationWhenMotionIsAllowed() {
        #expect(MotionPreference.animation(.default, reduceMotion: false) != nil)
    }

    @Test func dropsAnimationWhenReduceMotionIsOn() {
        #expect(MotionPreference.animation(.default, reduceMotion: true) == nil)
    }
}
