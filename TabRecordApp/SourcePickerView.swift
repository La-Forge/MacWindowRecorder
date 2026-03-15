import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Data model

/// A row in the picker list — wraps either a display or a window.
struct SourceItem: Identifiable, Hashable {
    let id: UUID = UUID()
    let title: String
    let subtitle: String?
    let source: RecordingSource

    static func == (lhs: SourceItem, rhs: SourceItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Window controller

/// Presents the `SourcePickerView` in a floating panel.
final class SourcePickerWindowController: NSWindowController {

    private let onSelection: (RecordingSource) -> Void

    init(content: SCShareableContent, onSelection: @escaping (RecordingSource) -> Void) {
        self.onSelection = onSelection

        let view = SourcePickerView(content: content, onSelection: onSelection)
        let hosting = NSHostingController(rootView: view)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Choose Recording Source"
        window.contentViewController = hosting
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Picker categories

private enum SourceCategory: String, CaseIterable, Identifiable {
    case displays = "Displays"
    case windows  = "Windows"
    var id: Self { self }
}

// MARK: - SwiftUI view

struct SourcePickerView: View {

    let content: SCShareableContent
    let onSelection: (RecordingSource) -> Void

    @State private var category: SourceCategory = .displays
    @State private var selected: SourceItem?

    // MARK: Data

    private var displayItems: [SourceItem] {
        content.displays.map { display in
            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            return SourceItem(
                title: "Display \(display.displayID)",
                subtitle: "\(display.width) × \(display.height)",
                source: .display(display, filter)
            )
        }
    }

    private var windowItems: [SourceItem] {
        content.windows
            .filter { $0.isOnScreen && $0.frame.width > 80 && $0.frame.height > 80 }
            .compactMap { window -> SourceItem? in
                let title: String
                if let t = window.title, !t.isEmpty {
                    title = t
                } else if let app = window.owningApplication {
                    title = app.applicationName
                } else {
                    return nil
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                return SourceItem(
                    title: title,
                    subtitle: window.owningApplication?.applicationName,
                    source: .window(window, filter)
                )
            }
    }

    private var currentItems: [SourceItem] {
        category == .displays ? displayItems : windowItems
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // Category picker
            Picker("Source type", selection: $category) {
                ForEach(SourceCategory.allCases) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            // Source list
            if currentItems.isEmpty {
                Spacer()
                Text("No sources available")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(currentItems, id: \.id, selection: $selected) { item in
                    HStack(spacing: 10) {
                        Image(systemName: category == .displays ? "display" : "macwindow")
                            .frame(width: 20)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.body)
                            if let sub = item.subtitle {
                                Text(sub)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(item)
                }
                .listStyle(.inset)
            }

            Divider()

            // Action buttons
            HStack {
                Button("Cancel") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Start Recording") {
                    guard let item = selected else { return }
                    onSelection(item.source)
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selected == nil)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 400, minHeight: 360)
        // Auto-select first item when category changes or on appear
        .onAppear { selected = currentItems.first }
        .onChange(of: category) { _ in selected = currentItems.first }
    }
}
