import AppKit
import Combine
import SwiftUI

@MainActor
final class WelcomeSetup: ObservableObject {
  static let shared = WelcomeSetup()
  static let completedKey = "welcomeSetup.completed.v1"
  static let progressKey = "welcomeSetup.step.v1"
  enum Step: Int, CaseIterable { case welcome, models, connections, walkthrough }
  @Published private(set) var isPresented = false
  @Published var step: Step = .welcome {
    didSet { if isPresented { defaults.set(step.rawValue, forKey: Self.progressKey) } }
  }
  @Published private(set) var tour: WelcomeTourStep?
  private let defaults: UserDefaults
  private var started = false

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func start(hasInstalledModels: Bool) {
    guard !started else { return }
    started = true
    guard !defaults.bool(forKey: Self.completedKey) else { return }
    // Existing users can opt in through Replay; interrupted new setup resumes.
    if defaults.object(forKey: Self.progressKey) == nil,
       hasInstalledModels || defaults.bool(forKey: "localModelOnboardingDismissed") {
      defaults.set(true, forKey: Self.completedKey)
      return
    }
    isPresented = true
    step = Step(rawValue: defaults.integer(forKey: Self.progressKey)) ?? .welcome
  }

  func replay() {
    isPresented = true
    tour = nil
    step = .welcome
  }

  func finish(takeTour: Bool) {
    defaults.set(true, forKey: Self.completedKey)
    defaults.removeObject(forKey: Self.progressKey)
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    tour = takeTour ? .history : nil
    isPresented = false
  }

  func nextTourStep() {
    guard let tour else { return }
    self.tour = WelcomeTourStep(rawValue: tour.rawValue + 1)
  }

  func endTour() { tour = nil }

  static func choices(_ recommendations: LocalModelRecommendations, preserving selectedID: String? = nil) -> [LocalModelAssessment] {
    let first = recommendations.recommended.map { [$0] } ?? []
    let alternatives = recommendations.tierGroups.flatMap { $0.models }
      .filter { $0.fit.canRun && $0.id != first.first?.id }
      .sorted(by: LocalModelSelector.hardwareOrder)
    var choices = Array((first + alternatives).prefix(3))
    // A benchmark can reorder recommendations; do not require a second download.
    if let selectedID, !choices.contains(where: { $0.id == selectedID }),
       let chosen = recommendations.assessments.first(where: { $0.id == selectedID && $0.fit.canRun }) {
      if choices.count == 3 { choices.removeLast() }
      choices.append(chosen)
    }
    return choices
  }

  static func canContinue(selected: LocalModelAssessment?, installed: [LocalModel], activeID: String?,
                          skipLocal: Bool, busy: Bool) -> Bool {
    guard !busy else { return false }
    if skipLocal { return true }
    guard let selected, selected.fit.canRun, activeID == selected.id,
          let model = installed.first(where: { $0.id == selected.id }) else { return false }
    return !selected.model.requiresUpdate(model)
  }
}

/// Coordinates and characters are extracted unchanged from the supplied Vue asset.
struct EnigmaHelloLetter: Decodable {
  struct Column: Decodable {
    struct Row: Decodable { let y: Double; let char: String; let opacity: Double }
    let x: Double; let delay: Double; let rows: [Row]
  }
  let delay: Double; let cols: [Column]
  static let all: [Self] = {
    guard let asset = NSDataAsset(name: "EnigmaHello") else { return [] }
    return (try? JSONDecoder().decode([Self].self, from: asset.data)) ?? []
  }()
}

