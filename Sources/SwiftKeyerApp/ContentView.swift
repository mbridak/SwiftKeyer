import SwiftKeyerCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      connectionBar
      Divider()

      ScrollView {
        VStack(spacing: 18) {
          speedControl
          sentTextPanel
          liveTextPanel
          macroPanel
          keyingControls
        }
        .padding(20)
      }

      Divider()
      statusBar
    }
    .frame(minWidth: 780, minHeight: 700)
    .sheet(isPresented: $model.isSettingsPresented) {
      SettingsView(
        settings: model.paddleSettings,
        onSave: model.updatePaddleSettings
      )
    }
    .alert(
      "WinKeyer Serial",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { isPresented in
          if !isPresented {
            model.errorMessage = nil
          }
        }
      )
    ) {
      Button("OK", role: .cancel) {
        model.errorMessage = nil
      }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .task {
      await model.start()
    }
  }

  private var connectionBar: some View {
    HStack(spacing: 10) {
      Label("Serial", systemImage: "cable.connector")
        .font(.headline)

      TextField("/dev/cu...", text: $model.devicePath)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 220)

      Menu {
        if model.availablePorts.isEmpty {
          Text("No serial ports found")
        } else {
          ForEach(model.availablePorts) { port in
            Button {
              model.devicePath = port.path
            } label: {
              VStack(alignment: .leading) {
                Text(port.path)
                Text(port.description)
                  .font(.caption)
              }
            }
          }
        }
      } label: {
        Label("Ports", systemImage: "list.bullet")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      Button {
        model.refreshPorts()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("Refresh serial ports")

      Button(model.connectionState == .connecting ? "Connecting" : "Connect") {
        model.connect()
      }
      .buttonStyle(.borderedProminent)
      .disabled(
        model.devicePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || model.connectionState == .connecting
      )

      connectionBadge
      Spacer()

      Button {
        model.isSettingsPresented = true
      } label: {
        Image(systemName: "gearshape")
      }
      .help("Keyer settings")
    }
    .padding(14)
  }

  private var speedControl: some View {
    HStack(spacing: 14) {
      Label("Speed", systemImage: "gauge.with.dots.needle.33percent")
        .font(.headline)
        .frame(width: 85, alignment: .leading)

      Slider(value: model.speedBinding(), in: 5...35, step: 1)
        .frame(maxWidth: 420)

      Text("\(model.speed) WPM")
        .font(.system(.body, design: .monospaced).weight(.semibold))
        .frame(width: 75, alignment: .trailing)
    }
    .padding(.horizontal, 4)
  }

  private var sentTextPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Sent Text", systemImage: "text.bubble")
        .font(.headline)

      ScrollView {
        Text(model.sentText.isEmpty ? "Waiting for keyer echo…" : model.sentText)
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(model.sentText.isEmpty ? Color.secondary : Color.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(height: 110)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
    }
  }

  private var liveTextPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Free Text Input", systemImage: "keyboard")
        .font(.headline)

      ZStack(alignment: .topLeading) {
        if model.liveText.isEmpty {
          Text("Type CW text to send immediately…")
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 9)
            .allowsHitTesting(false)
        }
        TextEditor(text: $model.liveText)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(4)
      }
      .frame(height: 130)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
    }
  }

  private var macroPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Macros", systemImage: "text.badge.plus")
        .font(.headline)

      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible())],
        spacing: 10
      ) {
        ForEach(0..<6, id: \.self) { index in
          HStack(spacing: 8) {
            TextField("Message \(index + 1)", text: model.macroBinding(at: index))
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
            Button("Send") {
              model.sendMacro(at: index)
            }
            .frame(width: 58)
          }
        }
      }
    }
  }

  private var keyingControls: some View {
    HStack {
      Button {
        model.setTuning(!model.isTuning)
      } label: {
        Label(
          model.isTuning ? "Stop Tune" : "Start Tune",
          systemImage: model.isTuning ? "stop.circle.fill" : "play.circle.fill"
        )
      }
      .buttonStyle(.bordered)
      .tint(model.isTuning ? .red : .accentColor)

      Button(role: .destructive) {
        model.clearBuffer()
      } label: {
        Label("Clear Buffer", systemImage: "trash")
      }
      .buttonStyle(.bordered)

      Spacer()
    }
  }

  private var connectionBadge: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(connectionColor)
        .frame(width: 8, height: 8)
      Text(connectionLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.quaternary, in: Capsule())
  }

  private var statusBar: some View {
    HStack(spacing: 14) {
      Label(rpcLabel, systemImage: "network")
        .foregroundStyle(rpcColor)
      if !model.statusMessage.isEmpty {
        Text(model.statusMessage)
          .lineLimit(1)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("XML-RPC port 8000")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private var connectionLabel: String {
    switch model.connectionState {
    case .disconnected:
      return "Disconnected"
    case .connecting:
      return "Connecting"
    case .connected:
      return "Connected"
    case .failed:
      return "Unavailable"
    }
  }

  private var connectionColor: Color {
    switch model.connectionState {
    case .connected:
      return .green
    case .connecting:
      return .orange
    case .disconnected:
      return .secondary
    case .failed:
      return .red
    }
  }

  private var rpcLabel: String {
    switch model.rpcState {
    case .stopped:
      return "RPC stopped"
    case .starting:
      return "RPC starting"
    case .listening:
      return "RPC listening"
    case .failed:
      return "RPC unavailable"
    }
  }

  private var rpcColor: Color {
    switch model.rpcState {
    case .listening:
      return .green
    case .starting:
      return .orange
    case .stopped:
      return .secondary
    case .failed:
      return .red
    }
  }
}
