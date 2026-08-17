import SwiftTerm
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct SerialConsoleView: View {
    @Environment(AppModel.self) private var model
    var workloadID: String
    var deviceID: String
    var fallbackWorkload: Workload
    var fallbackDevice: HomeDeviceHealthSnapshot
    @State private var session = ConsoleSession()
    @State private var terminalRef: TerminalView?

    var body: some View {
        VStack(spacing: 0) {
            if !session.status.isEmpty {
                Text(session.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if access.allowsOpen {
                SerialTerminalView(session: session, terminalRef: $terminalRef)
                    .background(Color.black)
            } else {
                ContentUnavailableView(
                    access == .memberDisabled ? "Member Console unavailable" : "Console unavailable",
                    systemImage: "apple.terminal",
                    description: Text(access.reason)
                )
            }
        }
        .background(Color.black)
        .navigationTitle("Console")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Keyboard", systemImage: "keyboard") {
                        _ = terminalRef?.becomeFirstResponder()
                    }
                    .disabled(!access.allowsOpen)
                }
            }
        #endif
        .task(id: WorkloadStream.sessionTaskID(deviceID: deviceID, workloadID: workloadID, state: workload.state)) {
            guard let client = model.client, access.allowsOpen else {
                session.stop()
                return
            }
            session.start(client: client, workloadID: workload.id, state: workload.state)
        }
        .onChange(of: workload.state) { _, next in
            session.updateState(next)
        }
        .onDisappear { session.stop() }
    }

    private var workload: Workload {
        if let home = model.homeRows.first(where: { $0.workload.id == workloadID && $0.device.hostId == deviceID }) {
            return home.workload
        }
        if model.selectedDevice?.hostId == deviceID, let live = model.workloads.first(where: { $0.id == workloadID }) {
            return live
        }
        return fallbackWorkload
    }

    private var device: HomeDeviceHealthSnapshot {
        model.devices.first(where: { $0.hostId == deviceID }) ?? fallbackDevice
    }

    private var access: WorkloadStreamAccess {
        WorkloadStreamAccess.resolve(isSelfDevice: device.isSelf, state: workload.state)
    }
}

#if os(iOS)
private struct SerialTerminalView: UIViewRepresentable {
    var session: ConsoleSession
    @Binding var terminalRef: TerminalView?

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        )
        view.terminalDelegate = context.coordinator
        view.nativeForegroundColor = .init(red: 0.78, green: 0.97, blue: 0.77, alpha: 1)
        view.nativeBackgroundColor = .black
        context.coordinator.attach(view)
        DispatchQueue.main.async { terminalRef = view }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.session = session
        context.coordinator.attach(view)
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: ConsoleSession
        weak var terminal: TerminalView?

        init(session: ConsoleSession) { self.session = session }

        func attach(_ view: TerminalView) {
            terminal = view
            session.onBytes = { [weak view] bytes in
                view?.feed(byteArray: bytes)
            }
            session.onText = { [weak view] text in
                view?.feed(text: text)
            }
        }

        nonisolated func sizeChanged(source _: TerminalView, newCols _: Int, newRows _: Int) {}
        nonisolated func setTerminalTitle(source _: TerminalView, title _: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}
        nonisolated func send(source _: TerminalView, data: ArraySlice<UInt8>) {
            let copy = Array(data)
            Task { @MainActor in self.session.send(copy[...]) }
        }

        nonisolated func scrolled(source _: TerminalView, position _: Double) {}
        nonisolated func requestOpenLink(source _: TerminalView, link _: String, params _: [String: String]) {}
        nonisolated func bell(source _: TerminalView) {}
        nonisolated func clipboardCopy(source _: TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }

        nonisolated func clipboardRead(source _: TerminalView) -> Data? { nil }
        nonisolated func iTermContent(source _: TerminalView, content _: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
    }
}
#else
private struct SerialTerminalView: NSViewRepresentable {
    var session: ConsoleSession
    @Binding var terminalRef: TerminalView?

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view)
        DispatchQueue.main.async { terminalRef = view }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.session = session
        context.coordinator.attach(view)
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: ConsoleSession
        weak var terminal: TerminalView?

        init(session: ConsoleSession) { self.session = session }

        func attach(_ view: TerminalView) {
            terminal = view
            session.onBytes = { [weak view] bytes in
                view?.feed(byteArray: bytes)
            }
            session.onText = { [weak view] text in
                view?.feed(text: text)
            }
        }

        nonisolated func sizeChanged(source _: TerminalView, newCols _: Int, newRows _: Int) {}
        nonisolated func setTerminalTitle(source _: TerminalView, title _: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}
        nonisolated func send(source _: TerminalView, data: ArraySlice<UInt8>) {
            let copy = Array(data)
            Task { @MainActor in self.session.send(copy[...]) }
        }

        nonisolated func scrolled(source _: TerminalView, position _: Double) {}
        nonisolated func requestOpenLink(source _: TerminalView, link _: String, params _: [String: String]) {}
        nonisolated func bell(source _: TerminalView) {}
        nonisolated func clipboardCopy(source _: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(data: content, encoding: .utf8) ?? "", forType: .string)
        }

        nonisolated func clipboardRead(source _: TerminalView) -> Data? { nil }
        nonisolated func iTermContent(source _: TerminalView, content _: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
    }
}
#endif
