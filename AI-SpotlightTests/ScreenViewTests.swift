import AppKit
import SwiftUI
import XCTest
@testable import PrimaryAgent

@MainActor
final class ScreenViewTests: XCTestCase {
  func testScreenIconSlotAndNativeComposerStates() async throws {
    let icon = try XCTUnwrap(NSImage(named: "ScreenCapture"))
    let pixels = try XCTUnwrap(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let bitmapIcon = NSBitmapImageRep(cgImage: pixels)
    let visiblePixels = (0..<bitmapIcon.pixelsWide).reduce(0) { count, x in
      count + (0..<bitmapIcon.pixelsHigh).filter { y in (bitmapIcon.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }.count
    }
    XCTAssertGreaterThan(visiblePixels, 100, "A loaded but blank SVG must fail rendering verification")
    let hidden = ScreenComposerCoordinator()
    let off = ScreenComposerCoordinator()
    off.isPresented = true
    let on = ScreenComposerCoordinator(captureService: PreviewCapture(), ocrService: PreviewOCR())
    _ = await on.capture()
    let hiddenView = NSHostingView(rootView: ScreenToolButton(coordinator: hidden, isBusy: false, capture: {}))
    let offView = NSHostingView(rootView: ScreenToolButton(coordinator: off, isBusy: false, capture: {}))
    XCTAssertEqual(offView.fittingSize.width - hiddenView.fittingSize.width, 40, accuracy: 0.5)
    XCTAssertEqual(offView.fittingSize.height, hiddenView.fittingSize.height)
    let attachment = try XCTUnwrap(on.attachment)
    let preview = VStack(alignment: .leading, spacing: 16) {
      Text("Screen").font(.title2.weight(.semibold))
      ForEach(Array([hidden, off, on].enumerated()), id: \.offset) { index, coordinator in
        Text(["Before adding Screen", "Screen off", "Screen on"][index]).font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 10) {
          HStack(spacing: 0) {
            WebSearchControls(isEnabled: .constant(false), isPresented: .constant(false), isBusy: false, openSettings: {}, captureScreen: {})
            ScreenToolButton(coordinator: coordinator, isBusy: false, capture: {})
          }
          Text("Ask anything").foregroundStyle(.secondary)
          Spacer()
          Label("Auto", systemImage: "sparkles")
        }
        .padding(14)
        .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
      }
      Text("Screenshot attached · ready for a question").font(.caption).foregroundStyle(.secondary)
      ScreenAttachmentView(attachment: attachment, isEnabled: true, isBusy: false, remove: {}, retake: {})
    }
    .padding(24).frame(width: 700).background(Color(nsColor: .windowBackgroundColor))
    let view = NSHostingView(rootView: preview)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 480)
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/AI-Spotlight-Screen-Preview.png"))
    let rendered = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    rendered.name = "Screen composer states"
    rendered.lifetime = .keepAlways
    add(rendered)
  }
}

@MainActor
private struct PreviewCapture: ScreenCapturing {
  func capture() async throws -> NSImage? {
    NSImage(size: NSSize(width: 600, height: 200), flipped: false) { rect in
      NSColor(white: 0.12, alpha: 1).setFill(); rect.fill()
      ("let answer = values.count\nprint(answer)" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular), .foregroundColor: NSColor.systemGreen])
      return true
    }
  }
}

private struct PreviewOCR: ScreenOCRReading {
  func recognize(_ image: CGImage) async throws -> ScreenOCRResult {
    ScreenOCRResult(text: "let answer = values.count\nprint(answer)\n// explain this code", confidence: 0.95)
  }
}
