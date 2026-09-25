import SwiftKeyerCore
import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: PaddleSettings
  let onSave: (PaddleSettings) -> Void

  init(
    settings: PaddleSettings,
    onSave: @escaping (PaddleSettings) -> Void
  ) {
    _draft = State(initialValue: settings)
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Paddle Behavior") {
          Toggle("Disable paddle watchdog", isOn: $draft.disablePaddleWatchdog)
          Toggle("Paddle echo back", isOn: $draft.paddleEchoBack)
          Toggle("Paddle swap", isOn: $draft.paddleSwap)
        }

        Section("Keying") {
          Picker("Key mode", selection: $draft.keyMode) {
            ForEach(KeyerKeyMode.allCases) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          Toggle("Serial echo back", isOn: $draft.serialEchoBack)
          Toggle("Auto space", isOn: $draft.autoSpace)
          Toggle("CT spacing", isOn: $draft.ctSpacing)
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        Button("Save") {
          onSave(draft)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(14)
    }
    .frame(width: 430, height: 440)
  }
}
