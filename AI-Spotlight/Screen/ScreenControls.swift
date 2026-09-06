import SwiftUI

struct ScreenToolButton: View {
  @ObservedObject var coordinator: ScreenComposerCoordinator
  let isBusy: Bool
  let capture: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .leading) {
      if coordinator.isPresented {
      Button {
        if coordinator.attachment == nil { capture() }
        else { coordinator.isEnabled.toggle() }
      } label: {
        Image("ScreenCapture")
          .renderingMode(.template)
          .resizable().scaledToFit()
          .foregroundStyle(coordinator.isEnabled ? Color.orange : Color.secondary)
          .frame(width: 22, height: 22)
          .padding(4)
          .background(coordinator.isEnabled ? Color.orange.opacity(0.12) : .clear,
                      in: RoundedRectangle(cornerRadius: 7))
          .scaleEffect(coordinator.isEnabled ? 1 : 0.9)
      }
      .buttonStyle(.plain)
      .disabled(isBusy || coordinator.isBusy)
      .accessibilityLabel("Screen")
      .accessibilityValue(coordinator.isEnabled ? "On" : "Off")
      .help(coordinator.isEnabled ? "Turn Screen off for this prompt" : "Turn Screen on. Hide inactive tools with ⌘⇧H.")
      .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: coordinator.isEnabled)
      .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
      }
    }
    .frame(width: coordinator.isPresented ? 30 : 0, height: 30, alignment: .leading)
    .clipped()
    .padding(.leading, coordinator.isPresented ? 10 : 0)
    .onReceive(NotificationCenter.default.publisher(for: .hideInactiveToolsRequested)) { _ in
      guard !isBusy, !coordinator.isBusy, !coordinator.isEnabled else { return }
      coordinator.isPresented = false
    }
  }
}

struct ScreenAttachmentView: View {
  let attachment: ScreenAttachment
  let isEnabled: Bool
  let isBusy: Bool
  let remove: () -> Void
  let retake: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: attachment.originalImage)
        .resizable().scaledToFit().frame(width: 76, height: 52)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Captured screen region")
      VStack(alignment: .leading, spacing: 3) {
        Text("Screen region").font(.caption.weight(.medium))
        Text(isEnabled ? attachment.status.rawValue : "Off · excluded from prompt")
          .font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Retake", action: retake).disabled(isBusy)
      Button(action: remove) { Image(systemName: "xmark.circle.fill") }
        .buttonStyle(.plain).accessibilityLabel("Remove screenshot").disabled(isBusy)
    }
    .padding(10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    .opacity(isEnabled ? 1 : 0.65)
  }
}
