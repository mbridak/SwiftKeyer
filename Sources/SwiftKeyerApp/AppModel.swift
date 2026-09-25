import Foundation
import SwiftKeyerCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var availablePorts: [SerialPortInfo] = []
  @Published private(set) var connectionState: KeyerConnectionState = .disconnected
  @Published private(set) var rpcState: KeyerRPCState = .stopped
  @Published private(set) var sentText = ""
  @Published private(set) var speed = 20
  @Published private(set) var isTuning = false
  @Published private(set) var statusMessage = ""
  @Published var errorMessage: String?
  @Published var isSettingsPresented = false
  @Published var devicePath: String {
    didSet {
      guard hasStarted, oldValue != devicePath else {
        return
      }
      reconnectTask?.cancel()
      settingsWritable = true
      scheduleSave()
    }
  }
  @Published var liveText: String {
    didSet {
      applyLiveTextChange(from: oldValue)
    }
  }
  @Published var macros: [String]
  @Published var paddleSettings: PaddleSettings

  private let controller: WinKeyerController
  private let settingsStore: SettingsStore
  private var eventTask: Task<Void, Never>?
  private var connectionTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var liveTextTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var hasStarted = false
  private var activePath = ""
  private var suppressLiveTextChange = false
  private var liveTextRevision = 0
  private var settingsWritable = true

  init(
    controller: WinKeyerController = WinKeyerController(),
    settingsStore: SettingsStore = SettingsStore()
  ) {
    self.controller = controller
    self.settingsStore = settingsStore
    devicePath = ""
    liveText = ""
    macros = Array(repeating: "", count: 6)
    paddleSettings = .standard
  }

  deinit {
    eventTask?.cancel()
    connectionTask?.cancel()
    reconnectTask?.cancel()
    liveTextTask?.cancel()
    saveTask?.cancel()
  }

  func start() async {
    guard !hasStarted else {
      return
    }
    loadSettings()
    hasStarted = true
    refreshPorts()
    eventTask = Task { [weak self, controller] in
      for await event in controller.events {
        guard let self else {
          return
        }
        self.handle(event)
      }
    }

    await controller.setPaddleSettings(paddleSettings)
    await controller.startRPCServer()
    if !devicePath.isEmpty {
      connect()
    } else if availablePorts.count == 1 {
      devicePath = availablePorts[0].path
      connect()
    }
  }

  func refreshPorts() {
    availablePorts = SerialPortDiscovery.availablePorts()
    if devicePath.isEmpty, availablePorts.count == 1 {
      devicePath = availablePorts[0].path
    }
  }

  func connect() {
    let path = devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      return
    }

    reconnectTask?.cancel()
    let previousConnection = connectionTask
    previousConnection?.cancel()
    activePath = path
    connectionTask = Task { [controller] in
      await previousConnection?.value
      guard !Task.isCancelled else {
        return
      }
      await controller.connect(to: path)
    }
  }

  func disconnect() {
    reconnectTask?.cancel()
    let previousConnection = connectionTask
    previousConnection?.cancel()
    activePath = ""
    connectionTask = Task { [controller] in
      await previousConnection?.value
      guard !Task.isCancelled else {
        return
      }
      await controller.disconnect()
    }
  }

  func sendMacro(at index: Int) {
    guard macros.indices.contains(index) else {
      return
    }
    let message = macros[index]
    Task { [controller] in
      await controller.sendMacro(message)
    }
  }

  func setTuning(_ tuning: Bool) {
    Task { [controller] in
      await controller.tune(on: tuning)
    }
  }

  func clearBuffer() {
    suppressLiveTextChange = true
    liveText = ""
    suppressLiveTextChange = false
    Task { [controller] in
      await controller.clearBuffer()
    }
  }

  func updatePaddleSettings(_ settings: PaddleSettings) {
    paddleSettings = settings
    settingsWritable = true
    scheduleSave()
    Task { [controller] in
      await controller.setPaddleSettings(settings)
    }
  }

  func speedBinding() -> Binding<Double> {
    Binding(
      get: { Double(self.speed) },
      set: { value in
        let speed = Int(value.rounded())
        guard self.speed != speed else {
          return
        }
        self.speed = speed
        Task { [controller = self.controller] in
          await controller.setSpeed(speed)
        }
      }
    )
  }

  func macroBinding(at index: Int) -> Binding<String> {
    Binding(
      get: { self.macros.indices.contains(index) ? self.macros[index] : "" },
      set: { value in
        guard self.macros.indices.contains(index) else {
          return
        }
        self.macros[index] = value
        self.settingsWritable = true
        self.scheduleSave()
      }
    )
  }

  func shutdown() async {
    reconnectTask?.cancel()
    liveTextTask?.cancel()
    saveTask?.cancel()
    let pendingConnection = connectionTask
    pendingConnection?.cancel()
    await pendingConnection?.value
    saveNow()
    eventTask?.cancel()
    await controller.shutdown()
  }

  private func handle(_ event: KeyerEvent) {
    switch event {
    case .connection(let state):
      connectionState = state
      switch state {
      case .connecting:
        sentText = ""
        statusMessage = ""
        isTuning = false
      case .failed(let message):
        statusMessage = message
        scheduleReconnect()
      case .connected, .disconnected:
        break
      }
    case .rpc(let state):
      rpcState = state
    case .output(let character):
      sentText.append(character)
      if sentText.count > 100_000 {
        sentText.removeFirst(sentText.count - 100_000)
      }
    case .speed(let speed):
      self.speed = min(max(speed, 5), 35)
    case .error(let message):
      statusMessage = message
    case .tuning(let active):
      isTuning = active
    }
  }

  private func applyLiveTextChange(from oldText: String) {
    guard hasStarted, !suppressLiveTextChange, oldText != liveText else {
      return
    }
    liveTextTask?.cancel()
    liveTextRevision += 1
    let revision = liveTextRevision
    let newText = liveText
    liveTextTask = Task { [controller] in
      await controller.applyLiveTextChange(to: newText, revision: revision)
    }
  }

  private func scheduleReconnect() {
    let path = activePath
    guard !path.isEmpty, path == devicePath else {
      return
    }
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self, controller] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, let self else {
        return
      }
      guard self.devicePath == path else {
        return
      }
      await controller.connect(to: path)
    }
  }

  private func loadSettings() {
    do {
      let settings = try settingsStore.load()
      devicePath = settings.device
      macros = settings.macros
      paddleSettings = settings.paddleSettings
    } catch {
      settingsWritable = false
      errorMessage = "Unable to load saved settings: \(error.localizedDescription)"
    }
  }

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else {
        return
      }
      self?.saveNow()
    }
  }

  private func saveNow() {
    guard hasStarted, settingsWritable else {
      return
    }
    do {
      try settingsStore.save(
        KeyerSettings(
          device: devicePath,
          macros: macros,
          paddleSettings: paddleSettings
        )
      )
    } catch {
      errorMessage = "Unable to save settings: \(error.localizedDescription)"
    }
  }
}
