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

    var id: String {
        rawValue
    }

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
    case library
    case devices
    case settings
}

/// Outcome of POST /api/auth/refresh. Only `.unauthorized` (401) may drop the Keychain refresh token.
enum SessionRefreshResult: Equatable {
    case rotated(String)
    case unauthorized
    case unavailable(String)

    static func from(error: Error) -> SessionRefreshResult {
        guard let api = error as? APIError else {
            return .unavailable(error.localizedDescription)
        }
        switch api {
        case .unauthorized:
            return .unauthorized
        case let .http(status, _) where status == 401:
            return .unauthorized
        default:
            return .unavailable(api.localizedDescription)
        }
    }

    /// No refresh token or Device origin: permanent, not a transport blip.
    static func fromLocalMaterial(refreshToken: String?, origin: URL?) -> SessionRefreshResult? {
        if refreshToken == nil || origin == nil { return .unauthorized }
        return nil
    }
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
    var catalogRepos: [ImageRepository] = []
    var catalogImagesByRepo: [String: [CatalogImage]] = [:]
    var catalogLoaded = false
    var catalogFetchFailed = false
    var disks: [DiskRecord] = []
    var networks: [NetworkRecord] = []
    var logs: [ServerLogEntry] = []
    var pairing: PairingIssue?
    var loginOffer: LoginOfferIssue?
    var actionIDs: Set<String> = []
    var phoneTab: PhoneTab = .home
    var homeRows: [HomeWorkloadRow] = []
    var homeLoadErrors: [HomeDeviceLoadError] = []
    var homeUnreachable: [HomeDeviceHealthSnapshot] = []
    var homeLoaded = false

    private var token: String?
    private var refreshToken: String?
    /// Origin the JWT was issued for. Polling must never follow a draft URL edit.
    private var sessionURL: URL?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<SessionRefreshResult, Never>?
    private var sessionGeneration = 0
    private var scopedGeneration = 0
    private var catalogGeneration = 0
    private var homeGeneration = 0
    private var pairingGeneration = 0
    private var pairingMutating = false

    var client: APIClient? {
        guard let sessionURL, let token else { return nil }
        var api = APIClient(baseURL: sessionURL, token: token)
        api.refreshOnce = { [weak self] in
            guard let self else { return .unavailable("Sign in required") }
            return await self.refreshAccessToken()
        }
        return api
    }

    var selectedDevice: HomeDeviceHealthSnapshot? {
        devices.first { $0.hostId == selectedDeviceID } ?? devices.first { $0.isSelf } ?? devices.first
    }

    var unreachablePairedDeviceCount: Int {
        DevicesTabBadge.count(in: devices)
    }

    /// Mac: selected Device. iOS: This Device (`role=self`) unless a picker already exists.
    var libraryDevice: HomeDeviceHealthSnapshot? {
        LibraryCatalog.targetDevice(
            devices: devices,
            selectedID: selectedDeviceID,
            preferSelf: LibraryCatalog.preferSelfDevice,
        )
    }

    var catalogGroups: [CatalogGroup] {
        LibraryCatalog.groups(repos: catalogRepos, imagesByRepo: catalogImagesByRepo)
    }

    var connectedURL: URL? {
        sessionURL ?? (try? DeviceURL.normalize(serverURLText))
    }

    init() {
        let storedURL = UserDefaults.standard.string(forKey: "serverURL") ?? DeviceURL.default
        let migrated = DeviceURL.migrateStored(storedURL)
        if let url = try? DeviceURL.normalize(migrated) {
            let resolved = url.absoluteString
            serverURLText = resolved
            if resolved != storedURL {
                UserDefaults.standard.set(resolved, forKey: "serverURL")
            }
        } else {
            serverURLText = migrated
        }
        username = UserDefaults.standard.string(forKey: "username") ?? ""
        selectedDeviceID = UserDefaults.standard.string(forKey: "selectedDeviceID")
        token = KeychainStore.readToken()
        refreshToken = KeychainStore.readRefreshToken()
        if token != nil || refreshToken != nil {
            if let url = try? DeviceURL.normalize(serverURLText) {
                sessionURL = url
            } else {
                KeychainStore.deleteSession()
                token = nil
                refreshToken = nil
            }
        }
    }

