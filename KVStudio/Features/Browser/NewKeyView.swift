import SwiftUI

enum NewKeyInputMode: String, CaseIterable, Sendable {
    case text = "Text"
    case hex = "Hex"
}

struct NewKeyView: View {
    @Bindable var viewModel: BrowserViewModel
    let client: KVClient

    @Environment(\.dismiss) private var dismiss

    @State private var keyMode: NewKeyInputMode = .text
    @State private var keyText: String = ""
    @State private var valueMode: NewKeyInputMode = .text
    @State private var valueText: String = ""
    @State private var expiryUnit: ExpiryUnit = .none
    @State private var expiryText: String = ""
    @State private var errorMessage: String?
    @State private var isCreating: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section(header: Text("Key")) {
                    Picker("Key Mode", selection: $keyMode) {
                        ForEach(NewKeyInputMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("newKey.keyModePicker")

                    if keyMode == .text {
                        TextField("Key", text: $keyText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("newKey.keyField")
                    } else {
                        TextField("Hex key (e.g. 00 ff 01)", text: $keyText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(3...6)
                            .accessibilityIdentifier("newKey.keyField")
                    }
                    if let msg = keyValidationMessage, !keyText.isEmpty || keyMode == .hex {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("newKey.keyError")
                    }
                }

                Section(header: Text("Value")) {
                    Picker("Value Mode", selection: $valueMode) {
                        ForEach(NewKeyInputMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("newKey.valueModePicker")

                    if valueMode == .text {
                        TextEditor(text: $valueText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80, maxHeight: 160)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                            .accessibilityIdentifier("newKey.valueField")
                    } else {
                        TextField("Hex value (e.g. 48 65 6c 6c 6f)", text: $valueText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(3...6)
                            .accessibilityIdentifier("newKey.valueField")
                    }
                    if let msg = valueValidationMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("newKey.valueError")
                    }
                }

                Section(header: Text("Expiry")) {
                    Picker("Expiry", selection: $expiryUnit) {
                        Text("None").tag(ExpiryUnit.none)
                        Text("Seconds").tag(ExpiryUnit.seconds)
                        Text("Minutes").tag(ExpiryUnit.minutes)
                        Text("Hours").tag(ExpiryUnit.hours)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("newKey.expiryPicker")

                    if expiryUnit != .none {
                        HStack {
                            TextField("Amount", text: $expiryText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 120)
                                .accessibilityIdentifier("newKey.expiryValueField")
                            Text(unitLabel)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        if let msg = expiryValidationMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("newKey.expiryError")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let err = errorMessage {
                Text(err)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .accessibilityIdentifier("newKey.error")
            }

            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 520)
        .accessibilityIdentifier("newKey.view")
    }

    private var header: some View {
        HStack {
            Text("New Key")
                .font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button {
                Task { await create() }
            } label: {
                if isCreating { ProgressView().controlSize(.small) } else { Text("Create") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isFormValid || isCreating)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("newKey.createButton")
        }
        .padding()
    }

    private var unitLabel: String {
        switch expiryUnit {
        case .seconds: return expiryText == "1" ? "second" : "seconds"
        case .minutes: return expiryText == "1" ? "minute" : "minutes"
        case .hours: return expiryText == "1" ? "hour" : "hours"
        case .none: return ""
        }
    }

    private var keyValidationMessage: String? {
        switch keyMode {
        case .text:
            if keyText.isEmpty { return "Key must not be empty" }
            return nil
        case .hex:
            do {
                let data = try ValuePresentation.data(fromHex: keyText)
                if data.isEmpty { return "Key must not be empty" }
                return nil
            } catch let err as ValuePresentation.HexParseError {
                switch err {
                case .oddLength: return "Invalid hex: odd number of hex digits"
                case .invalidCharacter: return "Invalid hex: contains non-hex character"
                }
            } catch {
                return "Invalid hex"
            }
        }
    }

    private var valueValidationMessage: String? {
        switch valueMode {
        case .text: return nil
        case .hex:
            do {
                _ = try ValuePresentation.data(fromHex: valueText)
                return nil
            } catch let err as ValuePresentation.HexParseError {
                switch err {
                case .oddLength: return "Invalid hex: odd number of hex digits"
                case .invalidCharacter: return "Invalid hex: contains non-hex character"
                }
            } catch {
                return "Invalid hex"
            }
        }
    }

    private var expiryValidationMessage: String? {
        guard expiryUnit != .none else { return nil }
        let trimmed = expiryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Expiry amount required" }
        guard let v = Int64(trimmed), v > 0 else { return "Expiry must be a positive integer" }
        return nil
    }

    private var isFormValid: Bool {
        keyValidationMessage == nil && valueValidationMessage == nil && expiryValidationMessage == nil
    }

    private func parsedKey() throws -> Data {
        switch keyMode {
        case .text: return Data(keyText.utf8)
        case .hex: return try ValuePresentation.data(fromHex: keyText)
        }
    }

    private func parsedValue() throws -> Data {
        switch valueMode {
        case .text: return Data(valueText.utf8)
        case .hex: return try ValuePresentation.data(fromHex: valueText)
        }
    }

    private func parsedExpiration() -> SetExpiration? {
        guard expiryUnit != .none else { return nil }
        guard let expiry = NewKeyExpiry.from(amountText: expiryText, unit: expiryUnit) else { return nil }
        return expiry.asSetExpiration
    }

    private func create() async {
        guard isFormValid else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let keyData = try parsedKey()
            let valueData = try parsedValue()
            guard !keyData.isEmpty else {
                errorMessage = "Key must not be empty"
                return
            }
            let expiration = parsedExpiration()
            // If expiry unit selected but parsing failed, surface error
            if expiryUnit != .none && expiration == nil {
                errorMessage = expiryValidationMessage ?? "Invalid expiry"
                return
            }
            try await viewModel.createKey(key: keyData, value: valueData, expiration: expiration, using: client)
            dismiss()
        } catch let err as ValuePresentation.HexParseError {
            switch err {
            case .oddLength: errorMessage = "Invalid hex: odd length"
            case .invalidCharacter: errorMessage = "Invalid hex: contains non-hex character"
            }
        } catch let err as BrowserNewKeyError {
            switch err {
            case .emptyKey: errorMessage = "Key must not be empty"
            }
        } catch {
            if let kv = error as? KVClientError, case .serverError(let data) = kv {
                errorMessage = String(decoding: data, as: UTF8.self)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
