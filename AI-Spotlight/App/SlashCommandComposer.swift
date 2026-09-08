import AppKit
import SwiftUI

struct SlashCommandComposer: View {
  @Binding var text: String
  @Binding var isFocused: Bool
  var isEnabled: Bool
  var submit: () -> Void
  @StateObject private var completion = CommandCompletionModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if isFocused && isEnabled && !completion.commands.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(completion.commands.enumerated()), id: \.element) { index, command in
            Button { completion.accept(command) } label: {
              HStack(spacing: 10) {
                Image(systemName: command.symbol).font(.system(size: 17))
                  .frame(width: 24).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                  Text(command.token).font(.system(size: 13, weight: .semibold)).foregroundStyle(.blue)
                  Text(command.description).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if index == completion.selected { Text("⇥").foregroundStyle(.secondary) }
              }
              .padding(8)
              .contentShape(Rectangle())
              .background(index == completion.selected ? Color.blue.opacity(0.12) : .clear,
                          in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(command.token + ", " + command.description)
            .accessibilityAddTraits(index == completion.selected ? .isSelected : [])
          }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slash commands")
      }
      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text("Ask anything").font(ChatTypography.body).foregroundStyle(.tertiary)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        CommandTextEditor(text: $text, isFocused: $isFocused, isEnabled: isEnabled,
                          completion: completion, submit: submit)
          .frame(height: completion.height)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

@MainActor
final class CommandCompletionModel: ObservableObject {
  @Published var commands: [SlashCommand] = []
  @Published var selected = 0
  @Published var height: CGFloat = 20
  weak var editor: SlashCommandTextView?
  private var active: SlashCommand.Completion?

  func refresh() {
    guard let editor, editor.isEditable, !editor.hasMarkedText() else { dismiss(); return }
    let next = SlashCommand.completion(in: editor.string, selection: editor.selectedRange())
    if next != active { selected = 0 }
    active = next
    let matches = next?.commands ?? []
    if commands != matches { commands = matches }
    updateHeight()
  }

  func updateHeight() {
    guard let editor, let container = editor.textContainer, let layout = editor.layoutManager else { return }
    layout.ensureLayout(for: container)
    let measured = min(100, max(20, ceil(layout.usedRect(for: container).height)))
    if height != measured { height = measured }
  }

  @discardableResult
  func dismiss() -> Bool {
    let wasVisible = !commands.isEmpty
    if !commands.isEmpty { commands = [] }
    active = nil
    return wasVisible
  }

  func accept(_ command: SlashCommand) {
    guard let editor, let active, editor.isEditable,
          SlashCommand.completion(in: editor.string, selection: editor.selectedRange()) == active else { return }
    let source = editor.string as NSString
    let end = NSMaxRange(active.range)
    let hasSpace = end < source.length && source.substring(with: NSRange(location: end, length: 1)).first?.isWhitespace == true
    let replacement = command.token + (hasSpace ? "" : " ")
    guard editor.shouldChangeText(in: active.range, replacementString: replacement) else { return }
    editor.textStorage?.replaceCharacters(in: active.range, with: replacement)
    editor.setSelectedRange(NSRange(location: active.range.location + (replacement as NSString).length, length: 0))
    editor.didChangeText()
    dismiss()
    editor.window?.makeFirstResponder(editor)
  }

  func handle(_ event: NSEvent) -> Bool {
    guard !commands.isEmpty, editor?.hasMarkedText() == false,
          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
    switch event.keyCode {
    case 53: return dismiss()
    case 125: selected = (selected + 1) % commands.count
    case 126: selected = (selected + commands.count - 1) % commands.count
    case 48, 36, 76: accept(commands[selected])
    default: return false
    }
    return true
  }
}

final class SlashCommandTextView: NSTextView {
  var completion: CommandCompletionModel?
  var submit: (() -> Void)?
  var focusChanged: ((Bool) -> Void)?

  override func keyDown(with event: NSEvent) {
    if completion?.handle(event) == true { return }
    if !hasMarkedText(), [36, 76].contains(event.keyCode),
       event.modifierFlags.intersection([.shift, .option, .control, .command]) == .shift {
      insertText("\n", replacementRange: selectedRange())
      return
    }
    if !hasMarkedText(), [36, 76].contains(event.keyCode),
       event.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty {
      submit?()
      return
    }
    super.keyDown(with: event)
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { focusChanged?(true) }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      focusChanged?(false)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.window?.firstResponder !== self else { return }
        self.completion?.dismiss()
      }
    }
    return accepted
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    // Wrapping can change when the panel resizes without an edit.
    DispatchQueue.main.async { [weak self] in self?.completion?.updateHeight() }
  }

  func highlightCommands() {
    guard !hasMarkedText(), let storage = textStorage else { return }
    let selection = selectedRanges
    storage.beginEditing()
    storage.addAttributes([.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 15)],
                          range: NSRange(location: 0, length: storage.length))
    for token in SlashCommand.tokens(in: string) {
      storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: token.range)
    }
    storage.endEditing()
    selectedRanges = selection
    typingAttributes = [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 15)]
  }
}

private struct CommandTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  var isEnabled: Bool
  var completion: CommandCompletionModel
  var submit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let editor = SlashCommandTextView(frame: .zero)
    editor.isRichText = false
    editor.allowsUndo = true
    editor.drawsBackground = false
    editor.textContainerInset = .zero
    editor.textContainer?.lineFragmentPadding = 0
    editor.isHorizontallyResizable = false
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.font = .systemFont(ofSize: 15)
    editor.setAccessibilityLabel("Ask anything")
    editor.setAccessibilityHelp("Type slash for commands. Use arrow keys to choose, Tab or Return to complete, Escape to dismiss, and Shift Return for a new line.")
    editor.delegate = context.coordinator
    editor.completion = completion
    completion.editor = editor
    scroll.documentView = editor
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = scroll.documentView as? SlashCommandTextView else { return }
    editor.isEditable = isEnabled
    editor.submit = submit
    editor.focusChanged = { focused in
      DispatchQueue.main.async { context.coordinator.parent.isFocused = focused }
    }
    if editor.string != text, !editor.hasMarkedText() {
      editor.delegate = nil
      editor.string = text
      editor.highlightCommands()
      editor.delegate = context.coordinator
      DispatchQueue.main.async { completion.refresh() }
    }
    if !isEnabled { DispatchQueue.main.async { completion.dismiss() } }
    if isFocused && isEnabled && editor.window?.firstResponder !== editor {
      DispatchQueue.main.async { [weak editor] in
        guard let editor, context.coordinator.parent.isFocused, editor.isEditable else { return }
        editor.window?.makeFirstResponder(editor)
      }
    } else if !isFocused && editor.window?.firstResponder === editor {
      editor.window?.makeFirstResponder(nil)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: CommandTextEditor
    init(_ parent: CommandTextEditor) { self.parent = parent }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
      parent.submit()
      return true
    }
    func textDidChange(_ notification: Notification) {
      guard let editor = notification.object as? SlashCommandTextView else { return }
      parent.text = editor.string
      editor.highlightCommands()
      parent.completion.refresh()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      parent.completion.refresh()
    }
  }
}
