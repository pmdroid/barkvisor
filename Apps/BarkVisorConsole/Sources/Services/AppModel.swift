import Foundation
import Observation

enum AppRoute: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case devices
    case workloads
    case models
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
        case .models: "Ollama"
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

enum PhoneTab: String, Hashable, CaseIterable {
    case home
    case library
    case models
    case devices
    case settings

    static let storageKey = "phoneTab"

    static func restored(_ raw: String?) -> PhoneTab {
        if raw == "chat" { return .home }
        return PhoneTab(rawValue: raw ?? "") ?? .home
    }

    init?(route: AppRoute) {
        switch route {
        case .dashboard: self = .home
        case .library: self = .library
        case .models: self = .models
        case .devices: self = .devices
        case .settings: self = .settings
        default: return nil
        }
    }

    var appRoute: AppRoute {
        switch self {
        case .home: .dashboard
        case .library: .library
        case .models: .models
        case .devices: .devices
        case .settings: .settings
        }
    }
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
    var capabilities: SystemCapabilities?
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
    var ollamaCatalog: OllamaHomeCatalog?
    var ollamaLoaded = false
    var ollamaRefreshing = false
    var ollamaSettings: OllamaSettingsSnapshot?
    var remoteAccess: RemoteAccessStatus?
    var diskSettings: DiskSettingsSnapshot?
    var updateCheck: UpdateCheckResponse?
    var updateBusy = false
    var updatePhase = ""

    var showsChat: Bool {
        ChatAvailability.visible(catalog: ollamaCatalog)
    }

    private var token: String?
    private var refreshToken: String?
    /// Origin the JWT was issued for. Polling must never follow a draft URL edit.
    private var sessionURL: URL?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<SessionRefreshResult, Never>?
    private var sessionGeneration = 0
    private var scopedGeneration = 0
    private var catalogGeneration = 0
    private var libraryImagesGeneration = 0
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
        phoneTab = PhoneTab.restored(UserDefaults.standard.string(forKey: PhoneTab.storageKey))
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

