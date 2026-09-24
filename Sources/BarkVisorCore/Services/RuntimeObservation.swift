import Foundation

public actor RuntimeObservation {
    private var observations: [String: WorkloadObservation] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var resyncTime: Date?
    private var identityProvider: @Sendable () -> DockerRuntimeIdentity
    private var listContainers: @Sendable () -> ContainerListCollect
    private var subscribedIdentity: DockerRuntimeIdentity?
    private var source: (any DockerEventProducing)?
    private var reconnect: Bool = true
    private var eventTask: Task<Void, Never>?
    private var eventGeneration: UInt64 = 0
    private var openings = 0

    public init(
        identityProvider: @escaping @Sendable () -> DockerRuntimeIdentity = {
            DockerRuntimeIdentity.detectFromEnvironment()
        },
        listContainers: @escaping @Sendable () -> ContainerListCollect = {
            DockerStats.listManagedResult()
        },
    ) {
        self.identityProvider = identityProvider
        self.listContainers = listContainers
    }

    public func observation(for workloadID: String) -> WorkloadObservation? {
        observations[workloadID]
    }

    public func currentObservations() -> [WorkloadObservation] {
        observations.values.sorted { $0.workloadID < $1.workloadID }
    }

    public func subscriptionOpenings() -> Int {
        openings
    }

    public func ensureEvents(source: any DockerEventProducing, reconnect: Bool = true) {
        if eventTask != nil { return }
        self.source = source
        self.reconnect = reconnect
        subscribedIdentity = identityProvider()
        beginEvents(source: source, reconnect: reconnect)
    }

    public func refreshIdentity() async {
        guard source != nil else { return }
        let identity = identityProvider()
        guard identity != subscribedIdentity else { return }
        await restartEvents()
    }

    public func stop() async {
        eventGeneration += 1
        eventTask?.cancel()
        await eventTask?.value
        eventTask = nil
        source = nil
    }

    public func connectPublic(capacity: Int) -> UUID {
        let id = UUID()
        var subscriber = Subscriber(capacity: max(capacity, 1))
        let current = currentObservations()
        if current.count > subscriber.capacity {
            subscriber.notices = [.resync]
            subscriber.resync = true
        } else {
            subscriber.notices = current.map { .observation($0) }
        }
        subscribers[id] = subscriber
        return id
    }

    public func reconnectPublic(id: UUID, capacity: Int) {
        guard subscribers[id] != nil else { return }
        subscribers[id] = nil
        var subscriber = Subscriber(capacity: max(capacity, 1))
        let current = currentObservations()
        if current.count > subscriber.capacity {
            subscriber.notices = [.resync]
            subscriber.resync = true
        } else {
            subscriber.notices = current.map { .observation($0) }
        }
        subscribers[id] = subscriber
    }

    public func notices(for id: UUID) -> [ObservationNotice] {
        subscribers[id]?.notices ?? []
    }

    public func bufferedCount(for id: UUID) -> Int {
        subscribers[id]?.notices.count ?? 0
    }

    public func ingest(line: String) {
        guard let event = DockerEventDecoding.parse(line: line) else { return }
        apply(event)
    }

    public func ingest(delivery: DockerEventDelivery) async {
        switch delivery {
        case let .line(line):
            ingest(line: line)
        case .gap:
            await resyncFromRuntime(force: true)
        }
    }

    public func noteConfiguration(workloadID: String, generation: UInt64, at: Date = Date()) {
        var observation = observations[workloadID] ?? .empty(workloadID)
        guard generation > observation.configurationGeneration else { return }
        observation.configurationGeneration = generation
        observation.observationSequence += 1
        observation.observedAt = at
        store(observation)
    }

    public func apply(_ event: DockerContainerEvent) {
        if let resyncTime, event.time <= resyncTime { return }
        var observation = observations[event.workloadID] ?? .empty(event.workloadID)
        upsertService(&observation, event: event)
        observation.freshness = .fresh
        observation.observationSequence += 1
        observation.observedAt = event.time
        observation.detail = nil
        store(observation)
    }

    public func applyQMP(workloadID: String, event: QMPObservationKind, at: Date = Date()) {
        var observation = observations[workloadID] ?? .empty(workloadID)
        switch event {
        case .shutdown:
            observation.phase = .exited
            observation.detail = nil
        case .guestPanicked:
            observation.health = .unhealthy
            observation.detail = "kernel panic"
        case .reset:
            observation.phase = .restarting
            observation.detail = nil
        }
        observation.freshness = .fresh
        observation.observationSequence += 1
        observation.observedAt = at
        store(observation)
    }

    public func applySnapshot(_ rows: [ContainerSnapshot], at: Date = Date(), force: Bool = false) {
        resyncTime = at
        var grouped: [String: [ContainerSnapshot]] = [:]
        for row in rows {
            grouped[row.workloadID, default: []].append(row)
        }
        let dockerIDs = observations.compactMap { id, observation in
            observation.services.isEmpty ? nil : id
        }
        let ids = Set(dockerIDs).union(grouped.keys)
        for id in ids {
            var observation = observations[id] ?? .empty(id)
            let services = (grouped[id] ?? []).map { row in
                ServiceObservation(
                    service: row.service,
                    containerID: row.containerID,
                    phase: ObservationRollup.phase(state: row.state, status: row.status),
                    health: ObservationRollup.health(status: row.status),
                )
            }
            let phase = services.isEmpty ? WorkloadRuntimePhase.exited : ObservationRollup.workloadPhase(services)
            let health = services.isEmpty ? WorkloadHealthFact.unknown : ObservationRollup.workloadHealth(services)
            let changed = observation.services != services
                || observation.phase != phase
                || observation.health != health
                || observation.freshness != .fresh
            observation.services = services
            observation.phase = phase
            observation.health = health
            observation.freshness = .fresh
            observation.detail = nil
            if changed || force {
                observation.observationSequence += 1
                observation.observedAt = at
                store(observation)
            } else {
                observations[id] = observation
            }
        }
    }

    public func applyReconcile(_ facts: [ReconcileFact], at: Date = Date()) {
        for fact in facts {
            var observation = observations[fact.workloadID] ?? .empty(fact.workloadID)
            let changed = observation.phase != fact.phase
                || observation.detail != fact.detail
                || observation.freshness != .fresh
            observation.phase = fact.phase
            observation.detail = fact.detail
            observation.freshness = .fresh
            if changed {
                observation.observationSequence += 1
                observation.observedAt = at
                store(observation)
            } else {
                observations[fact.workloadID] = observation
            }
        }
    }

    public func noteEventStreamEnded(at: Date = Date()) {
        for id in observations.keys {
            guard var observation = observations[id] else { continue }
            if observation.freshness == .unknown { continue }
            observation.freshness = .stale
            observation.observedAt = at
            observation.observationSequence += 1
            store(observation)
        }
    }

    public func noteMissedHistory(snapshot: [ContainerSnapshot], at: Date = Date()) {
        noteEventStreamEnded(at: at)
        applySnapshot(snapshot, at: at, force: true)
    }

    public func noteProbeFailure(
        detail: String,
        workloadIDs: Set<String>? = nil,
        at: Date = Date(),
    ) {
        let ids = workloadIDs ?? Set(observations.keys)
        for id in ids {
            var observation = observations[id] ?? .empty(id)
            observation.freshness = observation.observedAt == nil ? .unknown : .stale
            observation.detail = detail
            observation.observedAt = observation.observedAt ?? at
            store(observation)
        }
    }

    public func recordStats(
        _ collect: ManagedStatsCollect,
        workloadIDs: Set<String>,
        at: Date = Date(),
    ) {
        switch collect {
        case .failed:
            noteProbeFailure(detail: "docker stats failed", workloadIDs: workloadIDs, at: at)
        case let .fresh(totals):
            for id in workloadIDs {
                var observation = observations[id] ?? .empty(id)
                if let total = totals[id] {
                    observation.cpuPercent = total.cpuPercent
                    observation.memoryUsedBytes = total.memoryUsedBytes
                } else {
                    observation.cpuPercent = nil
                    observation.memoryUsedBytes = nil
                }
                observation.observedAt = at
                store(observation)
            }
        }
    }

    public func resyncFromRuntime(force: Bool = true) async {
        let list = listContainers
        let collected = await Task.detached(operation: { list() }).value
        switch collected {
        case let .fresh(rows):
            applySnapshot(rows, force: force)
        case .failed:
            noteProbeFailure(detail: "container list failed")
        }
    }

    private func beginEvents(source: any DockerEventProducing, reconnect: Bool) {
        eventGeneration += 1
        let generation = eventGeneration
        eventTask = Task { [weak self] in
            await self?.runEvents(generation: generation, source: source, reconnect: reconnect)
        }
    }

    private func restartEvents() async {
        guard let source else { return }
        eventGeneration += 1
        eventTask?.cancel()
        await eventTask?.value
        eventTask = nil
        beginEvents(source: source, reconnect: reconnect)
    }

    private func runEvents(
        generation: UInt64,
        source: any DockerEventProducing,
        reconnect: Bool,
    ) async {
        var delay: UInt64 = 1_000_000_000
        while eventGeneration == generation, !Task.isCancelled {
            let identity = identityProvider()
            subscribedIdentity = identity
            openings += 1
            let subscription = source.open(identity: identity)
            let cancel = subscription.cancel
            await withTaskCancellationHandler {
                for await delivery in subscription.stream {
                    if eventGeneration != generation || Task.isCancelled { break }
                    await ingest(delivery: delivery)
                }
            } onCancel: {
                cancel()
            }
            if eventGeneration != generation || Task.isCancelled || !reconnect { break }
            noteEventStreamEnded()
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay &* 2, 30_000_000_000)
            if eventGeneration != generation || Task.isCancelled { break }
            await resyncFromRuntime(force: true)
        }
        if eventGeneration == generation {
            eventTask = nil
        }
    }

    private func upsertService(_ observation: inout WorkloadObservation, event: DockerContainerEvent) {
        let phase = ObservationRollup.phase(action: event.action)
        let health = ObservationRollup.health(action: event.action)
        if phase == nil, health == nil { return }
        if let index = observation.services.firstIndex(where: { $0.containerID == event.containerID }) {
            var service = observation.services[index]
            if let phase { service.phase = phase }
            if let health { service.health = health }
            service.service = event.service
            observation.services[index] = service
        } else {
            observation.services.append(
                ServiceObservation(
                    service: event.service,
                    containerID: event.containerID,
                    phase: phase ?? .unknown,
                    health: health ?? .unknown,
                ),
            )
        }
        observation.phase = ObservationRollup.workloadPhase(observation.services)
        observation.health = ObservationRollup.workloadHealth(observation.services)
    }

    private func store(_ observation: WorkloadObservation) {
        observations[observation.workloadID] = observation
        enqueue(.observation(observation))
    }

    private func enqueue(_ notice: ObservationNotice) {
        for id in subscribers.keys {
            guard var subscriber = subscribers[id] else { continue }
            if subscriber.resync || subscriber.notices.count >= subscriber.capacity {
                subscriber.notices = [.resync]
                subscriber.resync = true
            } else {
                subscriber.notices.append(notice)
            }
            subscribers[id] = subscriber
        }
    }
}

private struct Subscriber {
    var capacity: Int
    var notices: [ObservationNotice] = []
    var resync = false
}
