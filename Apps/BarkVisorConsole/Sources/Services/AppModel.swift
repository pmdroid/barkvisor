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

enum PhoneTab: String, Hashable {
    case home
    case devices
    case settings
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
    var phoneTab: PhoneTab = .home
    var homeRows: [HomeWorkloadRow] = []
    var homeLoadErrors: [HomeDeviceLoadError] = []
    var homeUnreachable: [HomeDeviceHealthSnapshot] = []
    var homeLoaded = false

    private var token: String?
    /// Origin the JWT was issued for. Polling must never follow a draft URL edit.
    private var sessionURL: URL?
    private var pollTask: Task<Void, Never>?
    private var scopedGeneration = 0
    private var homeGeneration = 0

    var client: APIClient? {
        guard let sessionURL, let token else { return nil }
        return APIClient(baseURL: sessionURL, token: token)
    }

    var selectedDevice: HomeDeviceHealthSnapshot? {
        devices.first { $0.hostId == selectedDeviceID } ?? devices.first { $0.isSelf } ?? devices.first
    }

    var connectedURL: URL? { sessionURL ?? (try? DeviceURL.normalize(serverURLText)) }

    init() {
        let storedURL = UserDefaults.standard.string(forKey: "serverURL") ?? DeviceURL.default
        let migrated = DeviceURL.migrateStored(storedURL)
        let resolved: String
        if migrated != storedURL, let url = try? DeviceURL.normalize(migrated) {
            resolved = url.absoluteString
            UserDefaults.standard.set(resolved, forKey: "serverURL")
        } else {
            resolved = migrated
        }
        serverURLText = resolved
        username = UserDefaults.standard.string(forKey: "username") ?? ""
        selectedDeviceID = UserDefaults.standard.string(forKey: "selectedDeviceID")
        token = KeychainStore.readToken()
        if let stored = token {
            if JWT.isExpired(stored) {
                KeychainStore.deleteToken()
                token = nil
            } else if let url = try? DeviceURL.normalize(serverURLText) {
                sessionURL = url
            } else {
                KeychainStore.deleteToken()
                token = nil
            }
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
        dropScopedState()
        dropHomeState()
        devices = []
        totals = nil
        pairing = nil
        about = nil
        logs = []
        phase = .login
        banner = nil
    }

    func disconnect() {
        logout()
        sessionURL = nil
        phase = .connect
    }

    /// Persist a Settings URL edit. A different origin drops the JWT so poll cannot leak it.
    func applyServerURL(_ raw: String) {
        let next: URL
        do {
            next = try DeviceURL.normalize(raw)
        } catch {
            banner = error.localizedDescription
            return
        }
        serverURLText = next.absoluteString
        UserDefaults.standard.set(serverURLText, forKey: "serverURL")
        guard token != nil, let sessionURL, !DeviceURL.sameOrigin(sessionURL, next) else { return }
        stopPolling()
        token = nil
        KeychainStore.deleteToken()
        self.sessionURL = nil
        dropScopedState()
        dropHomeState()
        devices = []
        totals = nil
        pairing = nil
        about = nil
        logs = []
        phase = .connect
        banner = "Device URL changed. Sign in again."
    }

    func select(_ device: HomeDeviceHealthSnapshot) async {
        selectedDeviceID = device.hostId
        UserDefaults.standard.set(device.hostId, forKey: "selectedDeviceID")
        dropScopedState()
        await refreshDeviceScoped()
    }

    func open(_ next: AppRoute) async {
        route = next
        await refreshRoute()
    }

    func startWorkload(_ workload: Workload, on device: HomeDeviceHealthSnapshot? = nil) async {
        let target = device ?? selectedDevice
        await mutate(actionID(for: workload, explicit: device), on: target) { client, resolved in
            try await client.startWorkload(workload.id, on: resolved)
        }
    }

    func stopWorkload(_ workload: Workload, force: Bool = false, on device: HomeDeviceHealthSnapshot? = nil) async {
        let target = device ?? selectedDevice
        await mutate(actionID(for: workload, explicit: device), on: target) { client, resolved in
            try await client.stopWorkload(workload.id, force: force, on: resolved)
        }
    }

    func refreshHome() async {
        _ = try? await refreshDevices()
        await refreshHomeUnion()
    }

    func refreshPhoneDevices() async {
        _ = try? await refreshDevices()
    }

    func openPhoneTab(_ tab: PhoneTab) async {
        phoneTab = tab
        switch tab {
        case .home:
            await refreshHome()
        case .devices:
            await refreshPhoneDevices()
        case .settings:
            await refreshAbout()
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
        async let home: Void = refreshHomeUnion()
        _ = await (scoped, aboutLoad, home)
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
        sessionURL = try? DeviceURL.normalize(serverURLText)
        KeychainStore.saveToken(token)
        UserDefaults.standard.set(serverURLText, forKey: "serverURL")
        UserDefaults.standard.set(username, forKey: "username")
    }

    private func refreshDevices() async throws {
        let client = try requireClient()
        let health: Result<HomeDeviceHealthReport, Error>
        do {
            health = .success(try await client.healthReport())
        } catch {
            health = .failure(error)
        }
        switch health {
        case let .success(report):
            devices = report.devices
            totals = report.totals
        case let .failure(healthError):
            let healthStatus = HomeDeviceDirectory.httpStatus(from: healthError)
            if healthStatus != 404 { throw healthError }
            let list: Result<HomeDeviceList, Error>
            do {
                list = .success(try await client.deviceList())
            } catch {
                list = .failure(error)
            }
            switch list {
            case let .success(body):
                _ = try HomeDeviceDirectory.resolution(
                    healthStatus: healthStatus,
                    listStatus: nil,
                    aboutSucceeded: true
                )
                devices = body.devices.map(\.asSnapshot)
                totals = nil
            case let .failure(listError):
                let listStatus = HomeDeviceDirectory.httpStatus(from: listError)
                if listStatus != 404 { throw listError }
                let aboutSucceeded = (try? await client.about()) != nil
                _ = try HomeDeviceDirectory.resolution(
                    healthStatus: healthStatus,
                    listStatus: listStatus,
                    aboutSucceeded: aboutSucceeded
                )
                devices = [await client.localOnlyDevice()]
                totals = nil
            }
        }
        if selectedDeviceID == nil || !devices.contains(where: { $0.hostId == selectedDeviceID }) {
            dropScopedState()
            selectedDeviceID = devices.first(where: \.isSelf)?.hostId ?? devices.first?.hostId
        }
    }

    private func refreshDeviceScoped() async {
        guard let client else { return }
        let generation = scopedGeneration
        let device = selectedDevice
        async let w = optional { try await client.workloads(on: device) }
        async let s = optional { try await client.stats(on: device) }
        async let i = optional { try await client.images(on: device) }
        async let d = optional { try await client.disks(on: device) }
        async let n = optional { try await client.networks(on: device) }
        let nextWorkloads = await w
        let nextStats = await s
        let nextImages = await i
        let nextDisks = await d
        let nextNetworks = await n
        guard generation == scopedGeneration else { return }
        if let nextWorkloads { workloads = nextWorkloads }
        if let nextStats { stats = nextStats }
        if let nextImages { images = nextImages }
        if let nextDisks { disks = nextDisks }
        if let nextNetworks { networks = nextNetworks }
    }

    private func dropScopedState() {
        scopedGeneration += 1
        workloads = []
        stats = nil
        images = []
        disks = []
        networks = []
    }

    private func dropHomeState() {
        homeGeneration += 1
        homeRows = []
        homeLoadErrors = []
        homeUnreachable = []
        homeLoaded = false
    }

    private func refreshHomeUnion() async {
        guard let client else { return }
        let generation = homeGeneration
        let directory = devices
        var loads: [String: Result<[Workload], Error>] = [:]
        await withTaskGroup(of: (String, Result<[Workload], Error>).self) { group in
            for device in directory where device.isReachable {
                group.addTask {
                    do {
                        let list = try await client.workloads(on: device)
                        return (device.hostId, .success(list))
                    } catch {
                        return (device.hostId, .failure(error))
                    }
                }
            }
            for await item in group {
                loads[item.0] = item.1
            }
        }
        guard generation == homeGeneration else { return }
        if loads.values.contains(where: { if case let .failure(error) = $0 { return error as? APIError == .unauthorized } else { return false } }) {
            logout()
            return
        }
        if loads.values.contains(where: { if case let .failure(error) = $0 { return error as? APIError == .setupRequired } else { return false } }) {
            phase = .setupRequired
            return
        }
        let mapped = loads.mapValues { result -> HomeWorkloadUnion.Load in
            switch result {
            case let .success(workloads): .success(workloads)
            case let .failure(error): .failure(error.localizedDescription)
            }
        }
        let snapshot = HomeWorkloadUnion.build(devices: directory, loads: mapped)
        homeRows = snapshot.rows
        homeLoadErrors = snapshot.loadErrors
        homeUnreachable = snapshot.unreachable
        homeLoaded = true
    }

    private func actionID(for workload: Workload, explicit device: HomeDeviceHealthSnapshot?) -> String {
        if let device { return "\(device.hostId)/\(workload.id)" }
        return workload.id
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
                    await self.refreshHomeUnion()
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

    private func mutate(
        _ id: String,
        on device: HomeDeviceHealthSnapshot?,
        _ work: (APIClient, HomeDeviceHealthSnapshot?) async throws -> Void
    ) async {
        actionIDs.insert(id)
        defer { actionIDs.remove(id) }
        do {
            try await work(requireClient(), device)
            await refreshDeviceScoped()
            await refreshHomeUnion()
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