    func bootstrap() async {
        if refreshToken != nil, JWT.needsRefresh(token) {
            switch await refreshAccessToken() {
            case .rotated:
                break
            case .unauthorized:
                clearSessionLocally()
                phase = sessionURL == nil ? .connect : .login
                return
            case let .unavailable(message):
                if token == nil || JWT.isExpired(token ?? "") {
                    banner = message
                    phase = sessionURL == nil ? .connect : .login
                    return
                }
            }
        }
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
            let session = try await api.login(username: username, password: password)
            persistSession(session, origin: url)
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
        let presented = refreshToken
        let url = sessionURL
        let access = token
        bumpSessionGeneration()
        stopPolling()
        clearSessionLocally()
        dropScopedState()
        dropHomeState()
        devices = []
        totals = nil
        pairing = nil
        loginOffer = nil
        about = nil
        logs = []
        phase = url == nil ? .connect : .login
        banner = nil
        if let url, presented != nil || access != nil {
            Task {
                var api = APIClient(baseURL: url, token: access)
                try? await api.logout(refreshToken: presented)
            }
        }
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
        guard token != nil || refreshToken != nil, let sessionURL, !DeviceURL.sameOrigin(sessionURL, next) else { return }
        bumpSessionGeneration()
        stopPolling()
        clearSessionLocally()
        self.sessionURL = nil
        dropScopedState()
        dropHomeState()
        devices = []
        totals = nil
        pairing = nil
        loginOffer = nil
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
        if route == .library {
            await refreshLibrary()
        }
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

    func restartWorkload(_ workload: Workload, on device: HomeDeviceHealthSnapshot? = nil) async {
        let target = device ?? selectedDevice
        await mutate(actionID(for: workload, explicit: device), on: target) { client, resolved in
            try await client.restartWorkload(workload.id, on: resolved)
        }
    }

    func setStartOnBoot(_ workload: Workload, enabled: Bool, on device: HomeDeviceHealthSnapshot? = nil) async {
        let target = device ?? selectedDevice
        await mutate(actionID(for: workload, explicit: device), on: target) { client, resolved in
            try await client.setStartOnBoot(workload.id, enabled: enabled, on: resolved)
        }
    }

    func attachISO(_ isoID: String, to workload: Workload, on device: HomeDeviceHealthSnapshot) async {
        await mutate(actionID(for: workload, explicit: device), on: device) { client, resolved in
            try await client.attachISO(workload.id, isoID: isoID, on: resolved)
        }
    }

    func ejectISO(_ isoID: String, from workload: Workload, on device: HomeDeviceHealthSnapshot) async {
        await mutate(actionID(for: workload, explicit: device), on: device) { client, resolved in
            try await client.ejectISO(workload.id, isoID: isoID, on: resolved)
        }
    }

    func libraryImages(on device: HomeDeviceHealthSnapshot) async -> [LibraryImage]? {
        guard device.isReachable else { return nil }
        do {
            return try await requireClient().images(on: device)
        } catch {
            handle(error)
            return nil
        }
    }

    func createWorkload(
        name: String,
        image: LibraryImage,
        on device: HomeDeviceHealthSnapshot,
        workloadClass: String? = nil,
        openaiBaseURL: String? = nil,
    ) async -> Workload? {
        let key = "create/\(device.hostId)"
        actionIDs.insert(key)
        defer { actionIDs.remove(key) }
        do {
            let body = try CreateWorkload.body(
                name: name,
                image: image,
                hostCPUCount: device.resources?.cpuCount,
                workloadClass: workloadClass,
                openaiBaseURL: openaiBaseURL,
            )
            let created = try await requireClient().createWorkload(body, on: device)
            await refreshDeviceScoped()
            await refreshHomeUnion()
            return created
        } catch {
            handle(error)
            return nil
        }
    }

    func downloadCatalogImage(_ image: CatalogImage) async {
        let id = "catalog:\(image.id)"
        actionIDs.insert(id)
        defer { actionIDs.remove(id) }
        do {
            _ = try await requireClient().downloadCatalogImage(image.id, on: libraryDevice)
            await refreshLibraryImages()
        } catch {
            handle(error)
        }
    }

    func refreshLibrary() async {
        guard let client else { return }
        let generation = catalogGeneration
        let device = libraryDevice
        async let imagesLoad = optional { try await client.images(on: device) }
        async let reposLoad = optional { try await client.repositories(on: device) }
        let nextImages = await imagesLoad
        let nextRepos = await reposLoad
        guard generation == catalogGeneration else { return }
        if let nextImages { images = nextImages }
        guard let repos = nextRepos else {
            catalogLoaded = true
            return
        }
        let imageRepos = LibraryCatalog.imageRepositories(repos)
        catalogRepos = imageRepos
        var loads: [String: CatalogRepoLoad] = [:]
        await withTaskGroup(of: (String, CatalogRepoLoad).self) { group in
            for repo in imageRepos {
                group.addTask {
                    do {
                        let images = try await client.catalogImages(repositoryID: repo.id, on: device)
                        return (repo.id, .fetched(images))
                    } catch {
                        return (repo.id, .failed)
                    }
                }
            }
            for await item in group {
                loads[item.0] = item.1
            }
        }
        guard generation == catalogGeneration else { return }
        let merged = LibraryCatalog.mergeCatalogImages(previous: catalogImagesByRepo, loads: loads)
        catalogImagesByRepo = merged.imagesByRepo
        catalogFetchFailed = merged.fetchFailed
        catalogLoaded = true
    }

    func anyReadyLibraryImage() async -> Bool {
        if CreateWorkload.hasReadyImage(images) { return true }
        for device in devices where device.isReachable {
            if Task.isCancelled { return false }
            if await CreateWorkload.hasReadyImage(libraryImages(on: device) ?? []) { return true }
        }
        return false
    }

    func guestInfo(for workloadID: String, on device: HomeDeviceHealthSnapshot?) async -> GuestInfo? {
        await optional { try await requireClient().guestInfo(workloadID, on: device) }
    }

    func networkMode(for networkID: String?, on device: HomeDeviceHealthSnapshot) async -> String? {
        guard let networkID else { return nil }
        if selectedDevice?.hostId == device.hostId,
           let mode = networks.first(where: { $0.id == networkID })?.mode {
            return mode
        }
        guard let nets = await optional({ try await requireClient().networks(on: device) }) else {
            return nil
        }
        return nets.first { $0.id == networkID }?.mode
    }

    func refreshHome() async {
        await refreshHealthAndWorkloads()
    }

    func refreshPhoneDevices() async {
        await refreshHealthAndWorkloads()
    }

    /// Home and Devices pull-to-refresh share the health report and workload union.
    private func refreshHealthAndWorkloads() async {
        _ = try? await refreshDevices()
        await refreshHomeUnion()
    }

    func openPhoneTab(_ tab: PhoneTab) async {
        phoneTab = tab
        switch tab {
        case .home:
            await refreshHome()
        case .library:
            await refreshLibrary()
        case .devices:
            await refreshPhoneDevices()
        case .settings:
            await refreshAbout()
        }
    }

    func issuePairing(advertisedHost: String? = nil) async {
        banner = nil
        pairingGeneration += 1
        let generation = pairingGeneration
        pairingMutating = true
        defer { if pairingGeneration == generation { pairingMutating = false } }
        do {
            let issued = try await requireClient().issuePairingCode(advertisedHost: advertisedHost)
            guard pairingGeneration == generation else { return }
            pairing = issued
        } catch {
            guard pairingGeneration == generation else { return }
            handle(error)
        }
    }

    func loadPairing() async {
        if pairingMutating { return }
        let generation = pairingGeneration
        do {
            let loaded = try await requireClient().pairingCode()
            guard pairingGeneration == generation, !pairingMutating else { return }
            pairing = loaded
        } catch {
            guard pairingGeneration == generation, !pairingMutating else { return }
            handle(error)
        }
    }

    func revokePairing() async {
        pairingGeneration += 1
        let generation = pairingGeneration
        pairingMutating = true
        defer { if pairingGeneration == generation { pairingMutating = false } }
        do {
            try await requireClient().revokePairingCode()
            guard pairingGeneration == generation else { return }
            pairing = nil
        } catch {
            guard pairingGeneration == generation else { return }
            handle(error)
        }
    }

    func issueLoginOffer() async {
        banner = nil
        let generation = sessionGeneration
        let origin = sessionURL
        let access = token
        do {
            let host = LoginOfferHost.advertisedHost(pickerSelection: nil, pickerAvailable: false)
            let offer = try await requireClient().issueLoginOffer(advertisedHost: host)
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return }
            loginOffer = offer
        } catch {
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return }
            handle(error)
        }
    }

    func loadLoginOffer() async {
        let generation = sessionGeneration
        let origin = sessionURL
        let access = token
        do {
            let offer = try await requireClient().loginOffer()
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return }
            loginOffer = offer
        } catch {
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return }
            handle(error)
        }
    }

    func revokeLoginOffer() async {
        let generation = sessionGeneration
        let origin = sessionURL
        let access = token
        do {
            try await requireClient().revokeLoginOffer()
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return }
            loginOffer = nil
        } catch {
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return }
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

    func handleOpenURL(_ url: URL) async {
        await redeemLoginURI(url.absoluteString)
    }

    func redeemLoginURI(_ raw: String) async {
        banner = nil
        busy = true
        defer { busy = false }
        do {
            let payload = try LoginURI.parse(raw)
            let url = try DeviceURL.normalize(payload.deviceURL)
            var api = APIClient(baseURL: url, token: nil)
            let session = try await api.redeemLogin(code: payload.code)
            serverURLText = url.absoluteString
            persistSession(session, origin: url)
            try await refreshAll()
            phase = .ready
            startPolling()
        } catch APIError.setupRequired {
            phase = .setupRequired
        } catch APIError.unauthorized {
            banner = "Sign-in QR was invalid or expired"
        } catch {
            banner = error.localizedDescription
        }
    }

    private func persistSession(_ session: SessionTokens, origin: URL? = nil) {
        token = session.token
        refreshToken = session.refreshToken
        if let origin {
            sessionURL = origin
            serverURLText = origin.absoluteString
        } else if sessionURL == nil {
            sessionURL = try? DeviceURL.normalize(serverURLText)
        }
        if !KeychainStore.saveSession(token: session.token, refreshToken: session.refreshToken) {
            banner = "Could not save the session on this device"
        }
        UserDefaults.standard.set(serverURLText, forKey: "serverURL")
        UserDefaults.standard.set(username, forKey: "username")
    }

    private func bumpSessionGeneration() {
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func sessionStillCurrent(generation: Int, origin: URL?, access: String?) -> Bool {
        LoginOfferSession.stillCurrent(
            generation: generation,
            currentGeneration: sessionGeneration,
            origin: origin,
            currentOrigin: sessionURL,
            token: access,
            currentToken: token,
        )
    }

    private func clearSessionLocally() {
        token = nil
        refreshToken = nil
        KeychainStore.deleteSession()
    }

    private func refreshAccessToken() async -> SessionRefreshResult {
        if let refreshTask {
            return await refreshTask.value
        }
        let generation = sessionGeneration
        let presented = refreshToken
        let origin = sessionURL
        let task = Task<SessionRefreshResult, Never> { [weak self] in
            guard let self else { return .unavailable("Sign in required") }
            if let blocked = SessionRefreshResult.fromLocalMaterial(
                refreshToken: presented,
                origin: origin,
            ) {
                return blocked
            }
            guard let presented, let origin else {
                return .unauthorized
            }
            do {
                var api = APIClient(baseURL: origin, token: nil)
                let session = try await api.refreshSession(refreshToken: presented)
                guard self.sessionGeneration == generation,
                      self.refreshToken == presented,
                      self.sessionURL == origin
                else {
                    return .unavailable("Sign in required")
                }
                self.persistSession(session)
                return .rotated(session.token)
            } catch {
                return SessionRefreshResult.from(error: error)
            }
        }
        refreshTask = task
        let value = await task.value
        refreshTask = nil
        return value
    }

    private func refreshDevices() async throws {
        let client = try requireClient()
        let health: Result<HomeDeviceHealthReport, Error>
        do {
            health = try await .success(client.healthReport())
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
                list = try await .success(client.deviceList())
            } catch {
                list = .failure(error)
            }
            switch list {
            case let .success(body):
                _ = try HomeDeviceDirectory.resolution(
                    healthStatus: healthStatus,
                    listStatus: nil,
                    aboutSucceeded: true,
                )
                devices = body.devices.map(\.asSnapshot)
                totals = nil
            case let .failure(listError):
                let listStatus = HomeDeviceDirectory.httpStatus(from: listError)
                if listStatus != 404 { throw listError }
                let aboutSucceeded = await (try? client.about()) != nil
                _ = try HomeDeviceDirectory.resolution(
                    healthStatus: healthStatus,
                    listStatus: listStatus,
                    aboutSucceeded: aboutSucceeded,
                )
                devices = await [client.localOnlyDevice()]
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
        async let i = optional { try await client.images(on: libraryDevice) }
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
        catalogGeneration += 1
        workloads = []
        stats = nil
        images = []
        catalogRepos = []
        catalogImagesByRepo = [:]
        catalogLoaded = false
        catalogFetchFailed = false
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
        homeGeneration += 1
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
        WorkloadActionKey.id(hostID: (device ?? selectedDevice)?.hostId, workloadID: workload.id)
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
            await loadLoginOffer()
            await refreshAbout()
        case .devices:
            _ = try? await refreshDevices()
        case .library:
            await refreshLibrary()
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
                if JWT.needsRefresh(self.token) {
                    if await self.refreshAccessToken() == .unauthorized {
                        self.logout()
                        return
                    }
                }
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
        _ work: (APIClient, HomeDeviceHealthSnapshot?) async throws -> Void,
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

    private func refreshLibraryImages() async {
        guard let client else { return }
        if let next = await optional({ try await client.images(on: libraryDevice) }) {
            images = next
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