    func signInWithPasskey() async {
        #if os(iOS) || os(macOS)
            banner = nil
            let url: URL
            do {
                url = try DeviceURL.normalize(serverURLText)
            } catch {
                banner = error.localizedDescription
                return
            }
            if let block = PasskeySupport.passkeyBlock(for: url) {
                banner = block.message
                return
            }
            busy = true
            defer { busy = false }
            do {
                serverURLText = url.absoluteString
                var api = APIClient(baseURL: url, token: nil)
                let begin = try await api.beginPasskeyLogin()
                let credential = try await PasskeyAuth.performLogin(publicKey: begin.publicKey.value)
                let session = try await api.finishPasskeyLogin(sessionId: begin.sessionId, credential: credential)
                persistSession(session, origin: url)
                password = ""
                try await refreshAll()
                phase = .ready
                startPolling()
            } catch APIError.setupRequired {
                phase = .setupRequired
            } catch {
                banner = error.localizedDescription
            }
        #endif
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
        capabilities = nil
        logs = []
        ollamaCatalog = nil
        ollamaSettings = nil
        remoteAccess = nil
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
        capabilities = nil
        logs = []
        ollamaCatalog = nil
        ollamaSettings = nil
        remoteAccess = nil
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
        if let tab = PhoneTab(route: next) {
            persistPhoneTab(tab)
        }
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

    func refreshOllama() async {
        guard !ollamaRefreshing else { return }
        ollamaRefreshing = true
        ollamaLoaded = false
        defer { ollamaRefreshing = false }
        do {
            ollamaCatalog = try await requireClient().ollamaCatalog()
            ollamaLoaded = true
            await refreshOllamaSettings()
            await loadRemoteAccess()
        } catch {
            ollamaLoaded = true
            handle(error)
        }
    }

    func loadRemoteAccess() async {
        let generation = sessionGeneration
        let origin = sessionURL
        let access = token
        do {
            let status = try await requireClient().remoteAccess()
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return }
            remoteAccess = status
        } catch {
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return }
            handle(error)
        }
    }

    @discardableResult
    func saveRemoteAccess(_ body: RemoteAccessUpdate) async -> Bool {
        let generation = sessionGeneration
        let origin = sessionURL
        let access = token
        do {
            let status = try await requireClient().saveRemoteAccess(body)
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return false }
            remoteAccess = status
            return true
        } catch {
            guard sessionStillCurrent(generation: generation, origin: origin, access: access) else { return false }
            handle(error)
            return false
        }
    }

    func refreshOllamaSettings() async {
        do {
            ollamaSettings = try await requireClient().ollamaSettings()
        } catch let APIError.http(status, _) where status == 403 {
            ollamaSettings = nil
        } catch {
            ollamaSettings = nil
            handle(error)
        }
    }

    func refreshDiskSettings() async {
        do {
            diskSettings = try await requireClient().diskSettings()
        } catch {
            diskSettings = nil
            handle(error)
        }
    }

    @discardableResult
    func refreshUpdates() async {
        do {
            updateCheck = try await requireClient().checkUpdates()
        } catch {
            updateCheck = nil
            banner = error.localizedDescription
        }
    }

    func applyUpdate(_ version: String) async -> Bool {
        updateBusy = true
        updatePhase = "Installing v\(version)…"
        defer { updateBusy = false }
        do {
            let accepted = try await requireClient().installUpdate(version: version)
            var consecutiveMisses = 0
            var startHealthPoll = false
            for _ in 0 ..< 60 {
                try? await Task.sleep(for: .seconds(2))
                do {
                    let task = try await requireClient().taskStatus(taskID: accepted.taskID)
                    consecutiveMisses = 0
                    if task.status == "failed" {
                        banner = task.error ?? "Update failed"
                        updatePhase = ""
                        return false
                    }
                    if task.status == "completed" {
                        startHealthPoll = true
                        break
                    }
                } catch {
                    consecutiveMisses += 1
                    if consecutiveMisses >= ApplianceUpdateApply.consecutiveTaskMissesBeforeHealthPoll {
                        startHealthPoll = true
                        break
                    }
                }
            }
            guard startHealthPoll else {
                banner = "Timed out waiting for the update to finish."
                updatePhase = ""
                return false
            }
            return await pollHealthAfterUpdate()
        } catch {
            if ApplianceUpdateApply.isConnectionLoss(error) {
                return await pollHealthAfterUpdate()
            }
            banner = error.localizedDescription
            updatePhase = ""
            return false
        }
    }

    /// SPA waits for task completion or connection loss before /api/health.
    /// The daemon keeps serving health during download/dpkg/pkg, so health==ok is not "done".
    private func pollHealthAfterUpdate() async -> Bool {
        updatePhase = "Waiting for this Device…"
        for _ in 0 ..< 60 {
            try? await Task.sleep(for: .seconds(2))
            if let health = try? await requireClient().processHealth(), health.status == "ok" {
                await refreshUpdates()
                updatePhase = ""
                return true
            }
        }
        banner = "Timed out waiting for /api/health after the update."
        updatePhase = ""
        return false
    }

    @discardableResult
    func saveDeviceName(_ displayName: String, on device: HomeDeviceHealthSnapshot) async -> Bool {
        do {
            _ = try await requireClient().saveDeviceName(displayName, on: device)
            await refreshHome()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    @discardableResult
    func saveDiskSettings(_ directory: String) async -> Bool {
        do {
            diskSettings = try await requireClient().saveDiskSettings(
                DiskSettingsUpdate(diskDirectory: directory),
            )
            return true
        } catch {
            handle(error)
            return false
        }
    }

    @discardableResult
    func saveOllamaSettings(_ body: OllamaSettingsUpdate) async -> Bool {
        do {
            ollamaSettings = try await requireClient().saveOllamaSettings(body)
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func startOllama(_ name: String, hostId: String?) async {
        let key = "ollama/\(name)"
        actionIDs.insert(key)
        defer { actionIDs.remove(key) }
        do {
            try await requireClient().startOllama(name, hostId: hostId)
            await refreshOllama()
        } catch {
            handle(error)
        }
    }

    func stopOllama(_ name: String, hostId: String?) async {
        let key = "ollama/\(name)"
        actionIDs.insert(key)
        defer { actionIDs.remove(key) }
        do {
            try await requireClient().stopOllama(name, hostId: hostId)
            await refreshOllama()
        } catch {
            handle(error)
        }
    }

    func pullOllama(_ name: String, hostId: String?) async throws -> OllamaTaskAccepted {
        try await requireClient().pullOllama(name: name, hostId: hostId)
    }

    func searchOllamaLibrary(_ q: String) async throws -> OllamaLibrarySearchResponse {
        try await requireClient().ollamaLibrarySearch(q: q)
    }

    func ollamaTask(_ task: OllamaTaskAccepted) async throws -> OllamaTaskEvent {
        try await requireClient().ollamaTask(task, selfHostId: devices.first(where: \.isSelf)?.hostId)
    }

    func cancelOllamaPull(_ task: OllamaTaskAccepted) async throws {
        try await requireClient().cancelOllamaTask(task, selfHostId: devices.first(where: \.isSelf)?.hostId)
    }

    func present(_ error: Error) {
        handle(error)
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

    /// Save guest addressing (DHCP or static IPv4) on a bridged cloud-init Workload.
    @discardableResult
    func setGuestAddressing(
        _ workload: Workload,
        addressing: GuestAddressingInfo,
        on device: HomeDeviceHealthSnapshot,
    ) async -> Bool {
        let key = actionID(for: workload, explicit: device)
        actionIDs.insert(key)
        defer { actionIDs.remove(key) }
        do {
            try await requireClient().setGuestAddressing(workload.id, addressing: addressing, on: device)
            await refreshDeviceScoped()
            await refreshHomeUnion()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func resumeSession(_ workload: Workload, on device: HomeDeviceHealthSnapshot? = nil) async {
        let target = device ?? selectedDevice
        await mutate(actionID(for: workload, explicit: device), on: target) { client, resolved in
            _ = try await client.resumeSession(workload.id, on: resolved)
        }
    }

    func resetSession(_ workload: Workload, on device: HomeDeviceHealthSnapshot? = nil) async {
        let target = device ?? selectedDevice
        await mutate(actionID(for: workload, explicit: device), on: target) { client, resolved in
            _ = try await client.resetSession(workload.id, on: resolved)
        }
    }

    func burnSession(_ workload: Workload, on device: HomeDeviceHealthSnapshot? = nil) async {
        let target = device ?? selectedDevice
        await mutate(actionID(for: workload, explicit: device), on: target) { client, resolved in
            try await client.burnSession(workload.id, on: resolved)
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

    func gpuDevices(on device: HomeDeviceHealthSnapshot) async -> [HostGPUDevice] {
        guard device.isReachable else { return [] }
        do {
            return try await requireClient().gpuDevices(on: device)
        } catch {
            handle(error)
            return []
        }
    }

    func usbDevices(on device: HomeDeviceHealthSnapshot) async -> [HostUSBDevice] {
        guard device.isReachable else { return [] }
        do {
            return try await requireClient().usbDevices(on: device)
        } catch {
            handle(error)
            return []
        }
    }

    func statsHistory(on device: HomeDeviceHealthSnapshot) async -> [SystemStatsSample] {
        guard DeviceStatsHistory.shouldFetch(device) else { return [] }
        do {
            return try await requireClient().statsHistory(on: device)
        } catch {
            handle(error)
            return []
        }
    }

    func attachGPU(_ pciAddress: String, to workload: Workload, on device: HomeDeviceHealthSnapshot) async {
        await mutate(actionID(for: workload, explicit: device), on: device) { client, resolved in
            _ = try await client.attachGPU(workload.id, pciAddress: pciAddress, on: resolved)
        }
    }

    func detachGPU(_ pciAddress: String, from workload: Workload, on device: HomeDeviceHealthSnapshot) async {
        await mutate(actionID(for: workload, explicit: device), on: device) { client, resolved in
            _ = try await client.detachGPU(workload.id, pciAddress: pciAddress, on: resolved)
        }
    }

    func attachUSB(_ deviceId: String, to workload: Workload, on device: HomeDeviceHealthSnapshot) async {
        await mutate(actionID(for: workload, explicit: device), on: device) { client, resolved in
            _ = try await client.attachUSB(workload.id, deviceId: deviceId, on: resolved)
        }
    }

    func detachUSB(_ deviceId: String, from workload: Workload, on device: HomeDeviceHealthSnapshot) async {
        await mutate(actionID(for: workload, explicit: device), on: device) { client, resolved in
            _ = try await client.detachUSB(workload.id, deviceId: deviceId, on: resolved)
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

    /// Networks on any reachable Device (Create Workload bridged picker).
    func networkList(on device: HomeDeviceHealthSnapshot) async -> [NetworkRecord]? {
        guard device.isReachable else { return nil }
        do {
            return try await requireClient().networks(on: device)
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
        openaiAPIKey: String? = nil,
        network: NetworkRecord? = nil,
        addressing: GuestAddressingDraft? = nil,
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
                openaiAPIKey: openaiAPIKey,
                network: network,
                addressing: addressing,
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

    func templateList(on device: HomeDeviceHealthSnapshot?) async -> [VMTemplateRecord]? {
        guard device?.isReachable != false else { return nil }
        do {
            return try await requireClient().templates(on: device)
        } catch {
            handle(error)
            return nil
        }
    }

    func sshKeyList() async -> [SSHKeyRecord]? {
        do {
            return try await requireClient().sshKeys()
        } catch {
            handle(error)
            return nil
        }
    }

    func diskList(on device: HomeDeviceHealthSnapshot) async -> [DiskRecord]? {
        guard device.isReachable else { return nil }
        do {
            return try await requireClient().disks(on: device)
        } catch {
            handle(error)
            return nil
        }
    }

    func createFromWizard(
        kind: CreateVMWizard.GalleryKind,
        name: String,
        device: HomeDeviceHealthSnapshot,
        template: VMTemplateRecord?,
        templateInputs: [String: String],
        image: LibraryImage?,
        sshKey: SSHKeyRecord?,
        preset: CreateVMWizard.SizePreset,
        network: NetworkRecord?,
        addressing: GuestAddressingDraft,
        diskSource: CreateVMWizard.DiskSource,
        diskSizeGB: Int,
        existingDiskID: String,
        workloadClass: String,
        openaiBaseURL: String?,
        openaiAPIKey: String?,
    ) async -> Workload? {
        let key = "create/\(device.hostId)"
        actionIDs.insert(key)
        defer { actionIDs.remove(key) }
        do {
            let client = try requireClient()
            if kind == .template, let template {
                let deviceTemplates = try await client.templates(on: device)
                let resolved = CreateVMWizard.resolveTemplate(template, on: deviceTemplates)
                let merged = CreateVMWizard.mergeTemplateCatalog(picked: template, resolved: resolved)
                let about = try? await client.about(on: device)
                let hostArch = device.platform?.arch ?? about?.hostArch ?? merged.architectures?.first
                let recipe = CreateVMWizard.buildDeployRecipe(template: merged, hostArch: hostArch)
                let onDevice = deviceTemplates.contains { $0.slug == template.slug }
                if recipe == nil, !onDevice {
                    banner =
                        "\(template.name) is not on this \(Copy.device.lowercased()). Sync templates in the web UI on that host, or pick This \(Copy.device)."
                    return nil
                }
                let body = DeployTemplateBody(
                    templateId: merged.id,
                    vmName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    inputs: CreateVMWizard.deployInputs(template: merged, values: templateInputs, sshKey: sshKey),
                    cpuCount: preset.cpu,
                    memoryMB: preset.memoryMB,
                    diskSizeGB: diskSource == .new ? diskSizeGB : nil,
                    networkId: network?.id,
                    recipe: recipe,
                )
                let created = try await client.deployTemplate(body, on: device)
                await refreshDeviceScoped()
                await refreshHomeUnion()
                return created
            }
            guard let image else { return nil }
            let body = try CreateWorkload.wizardBody(
                name: name,
                image: image,
                hostCPUCount: device.resources?.cpuCount,
                preset: preset,
                diskSource: diskSource,
                diskSizeGB: diskSizeGB,
                existingDiskID: existingDiskID,
                workloadClass: workloadClass,
                openaiBaseURL: openaiBaseURL,
                openaiAPIKey: openaiAPIKey,
                network: network,
                addressing: addressing,
                sshPublicKey: sshKey?.publicKey,
            )
            let created = try await client.createWorkload(body, on: device)
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
        let imagesGeneration = beginLibraryImagesFetch()
        let device = libraryDevice
        async let imagesLoad = optional { try await client.images(on: device) }
        async let reposLoad = optional { try await client.repositories(on: device) }
        let nextImages = await imagesLoad
        let nextRepos = await reposLoad
        guard generation == catalogGeneration else { return }
        applyLibraryImages(nextImages, generation: imagesGeneration)
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

    func persistPhoneTab(_ tab: PhoneTab) {
        phoneTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: PhoneTab.storageKey)
    }

    func openPhoneTab(_ tab: PhoneTab) async {
        persistPhoneTab(tab)
        route = tab.appRoute
        switch tab {
        case .home:
            await refreshHome()
        case .library:
            await refreshLibrary()
        case .models:
            await refreshOllama()
        case .devices:
            await refreshPhoneDevices()
        case .settings:
            await loadRemoteAccess()
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
        async let capsLoad: Void = refreshCapabilities()
        async let home: Void = refreshHomeUnion()
        async let ollama: Void = refreshOllamaCatalog()
        _ = await (scoped, aboutLoad, capsLoad, home, ollama)
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
        let imagesGeneration = beginLibraryImagesFetch()
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
        applyLibraryImages(nextImages, generation: imagesGeneration)
        if let nextDisks { disks = nextDisks }
        if let nextNetworks { networks = nextNetworks }
    }

    private func dropScopedState() {
        scopedGeneration += 1
        catalogGeneration += 1
        libraryImagesGeneration += 1
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
        ollamaCatalog = nil
        ollamaSettings = nil
        ollamaRefreshing = false
        remoteAccess = nil
    }

    func refreshOllamaCatalog() async {
        guard !ollamaRefreshing else { return }
        ollamaRefreshing = true
        defer { ollamaRefreshing = false }
        guard let client else { return }
        if let catalog = await optional({ try await client.ollamaCatalog() }) {
            ollamaCatalog = catalog
        } else {
            ollamaCatalog = nil
        }
        await refreshOllamaSettings()
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

    private func refreshCapabilities() async {
        capabilities = await optional { try await requireClient().capabilities() } ?? capabilities
    }

    func capabilities(for device: HomeDeviceHealthSnapshot) async -> SystemCapabilities? {
        guard DeviceStatsHistory.shouldFetch(device) else { return nil }
        return await optional { try await requireClient().capabilities(on: device) }
    }

    func about(on device: HomeDeviceHealthSnapshot) async -> SystemAbout? {
        guard DeviceStatsHistory.shouldFetch(device) else { return nil }
        return await optional { try await requireClient().about(on: device) }
    }

    private func refreshRoute() async {
        guard let client else { return }
        switch route {
        case .logs:
            logs = await optional { try await client.logs() } ?? logs
        case .settings:
            await loadPairing()
            await loadLoginOffer()
            await loadRemoteAccess()
        case .devices:
            _ = try? await refreshDevices()
        case .library:
            await refreshLibrary()
        case .models:
            await refreshOllama()
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
                    await self.refreshOllamaCatalog()
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

    func refreshLibraryImages() async {
        guard let client else { return }
        let generation = beginLibraryImagesFetch()
        let device = libraryDevice
        let next = await optional { try await client.images(on: device) }
        applyLibraryImages(next, generation: generation)
    }

    private func beginLibraryImagesFetch() -> Int {
        libraryImagesGeneration += 1
        return libraryImagesGeneration
    }

    private func applyLibraryImages(_ next: [LibraryImage]?, generation: Int) {
        guard LibraryImagesFetch.shouldApply(request: generation, current: libraryImagesGeneration) else {
            return
        }
        if let next { images = next }
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
