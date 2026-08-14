import Foundation
import Observation

enum AppRoute: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case devices
    case workloads
    case library
    case disks
    case networks
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .devices: Copy.devices
        case .workloads: Copy.workloads
        case .library: Copy.library
        case .disks: "Disks"
        case .networks: "Networks"
        case .logs: "Logs"
        case .settings: "Settings"
        }
    }
}

enum SessionPhase: Equatable {
    case launching
    case connect
    case login
    case setupRequired
    case ready
}

@Observable
@MainActor
final class AppModel {
    var phase: SessionPhase = .launching
    var route: AppRoute = .dashboard
    var serverURLText: String
    var username: String
    var password: String = ""
    var banner: String?
    var busy = false

    var devices: [HomeDeviceHealthSnapshot] = []
    var totals: HomeDeviceHealthTotals?
    var selectedDeviceID: String?
    var workloads: [Workload] = []
    var stats: SystemStats?
    var about: SystemAbout?
    var images: [LibraryImage] = []
    var disks: [DiskRecord] = []
    var networks: [NetworkRecord] = []
    var logs: [ServerLogEntry] = []
    var pairing: PairingIssue?
    var actionIDs: Set<String> = []

    private var token: String?
    private var pollTask: Task<Void, Never>?

    var client: APIClient? {
        guard let url = try? DeviceURL.normalize(serverURLText) else { return nil }
        return APIClient(baseURL: url, token: token)
    }

    var selectedDevice: HomeDeviceHealthSnapshot? {
        devices.first { $0.hostId == selectedDeviceID } ?? devices.first { $0.isSelf } ?? devices.first
    }

    var connectedURL: URL? { try? DeviceURL.normalize(serverURLText) }

    init() {
        serverURLText = UserDefaults.standard.string(forKey: "serverURL") ?? DeviceURL.default
        username = UserDefaults.standard.string(forKey: "username") ?? ""
        selectedDeviceID = UserDefaults.standard.string(forKey: "selectedDeviceID")
        token = KeychainStore.readToken()
        if let token, JWT.isExpired(token) {
            KeychainStore.deleteToken()
            self.token = nil
        }
    }

    func bootstrap() async {
        guard token != nil else {
            phase = .connect
            return
        }
        await restoreSession()
    }

    func connect() async {
        banner = nil
        busy = true
        defer { busy = false }
        do {
            let url = try DeviceURL.normalize(serverURLText)
            serverURLText = url.absoluteString
            UserDefaults.standard.set(serverURLText, forKey: "serverURL")
            var probe = APIClient(baseURL: url, token: nil)
            let status = try await probe.probeSetup()
            phase = status.complete ? .login : .setupRequired
        } catch APIError.setupRequired {
            phase = .setupRequired
        } catch {
            banner = error.localizedDescription
        }
    }

    func signIn() async {
        banner = nil
        busy = true
        defer { busy = false }
        do {
            let url = try DeviceURL.normalize(serverURLText)
            serverURLText = url.absoluteString
            var api = APIClient(baseURL: url, token: nil)
            let newToken = try await api.login(username: username, password: password)
            persistSession(token: newToken)
            password = ""
            try await refreshAll()
            phase = .ready
            startPolling()
        } catch APIError.setupRequired {
            phase = .setupRequired
        } catch APIError.unauthorized {
            banner = "Invalid username or password"
        } catch {
            banner = error.localizedDescription
        }
    }

    func logout() {
        stopPolling()
        token = nil
        KeychainStore.deleteToken()
        devices = []
        workloads = []
        stats = nil
        pairing = nil
        phase = .login
        banner = nil
    }

    func disconnect() {
        logout()
        phase = .connect
    }

    func select(_ device: HomeDeviceHealthSnapshot) async {
        selectedDeviceID = device.hostId
        UserDefaults.standard.set(device.hostId, forKey: "selectedDeviceID")
        await refreshDeviceScoped()
    }

    func open(_ next: AppRoute) async {
        route = next
        await refreshRoute()
    }

    func startWorkload(_ workload: Workload) async {
        await mutate(workload.id) { client, device in
            try await client.startWorkload(workload.id, on: device)
        }
    }

