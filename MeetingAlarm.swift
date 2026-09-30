import AppKit
import EventKit
import SwiftUI

// MARK: - Configuration

enum Config {
    static let monitorHours: TimeInterval = 48 * 60 * 60
    static let pollInterval: TimeInterval = 20
    static let alarmLeadMinutes = 10
    static let secondAlarmLeadMinutes = 2
    static let snoozeMinutes = 5
}

// MARK: - Event model

struct MonitoredEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendarName: String
    let calendarColor: NSColor
    let meetingURL: URL?
}

// MARK: - Persistent ignored-event store

final class IgnoreStore {
    static let shared = IgnoreStore()

    private let defaults = UserDefaults.standard
    private let key = "ignoredEventIDs"

    private var ids: Set<String> {
        get {
            Set(defaults.stringArray(forKey: key) ?? [])
        }
        set {
            defaults.set(Array(newValue), forKey: key)
        }
    }

    func isIgnored(_ id: String) -> Bool {
        ids.contains(id)
    }

    func setIgnored(_ id: String, ignored: Bool) {
        var current = ids

        if ignored {
            current.insert(id)
        } else {
            current.remove(id)
        }

        ids = current
    }
}

// MARK: - Snooze store

final class SnoozeStore {
    static let shared = SnoozeStore()

    private var values: [String: Date] = [:]

    func snooze(_ id: String, minutes: Int) {
        values[id] = Date().addingTimeInterval(
            TimeInterval(minutes * 60)
        )
    }

    func isSnoozed(_ id: String) -> Bool {
        guard let until = values[id] else {
            return false
        }

        if until <= Date() {
            values.removeValue(forKey: id)
            return false
        }

        return true
    }
}

// MARK: - Calendar manager

@MainActor
final class CalendarManager: ObservableObject {

    static let shared = CalendarManager()

    private let store = EKEventStore()

    @Published private(set) var events: [MonitoredEvent] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var hasAccess = false
    @Published private(set) var errorMessage: String?

    private var timer: Timer?

    private init() {}

    func start() {
        requestAccess()
    }

