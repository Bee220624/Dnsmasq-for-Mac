import AppKit
import MacNetLogging
import MacNetModels
import SwiftUI
import UniformTypeIdentifiers

/// The Logs page (ticket §5.5).
struct LogsView: View {
    @Environment(LogMonitor.self) private var monitor
    @Environment(SessionController.self) private var session

    @State private var exportError: String?

    var body: some View {
        @Bindable var monitor = monitor

        VStack(spacing: 0) {
            toolbar
            Divider()

            if !session.isRunning && monitor.buffer.events.isEmpty {
                emptyState
            } else {
                logList
            }

            if monitor.droppedCount > 0 {
                Divider()
                droppedBanner
            }
        }
        .accessibilityIdentifier("logs.page")
        .onChange(of: session.activeSession?.id, initial: true) { _, sessionID in
            if let sessionID {
                monitor.start(sessionID: sessionID)
            } else {
                monitor.stop()
            }
        }
        .alert("Could Not Export Log", isPresented: exportErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: exportError ?? "")
        }
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        @Bindable var monitor = monitor

        return HStack(spacing: 10) {
            TextField("Search", text: $monitor.filter.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 260)
                .accessibilityIdentifier("logs.searchField")

            categoryFilter

            Divider().frame(height: 18)

            Button {
                monitor.togglePause()
            } label: {
                Label(
                    monitor.isPaused ? "Resume" : "Pause",
                    systemImage: monitor.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .help(monitor.isPaused
                  ? Text("Resume updating. Nothing is lost while paused.")
                  : Text("Stop updating the view. Collection continues."))
            .accessibilityIdentifier("logs.pauseButton")

            Toggle(isOn: $monitor.autoScroll) {
                Label("Auto-scroll", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("logs.autoScroll")

            Spacer()

            Button("Clear View") {
                monitor.clearView()
            }
            // Ticket §5.5: this empties the view only. The dnsmasq log file on disk is the
            // record and is never truncated by a user tidying their screen.
            .help(Text("Empty the view. The log file on disk is not changed."))
            .accessibilityIdentifier("logs.clearButton")

            Button("Export…") {
                export()
            }
            .disabled(monitor.visibleEvents.isEmpty)
            .accessibilityIdentifier("logs.exportButton")
        }
        .padding(8)
    }

    private var categoryFilter: some View {
        @Bindable var monitor = monitor

        return Menu {
            Button("All Categories") {
                monitor.filter.categories = []
            }
            Divider()
            ForEach(LogCategory.allCases) { category in
                Toggle(isOn: categoryBinding(category)) {
                    Label(category.localizedName, systemImage: category.systemImage)
                }
            }
        } label: {
            Label(categoryLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("logs.categoryPicker")
    }

    private var categoryLabel: String {
        let selected = monitor.filter.categories
        if selected.isEmpty { return String(localized: "All Categories") }
        if selected.count == 1, let only = selected.first {
            return String(localized: String.LocalizationValue(only.displayName))
        }
        return String(localized: "\(selected.count) Categories")
    }

    private func categoryBinding(_ category: LogCategory) -> Binding<Bool> {
        Binding(
            get: { monitor.filter.categories.contains(category) },
            set: { isOn in
                if isOn {
                    monitor.filter.categories.insert(category)
                } else {
                    monitor.filter.categories.remove(category)
                }
            }
        )
    }

    // MARK: - List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(monitor.visibleEvents) { event in
                        row(event)
                            .id(event.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
            .onChange(of: monitor.visibleEvents.last?.id) { _, lastID in
                // Auto-scroll is suspended while paused: the point of pausing is to read
                // something without it moving.
                guard monitor.autoScroll, !monitor.isPaused, let lastID else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .accessibilityIdentifier("logs.list")
    }

    private func row(_ event: LogEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            // Text and symbol, never colour alone (ticket §26.2).
            Label(event.category.localizedName, systemImage: event.category.systemImage)
                .labelStyle(.iconOnly)
                .foregroundStyle(tint(for: event.category))
                .frame(width: 16)
                .accessibilityLabel(Text(event.category.localizedName))

            Text(verbatim: event.message)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func tint(for category: LogCategory) -> Color {
        switch category {
        case .system: .secondary
        case .dhcp: .blue
        case .dns: .purple
        case .warning: .orange
        case .error: .red
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No log output", systemImage: "text.alignleft")
        } description: {
            Text("Live dnsmasq output appears here while a session is running.")
        }
        .accessibilityIdentifier("logs.empty")
    }

    private var droppedBanner: some View {
        // Stated rather than silent: someone scrolled to the top should know the log starts
        // there because lines were evicted, not assume the service just started.
        Label(
            "\(monitor.droppedCount) earlier line(s) are no longer in memory. The complete log is on disk in the session directory.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    // MARK: - Export

    /// Saves the log through a save panel.
    ///
    /// Ticket §21.5: the destination is chosen by the user. Nothing is written anywhere they
    /// did not pick, and nothing is ever uploaded.
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "dnsmasq-for-mac-log.txt"
        panel.canCreateDirectories = true
        panel.message = String(localized: "The exported log stays on this Mac. Dnsmasq for Mac never uploads it.")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try Data(monitor.exportText().utf8).write(to: url, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