    func stopWorkload(_ workload: Workload, force: Bool = false) async {
        await mutate(workload.id) { client, device in
            try await client.stopWorkload(workload.id, force: force, on: device)
        }
    }

    func issuePairing() async {
        banner = nil
        do {
            pairing = try await requireClient().issuePairingCode()
        } catch {
            handle(error)
        }
    }

    func loadPairing() async {
        do {
            pairing = try await requireClient().pairingCode()
        } catch {
            handle(error)
        }
    }

    func revokePairing() async {
        do {
            try await requireClient().revokePairingCode()
            pairing = nil
        } catch {
            handle(error)
        }
    }

    func refreshAll() async throws {
        try await refreshDevices()
        async let scoped: Void = refreshDeviceScoped()
        async let aboutLoad: Void = refreshAbout()
        _ = try await (scoped, aboutLoad)
    }

    private func restoreSession() async {
        do {
            try await refreshAll()
            phase = .ready
            startPolling()
        } catch APIError.setupRequired {
            phase = .setupRequired
        } catch APIError.unauthorized {
            logout()
        } catch {
            banner = error.localizedDescription
            phase = .connect
        }
    }

    private func persistSession(token: String) {
        self.token = token
        KeychainStore.saveToken(token)
        UserDefaults.standard.set(serverURLText, forKey: "serverURL")
        UserDefaults.standard.set(username, forKey: "username")
    }

    private func refreshDevices() async throws {
        let client = try requireClient()
        do {
            let report = try await client.healthReport()
            devices = report.devices
            totals = report.totals
        } catch let APIError.http(status, _) where status == 404 {
            do {
                let list = try await client.deviceList()
                devices = list.devices.map(\.asSnapshot)
                totals = nil
            } catch let APIError.http(status, _) where status == 404 {
                // Pre-Home Device (no PAS-34 registry). Still a valid login.
                devices = [await client.localOnlyDevice()]
                totals = nil
            }
        }
        if selectedDeviceID == nil || !devices.contains(where: { $0.hostId == selectedDeviceID }) {
            selectedDeviceID = devices.first(where: \.isSelf)?.hostId ?? devices.first?.hostId
        }
    }

    private func refreshDeviceScoped() async {
        guard let client else { return }
        let device = selectedDevice
        async let w = optional { try await client.workloads(on: device) }
        async let s = optional { try await client.stats(on: device) }
        async let i = optional { try await client.images(on: device) }
        async let d = optional { try await client.disks(on: device) }
        async let n = optional { try await client.networks(on: device) }
        workloads = await w ?? workloads
        stats = await s ?? stats
        images = await i ?? images
        disks = await d ?? disks
        networks = await n ?? networks
    }

    private func refreshAbout() async {
        about = await optional { try await requireClient().about() } ?? about
    }

    private func refreshRoute() async {
        guard let client else { return }
        switch route {
        case .logs:
            logs = await optional { try await client.logs() } ?? logs
        case .settings:
            await loadPairing()
            await refreshAbout()
        case .devices:
            _ = try? await refreshDevices()
        default:
            await refreshDeviceScoped()
        }
    }

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase == .ready {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self.phase == .ready else { return }
                do {
                    try await self.refreshDevices()
                    await self.refreshDeviceScoped()
                } catch APIError.unauthorized {
                    self.logout()
                } catch APIError.setupRequired {
                    self.phase = .setupRequired
                } catch {
                    // Keep the last good snapshot; transient Device blips should not bounce the UI.
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func mutate(_ id: String, _ work: (APIClient, HomeDeviceHealthSnapshot?) async throws -> Void) async {
        actionIDs.insert(id)
        defer { actionIDs.remove(id) }
        do {
            try await work(requireClient(), selectedDevice)
            await refreshDeviceScoped()
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        if let api = error as? APIError {
            switch api {
            case .unauthorized: logout()
            case .setupRequired: phase = .setupRequired
            default: banner = api.localizedDescription
            }
        } else {
            banner = error.localizedDescription
        }
    }

    private func requireClient() throws -> APIClient {
        guard let client else { throw APIError.invalidURL }
        return client
    }

    private func optional<T>(_ work: () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch APIError.unauthorized {
            logout()
            return nil
        } catch APIError.setupRequired {
            phase = .setupRequired
            return nil
        } catch {
            return nil
        }
    }
}