struct EnigmaHelloView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var began = Date.now
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
      Canvas { context, size in
        let scale = min(size.width / 1280, size.height / 540)
        context.translateBy(x: (size.width - 1280 * scale) / 2, y: (size.height - 540 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        let elapsed = timeline.date.timeIntervalSince(began)
        for letter in EnigmaHelloLetter.all {
          let lift = reduceMotion ? 0 : -10 * pulse(elapsed - letter.delay, end: 0.66)
          for column in letter.cols {
            let green = reduceMotion ? 0 : pulse(elapsed - column.delay, end: 0.64)
            let color = Color(red: (240 - 140 * green) / 255, green: (245 - 13 * green) / 255,
                              blue: (242 - 80 * green) / 255)
            // Resolve each symbol once per column, instead of once per character.
            let symbols = Dictionary(uniqueKeysWithValues: Set(column.rows.map(\.char)).map {
              ($0, context.resolve(Text($0).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(color)))
            })
            for row in column.rows {
              context.opacity = row.opacity
              if let symbol = symbols[row.char] {
                context.draw(symbol, at: CGPoint(x: column.x, y: row.y + lift))
              }
            }
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Hello")
  }

  private func pulse(_ time: Double, end: Double) -> Double {
    let phase = time.truncatingRemainder(dividingBy: 8.4) / 8.4
    guard phase > 0.12, phase < end else { return 0 }
    let t = phase <= 0.36 ? (phase - 0.12) / 0.24 : (end - phase) / (end - 0.36)
    return (1 - cos(t * .pi)) / 2
  }
}

struct WelcomeSetupView: View {
  @ObservedObject var setup: WelcomeSetup
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  @ObservedObject var cloud: CloudSettingsModel
  @ObservedObject var search: WebSearchSettings
  let chooseMode: (ChatMode) -> Void
  @State private var selectedID: String?
  @State private var skipLocal = false
  @State private var showConnections = false

  private var choices: [LocalModelAssessment] {
    WelcomeSetup.choices(advisor.recommendations(installedModels: chat.installedModels), preserving: selectedID)
  }
  private var selected: LocalModelAssessment? {
    if let selectedID { return choices.first { $0.id == selectedID } }
    return choices.first
  }
  private var canContinue: Bool {
    WelcomeSetup.canContinue(selected: selected, installed: chat.installedModels,
      activeID: chat.installedModel?.id, skipLocal: skipLocal, busy: chat.isBusy || advisor.isDetecting)
  }

  var body: some View {
    GeometryReader { geometry in
      setupContent(helloHeight: min(260, max(100, geometry.size.height * 0.3)))
    }
    .naturePresentation()
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .strokeBorder(NatureGlass.edge, lineWidth: 0.75)
        .allowsHitTesting(false)
    }
  }

  private func setupContent(helloHeight: CGFloat) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text("ENIGMA").font(.caption.weight(.semibold)).tracking(3)
        Spacer()
        Text("\(setup.step.rawValue + 1) of 4").font(.caption).foregroundStyle(.secondary)
      }.padding(.bottom, 16)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch setup.step {
          case .welcome: welcome(helloHeight: helloHeight)
          case .models: models
          case .connections: connections
          case .walkthrough: walkthrough
          }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(2)
        .frame(maxWidth: .infinity)
      }
      .defaultScrollAnchor(.center, for: .alignment)
      .scrollIndicators(.visible)
      .id(setup.step)
      VStack(spacing: 12) {
        if setup.step == .models { modelControls }
        footer
      }
      .padding(16)
      .natureSurface(radius: 20)
      .padding(.top, 16)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $showConnections) {
      SettingsView(settings: cloud, initialDestination: .cloud)
        .overlay(alignment: .topTrailing) {
          Button("Back to Setup") { showConnections = false }.padding(20)
        }
        .frame(width: 820, height: 660)
    }
    .task { await advisor.detectHardware() }
    .onChange(of: setup.step) { _, step in
      if step == .connections { Task { await cloud.refreshChatGPTAccount() } }
    }
  }

  private func welcome(helloHeight: CGFloat) -> some View {
    VStack(spacing: 18) {
      EnigmaHelloView().frame(height: helloHeight)
      HStack(spacing: 8) {
        Image(systemName: "sparkle").accessibilityHidden(true)
        Text("(My name is Enigma)")
      }
      .font(.system(size: 15, weight: .medium, design: .rounded))
      .foregroundStyle(NatureGlass.accent)
      .padding(.horizontal, 16).padding(.vertical, 8)
      .background(NatureGlass.accent.opacity(0.08), in: Capsule())
      .overlay { Capsule().strokeBorder(NatureGlass.accent.opacity(0.22), lineWidth: 0.75) }
      VStack(spacing: 2) {
        Text("A little intelligence.").foregroundStyle(.primary)
        Text("Right where you need it.")
          .foregroundStyle(LinearGradient(colors: [.white, NatureGlass.accent], startPoint: .leading, endPoint: .trailing))
      }
      .font(.system(size: 28, weight: .semibold, design: .rounded))
      .multilineTextAlignment(.center)
      Text("Let’s make this Mac feel like home. Choose how I think, connect what you need, and take a quick look around.")
        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 450)
    }.frame(maxWidth: .infinity).padding(.vertical, 8)
  }

  private var models: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Made for your Mac").font(.system(size: 28, weight: .semibold))
      Text("Local models answer on this Mac. Choose a balance of speed, capability, and space.")
        .foregroundStyle(.secondary)
      if let mac = advisor.hardware {
        Label("\(mac.device) · \(mac.chip)", systemImage: "desktopcomputer").font(.subheadline.weight(.medium))
        Text("\(mac.physicalMemory, format: .byteCount(style: .memory)) memory · \(mac.availableDiskBytes, format: .byteCount(style: .file)) free storage")
          .font(.caption).foregroundStyle(.secondary)
      } else { ProgressView("Detecting your Mac…") }
      ForEach(Array(choices.enumerated()), id: \.element.id) { index, assessment in
        LocalModelChoiceCard(assessment: assessment,
          role: index == 0 ? (assessment.isResponsive ? "Recommended for your Mac" : "Best available · expect longer waits") : "Alternative \(index)",
          isSelected: !skipLocal && selected?.id == assessment.id) {
            selectedID = assessment.id
            skipLocal = false
          }
          .overlay { if index == 0 { RoundedRectangle(cornerRadius: 16).strokeBorder(NatureGlass.accent, lineWidth: 2).allowsHitTesting(false) } }
          .disabled(chat.isBusy || advisor.isDetecting)
      }
      if advisor.hardware != nil && choices.count < 3 {
        Text(choices.isEmpty ? "No supported model fits the available memory and storage. You can continue with Cloud."
          : "Only \(choices.count) compatible choices fit this Mac right now.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("Downloads include image support and are verified before installation. Speed estimates vary with other apps and power settings.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Add or change models later in Settings. Cloud and web search send relevant requests online.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var modelControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Don’t use local models", isOn: $skipLocal).disabled(chat.isBusy)
      if !skipLocal, let selected {
        let installed = chat.installedModels.first { $0.id == selected.id }
        let current = installed.map { !selected.model.requiresUpdate($0) } ?? false
        HStack {
          Button(current ? (chat.installedModel?.id == selected.id ? "Installed & selected" : "Use this model") : "Install selected model") {
            selectedID = selected.id
            if current { chat.selectModel(id: selected.id) } else { chat.downloadModel(selected.model) }
          }
          .buttonStyle(.borderedProminent)
          .disabled(chat.isBusy || advisor.isDetecting || (current && chat.installedModel?.id == selected.id))
          Text(current ? (chat.installedModel?.id == selected.id ? "Ready when you are" : "Select to continue") : ByteCountFormatter.string(fromByteCount: selected.model.downloadByteCount, countStyle: .file))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      LocalModelOperationView(chat: chat, advisor: advisor)
    }
  }

  private var connections: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("A little more connected").font(.system(size: 28, weight: .semibold))
      Text("Both are optional. Open the links to get started, then finish connecting in Settings.").foregroundStyle(.secondary)
      connectionCard(title: "ChatGPT & Codex", symbol: "cloud", status: cloud.chatGPTAccount != nil ? "Signed in with ChatGPT" : "Not connected") {
        Text("Use your ChatGPT plan’s Codex allowance for cloud answers. Install Codex, then sign in with ChatGPT in Enigma’s settings.")
        HStack {
          Link("ChatGPT", destination: URL(string: "https://chatgpt.com/")!)
          Link("Set up Codex", destination: URL(string: "https://learn.chatgpt.com/docs/codex/cli")!)
        }.buttonStyle(.bordered)
      }
      connectionCard(title: "Web search", symbol: "globe", status: search.hasAPIKey ? "Brave key saved · not tested here" : "Not connected") {
        Text("Get a Brave Search API key with LLM Context access and save it in Settings → Cloud & Search. Brave usage is billed separately.")
        Link("Get Brave Search", destination: URL(string: "https://brave.com/search/api/")!).buttonStyle(.bordered)
      }
      Button("Open Connection Settings") { showConnections = true }.buttonStyle(.borderedProminent)
      Text("Opening a link doesn’t connect your account. You can continue now and finish this later.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func connectionCard<Content: View>(title: String, symbol: String, status: String,
                                            @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: symbol).font(.headline)
      content().font(.subheadline)
      Text(status).font(.caption).foregroundStyle(NatureGlass.accent)
    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).natureSurface(radius: 16)
  }

  private var walkthrough: some View {
    VStack(alignment: .leading, spacing: 20) {
      Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(NatureGlass.accent)
      Text("Make yourself at home").font(.system(size: 28, weight: .semibold))
      Text("Would you like an interactive walkthrough?").font(.title3)
      Text("Six quick stops show you chat history, the message box, slash commands, files, model choices, and Help. Follow the highlighted controls with Next, or leave the tour anytime.")
        .foregroundStyle(.secondary)
      if chat.installedModel == nil && !cloud.isConfigured {
        Label("No model is ready yet. Connect Cloud or install a model in Settings before sending your first message.", systemImage: "info.circle")
          .font(.subheadline).foregroundStyle(.secondary)
      }
      Text("Screen, selection, and location permissions are requested when you use those features. You’re in control.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Replay this setup anytime from Settings → General.").font(.caption).foregroundStyle(.secondary)
    }.padding(.vertical, 30)
  }

  private var footer: some View {
    HStack {
      if setup.step != .welcome {
        Button("Back") { setup.step = WelcomeSetup.Step(rawValue: setup.step.rawValue - 1) ?? .welcome }
          .disabled(chat.isBusy)
      }
      Spacer()
      if setup.step == .walkthrough {
        Button("Skip tour & finish") { setup.finish(takeTour: false) }
        Button("Yes, show me around") { setup.finish(takeTour: true) }.buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      } else {
        Button("Next") {
          if setup.step == .models { chooseMode(skipLocal ? .cloud : .local) }
          setup.step = WelcomeSetup.Step(rawValue: setup.step.rawValue + 1) ?? .walkthrough
        }
        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        .disabled(setup.step == .models && !canContinue)
      }
    }
  }
}