    private func requestAccess() {
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()

                await MainActor.run {
                    self.hasAccess = granted

                    if granted {
                        self.refresh()
                        self.startTimer()
                    } else {
                        self.errorMessage =
                            "Calendar access was not granted."
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage =
                        error.localizedDescription
                }
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(
            withTimeInterval: Config.pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard hasAccess else {
            return
        }

        let now = Date()
        let end = now.addingTimeInterval(Config.monitorHours)

        let calendars = store.calendars(for: .event)

        let predicate = store.predicateForEvents(
            withStart: now,
            end: end,
            calendars: calendars
        )

        let rawEvents = store.events(matching: predicate)

        var result: [MonitoredEvent] = []

        for event in rawEvents {
            guard
                !event.isAllDay,
                let start = event.startDate
            else {
                continue
            }

            let id =
                event.eventIdentifier
                ?? "\(event.title)-\(start.timeIntervalSince1970)"

            let title =
                event.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            guard !title.isEmpty else {
                continue
            }

            let url = extractMeetingURL(event)

            let color =
                NSColor(
                    cgColor:
                        event.calendar?.cgColor
                        ?? NSColor.systemBlue.cgColor
                )
                ?? NSColor.systemBlue

            result.append(
                MonitoredEvent(
                    id: id,
                    title: title,
                    start: start,
                    end: event.endDate ?? start,
                    calendarName:
                        event.calendar?.title ?? "Calendar",
                    calendarColor: color,
                    meetingURL: url
                )
            )
        }

        events = result.sorted {
            $0.start < $1.start
        }

        lastRefresh = Date()

        checkForAlarms()
    }

    private func checkForAlarms() {
        let now = Date()

        for event in events {
            guard !IgnoreStore.shared.isIgnored(event.id) else {
                continue
            }

            guard !SnoozeStore.shared.isSnoozed(event.id) else {
                continue
            }

            let secondsUntilStart =
                event.start.timeIntervalSince(now)

            // First alarm: approximately 10 minutes before.
            if secondsUntilStart <=
                TimeInterval(Config.alarmLeadMinutes * 60),
               secondsUntilStart >
                TimeInterval(Config.secondAlarmLeadMinutes * 60)
            {
                AlarmController.shared.show(
                    event: event,
                    reason:
                        "MEETING IN \(Config.alarmLeadMinutes) MINUTES"
                )
            }

            // Second alarm: 2 minutes before through start.
            if secondsUntilStart <=
                TimeInterval(Config.secondAlarmLeadMinutes * 60),
               secondsUntilStart >= -30
            {
                AlarmController.shared.show(
                    event: event,
                    reason:
                        secondsUntilStart >= 0
                        ? "MEETING STARTING NOW"
                        : "MEETING STARTED"
                )
            }
        }
    }

    func setIgnored(
        _ event: MonitoredEvent,
        ignored: Bool
    ) {
        IgnoreStore.shared.setIgnored(
            event.id,
            ignored: ignored
        )
    }

    private func extractMeetingURL(
        _ event: EKEvent
    ) -> URL? {

        if let url = event.url {
            return url
        }

        let text =
            (event.notes ?? "") + "\n" +
            (event.location ?? "")

        let pattern =
            #"https?://[^\s<>\"]+"#

        guard
            let regex =
                try? NSRegularExpression(
                    pattern: pattern
                )
        else {
            return nil
        }

        let range =
            NSRange(
                text.startIndex..<text.endIndex,
                in: text
            )

        guard
            let match =
                regex.firstMatch(
                    in: text,
                    range: range
                ),
            let swiftRange =
                Range(match.range, in: text)
        else {
            return nil
        }

        let string =
            String(text[swiftRange])
                .trimmingCharacters(
                    in: CharacterSet(
                        charactersIn: ".,);"
                    )
                )

        return URL(string: string)
    }
}

// MARK: - Alarm view

struct AlarmView: View {

    let event: MonitoredEvent
    let reason: String
    let dismiss: () -> Void
    let snooze: () -> Void
    let openMeeting: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 28) {

            Text(reason)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.red)

            VStack(spacing: 8) {
                Text(event.title)
                    .font(.system(size: 32, weight: .bold))
                    .multilineTextAlignment(.center)

                Text(
                    "\(Self.timeFormatter.string(from: event.start))–\(Self.timeFormatter.string(from: event.end)) • \(event.calendarName)"
                )
                .font(.title3)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 16) {
                Button("Dismiss") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Snooze \(Config.snoozeMinutes) min") {
                    snooze()
                }

                if event.meetingURL != nil {
                    Button("Join Meeting") {
                        openMeeting()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(width: 760, height: 470)
    }
}

// MARK: - Alarm controller

@MainActor
final class AlarmController {

    static let shared = AlarmController()

    private var panel: NSPanel?
    private var sound: NSSound?
    private var soundTimer: Timer?

    private var currentEvent: MonitoredEvent?

    private init() {}

    func show(
        event: MonitoredEvent,
        reason: String
    ) {
        // Don't recreate the same alarm every 20 seconds.
        if currentEvent?.id == event.id,
           panel != nil {
            return
        }

        currentEvent = event

        dismissWindowOnly()

        let view = AlarmView(
            event: event,
            reason: reason,
            dismiss: { [weak self] in
                self?.dismiss()
            },
            snooze: { [weak self] in
                self?.snooze()
            },
            openMeeting: { [weak self] in
                self?.openMeeting()
            }
        )

        let hosting =
            NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect:
                NSRect(
                    x: 0,
                    y: 0,
                    width: 760,
                    height: 470
                ),
            styleMask: [
                .titled,
                .closable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        panel.title = "MEETING ALARM"

        panel.contentView = hosting

        // Make it substantially more intrusive than a notification.
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.preventsApplicationTerminationWhenModal = false

        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        panel.center()

        self.panel = panel

        NSApp.activate(
            ignoringOtherApps: true
        )

        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        startAlarmSound()
    }

    private func startAlarmSound() {
        stopAlarmSound()

        playSound()

        soundTimer =
            Timer.scheduledTimer(
                withTimeInterval: 2.5,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.playSound()
                }
            }
    }

    private func playSound() {
        sound?.stop()

        sound =
            NSSound(
                named: NSSound.Name("Glass")
            )

        sound?.play()
    }

    private func stopAlarmSound() {
        soundTimer?.invalidate()
        soundTimer = nil

        sound?.stop()
        sound = nil
    }

    func dismiss() {
        stopAlarmSound()
        dismissWindowOnly()

        currentEvent = nil
    }

    private func dismissWindowOnly() {
        panel?.orderOut(nil)
        panel = nil
    }

    func snooze() {
        guard let event = currentEvent else {
            return
        }

        SnoozeStore.shared.snooze(
            event.id,
            minutes: Config.snoozeMinutes
        )

        dismiss()
    }

    private func openMeeting() {
        guard
            let url = currentEvent?.meetingURL
        else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}

// MARK: - Monitor window

struct MonitorView: View {

    @ObservedObject
    private var calendar = CalendarManager.shared

    @State
    private var showSettings = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {

            header

            Divider()

            if !calendar.hasAccess {
                permissionView
            } else if calendar.events.isEmpty {
                emptyView
            } else {
                eventList
            }

            Divider()

            footer
        }
        .frame(
            minWidth: 780,
            minHeight: 520
        )
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var header: some View {
        HStack {
            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                Text("Meeting Alarm")
                    .font(
                        .system(
                            size: 26,
                            weight: .bold
                        )
                    )

                Text(
                    "Monitoring events for the next 48 hours"
                )
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(
                        calendar.hasAccess
                        ? .green
                        : .red
                    )
                    .frame(
                        width: 10,
                        height: 10
                    )

                Text(
                    calendar.hasAccess
                    ? "Running"
                    : "No calendar access"
                )
            }

            Button("Refresh") {
                calendar.refresh()
            }

            Button("Settings") {
                showSettings = true
            }
        }
        .padding(20)
    }

    private var eventList: some View {
        List {
            ForEach(calendar.events) { event in

                let ignored =
                    IgnoreStore.shared.isIgnored(
                        event.id
                    )

                HStack(spacing: 12) {

                    RoundedRectangle(
                        cornerRadius: 3
                    )
                    .fill(
                        Color(
                            nsColor:
                                event.calendarColor
                        )
                    )
                    .frame(
                        width: 5,
                        height: 44
                    )

                    VStack(
                        alignment: .leading,
                        spacing: 3
                    ) {
                        Text(event.title)
                            .font(
                                .system(
                                    size: 16,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(
                                ignored
                                ? .secondary
                                : .primary
                            )

                        HStack(spacing: 8) {
                            Text(
                                "\(Self.timeFormatter.string(from: event.start))–\(Self.timeFormatter.string(from: event.end))"
                            )

                            Text("•")

                            Text(event.calendarName)
                        }
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )
                    }

                    Spacer()

                    if event.meetingURL != nil {
                        Image(
                            systemName:
                                "video.fill"
                        )
                        .foregroundStyle(
                            .secondary
                        )
                    }

                    Toggle(
                        "Monitor",
                        isOn:
                            Binding(
                                get: {
                                    !IgnoreStore.shared
                                        .isIgnored(
                                            event.id
                                        )
                                },
                                set: { value in
                                    calendar.setIgnored(
                                        event,
                                        ignored: !value
                                    )
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.inset)
    }

    private var permissionView: some View {
        VStack(spacing: 15) {
            Image(
                systemName:
                    "calendar.badge.exclamationmark"
            )
            .font(.system(size: 45))

            Text("Calendar access required")
                .font(.title2.bold())

            Text(
                "Meeting Alarm needs Full Access to your calendars."
            )
            .foregroundStyle(.secondary)

            Button(
                "Open Calendar Privacy Settings"
            ) {
                if let url =
                    URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    )
                {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(
                systemName: "calendar"
            )
            .font(.system(size: 40))

            Text("No upcoming events")
                .font(.title2)

            Text(
                "No non-all-day calendar events were found in the next 48 hours."
            )
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if let date = calendar.lastRefresh {
                Text(
                    "Last calendar check: \(date.formatted(date: .omitted, time: .standard))"
                )
            }

            Spacer()

            Text(
                "\(calendar.events.count) events"
            )

            Text(
                "• Alarm: \(Config.alarmLeadMinutes) min before"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
    }
}

// MARK: - Settings

struct SettingsView: View {

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 18
        ) {
            Text("Settings")
                .font(.title.bold())

            Text(
                "Current configuration"
            )
            .font(.headline)

            LabeledContent(
                "First alarm",
                value:
                    "\(Config.alarmLeadMinutes) minutes before"
            )

            LabeledContent(
                "Second alarm",
                value:
                    "\(Config.secondAlarmLeadMinutes) minutes before"
            )

            LabeledContent(
                "Snooze",
                value:
                    "\(Config.snoozeMinutes) minutes"
            )

            LabeledContent(
                "Calendar refresh",
                value:
                    "\(Int(Config.pollInterval)) seconds"
            )

            Spacer()

            Text(
                "Change these values at the top of MeetingAlarm.swift and rebuild."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(
            width: 450,
            height: 330
        )
    }
}

// MARK: - Application delegate

final class AppDelegate:
    NSObject,
    NSApplicationDelegate {

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        StatusBarController.shared.setup()

        CalendarManager.shared.start()

        // Show the monitor immediately on first launch.
        MonitorWindowController.shared.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}

// MARK: - Monitor window controller

@MainActor
final class MonitorWindowController {

    static let shared =
        MonitorWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(
                ignoringOtherApps: true
            )

            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = MonitorView()

        let hosting =
            NSHostingView(rootView: view)

        let window =
            NSWindow(
                contentRect:
                    NSRect(
                        x: 0,
                        y: 0,
                        width: 900,
                        height: 600
                    ),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable
                ],
                backing: .buffered,
                defer: false
            )

        window.title = "Meeting Alarm"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window

        NSApp.activate(
            ignoringOtherApps: true
        )

        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Menu bar

@MainActor
final class StatusBarController {

    static let shared =
        StatusBarController()

    private let item =
        NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )

    func setup() {
        guard let button = item.button else {
            return
        }

        button.image =
            NSImage(
                systemSymbolName:
                    "alarm.fill",
                accessibilityDescription:
                    "Meeting Alarm"
            )

        let menu = NSMenu()

        let open =
            NSMenuItem(
                title: "Open Monitor",
                action: #selector(openMonitor),
                keyEquivalent: ""
            )

        open.target = self

        let refresh =
            NSMenuItem(
                title: "Check Calendar Now",
                action: #selector(refresh),
                keyEquivalent: ""
            )

        refresh.target = self

        menu.addItem(open)
        menu.addItem(refresh)
        menu.addItem(.separator())

        let quit =
            NSMenuItem(
                title: "Quit Meeting Alarm",
                action: #selector(quit),
                keyEquivalent: "q"
            )

        quit.target = self

        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func openMonitor() {
        MonitorWindowController.shared.show()
    }

    @objc private func refresh() {
        CalendarManager.shared.refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared

let delegate = AppDelegate()

app.delegate = delegate

app.setActivationPolicy(.accessory)

app.run()
