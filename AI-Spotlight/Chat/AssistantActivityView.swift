import SwiftUI

struct AssistantActivityView: View {
  let activity: AssistantActivity
  var expanded: Binding<Bool>? = nil
  @State private var locallyExpanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isExpanded: Binding<Bool> { expanded ?? $locallyExpanded }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
          isExpanded.wrappedValue.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          if !activity.phase.isTerminal && activity.phase != .generating {
            ThinkingStatusView(text: activity.status)
          } else {
            if !activity.phase.isTerminal { ProgressView().controlSize(.mini) }
            Text(activity.status).font(.system(size: 13, weight: .medium))
          }
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(activity.status)
      .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
      .accessibilityHint("Show or hide request activity and sources")
      .accessibilityIdentifier("assistant-activity-toggle")

      if isExpanded.wrappedValue {
        VStack(alignment: .leading, spacing: 12) {
          Text("Request activity").font(.system(size: 12, weight: .semibold))
          ForEach(activity.phases, id: \.self) { phase in
            HStack(spacing: 8) {
              Image(systemName: phase == activity.phase && !phase.isTerminal ? "circle.dotted" : "checkmark")
                .frame(width: 14)
              Text(phase == .readingSources ? "Collected \(activity.sourceSummary)" : phase.label)
            }
            .font(.caption).foregroundStyle(.secondary)
          }
          if !activity.sources.isEmpty {
            Divider()
            Text("Web sources").font(.system(size: 12, weight: .semibold))
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(activity.sources) { source in
                  ActivitySourceRow(source: source, detail: sourceDetail(source), colorIndex: activity.colorIndex(for: source))
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(activity.sources.count) * 76, 260))
          } else if activity.phase == .searching {
            Text("Waiting for search results…").font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08), lineWidth: 0.6) }
        .accessibilityIdentifier("assistant-activity-panel")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sourceDetail(_ source: WebSearchSource) -> String {
    guard let selected = activity.selectedSourceIDs else { return "Collected excerpt" }
    return selected.contains(source.id) ? "Included in context" : "Outside context budget"
  }
}

private struct ActivitySourceRow: View {
  let source: WebSearchSource
  let detail: String
  let colorIndex: Int
  private static let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green, .brown]

  var body: some View {
    Link(destination: source.url) {
      HStack(alignment: .top, spacing: 10) {
        Text(source.monogram)
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 28, height: 28)
          .background(Self.colors[colorIndex].gradient, in: Circle())
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(source.title.isEmpty ? source.siteName : source.title)
            .font(.system(size: 12, weight: .medium)).lineLimit(2)
          Text(source.siteName + " · " + detail)
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
          Text(source.url.absoluteString)
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
      }.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(source.url.absoluteString)
    .accessibilityLabel("\(source.title), \(source.siteName), \(detail)")
  }
}