enum WelcomeTourStep: Int, CaseIterable {
  case history, composer, commands, files, model, help
  var target: Self { self == .commands ? .composer : self }
  var title: String {
    switch self {
    case .history: "Your conversations"
    case .composer: "Start a conversation"
    case .commands: "Shortcuts start with /"
    case .files: "Bring your files"
    case .model: "Choose how I think"
    case .help: "Help is always here"
    }
  }
  var detail: String {
    switch self {
    case .history: "Use the sidebar button to show or hide your five most recent chats. Double-tap Control to toggle history, and use the pencil for a new chat."
    case .composer: "Type here and press Return to send. Use Shift–Return for a new line. Your draft stays here while you explore the tour."
    case .commands: "Type / in the message box to browse commands. Use ↑ and ↓, then Tab or Return to choose one before adding your question."
    case .files: "Open the file picker to work with a file or folder. Enigma asks for access to what you choose."
    case .model: "Choose Local, Cloud, or Auto and select a model. Local answers on your Mac; Cloud uses your connected provider; Auto selects a route."
    case .help: "Find keyboard shortcuts here. Settings is nearby for models, connections, and replaying welcome setup. Use Option–Space to hide or summon Enigma."
    }
  }
}

struct WelcomeTourAnchors: PreferenceKey {
  static let defaultValue: [WelcomeTourStep: Anchor<CGRect>] = [:]
  static func reduce(value: inout [WelcomeTourStep: Anchor<CGRect>], nextValue: () -> [WelcomeTourStep: Anchor<CGRect>]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

extension View {
  func welcomeTourTarget(_ step: WelcomeTourStep) -> some View {
    anchorPreference(key: WelcomeTourAnchors.self, value: .bounds) { [step: $0] }
  }
}

struct WelcomeTourOverlay: View {
  @ObservedObject var setup: WelcomeSetup
  let anchors: [WelcomeTourStep: Anchor<CGRect>]
  @State private var cardHeight: CGFloat = 230
  @AccessibilityFocusState private var isHeadingFocused: Bool
  var body: some View {
    GeometryReader { geometry in
      if let step = setup.tour {
        let bounds = CGRect(origin: .zero, size: geometry.size)
        let target = anchors[step.target].map { geometry[$0].insetBy(dx: -5, dy: -5).intersection(bounds) }
        let rect = target.flatMap { $0.isNull ? nil : $0 }
          ?? CGRect(x: geometry.size.width / 2, y: 24, width: 0, height: 0)
        let cardWidth = min(340.0, geometry.size.width - 32)
        ZStack(alignment: .topLeading) {
          Path { path in
            path.addRect(CGRect(origin: .zero, size: geometry.size))
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 12, height: 12))
          }.fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
          RoundedRectangle(cornerRadius: 12).strokeBorder(NatureGlass.accent, lineWidth: 2)
            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
          VStack(alignment: .leading, spacing: 12) {
            Text("\(step.rawValue + 1) of \(WelcomeTourStep.allCases.count)").font(.caption).foregroundStyle(NatureGlass.accent)
            Text(step.title).font(.headline).accessibilityFocused($isHeadingFocused)
            Text(step.detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if step == .commands { commandPreview }
            HStack {
              Button("End tour") { setup.endTour() }
              Spacer()
              Button(step == .help ? "Finish setup" : "Next") { setup.nextTourStep() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
          }
          .padding(18).frame(width: cardWidth).background(NatureGlass.canvas, in: RoundedRectangle(cornerRadius: 18))
          .natureSurface(radius: 18)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
          .offset(x: min(max(16, rect.midX - cardWidth / 2), geometry.size.width - cardWidth - 16),
                  y: rect.midY > geometry.size.height / 2 ? max(16, rect.minY - cardHeight - 16) : max(16, min(rect.maxY + 16, geometry.size.height - cardHeight - 16)))
        }
        .contentShape(Rectangle())
        .task(id: step) { isHeadingFocused = true }
        .onExitCommand { setup.endTour() }
      }
    }
  }

  private var commandPreview: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(SlashCommand.allCases) { command in
        HStack(spacing: 8) {
          Text(command.token).font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(NatureGlass.accent).frame(width: 76, alignment: .leading)
          Text(command.description).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
  }
}

extension Notification.Name {
  static let welcomeSetupRequested = Notification.Name("welcomeSetupRequested")
}
