public enum WorkloadCreationPhase: String, Codable, Sendable, CaseIterable {
    case initiating
    case downloading
    case decompressing
    case provisioning
    case created
    case failed
}

public struct WorkloadCreationProgress: Codable, Sendable, Equatable {
    public var phase: WorkloadCreationPhase
    public var percent: Int?

    public init(phase: WorkloadCreationPhase, percent: Int? = nil) {
        self.phase = phase
        self.percent = percent
    }
}

public enum WorkloadCreationProgressProjector {
    public static func project(
        vmState: String,
        overlay: PendingVMImageOverlay? = nil,
        lastProgress: ImageProgressEvent? = nil,
        provisionTaskStatus: BackgroundTaskManager.TaskStatus? = nil,
        imageStatus: String? = nil,
    ) -> WorkloadCreationProgress {
        let transferStatus = lastProgress?.status ?? imageStatus ?? overlay?.imageStatus
        if isFailed(
            vmState: vmState,
            lastProgress: lastProgress,
            provisionTaskStatus: provisionTaskStatus,
            transferStatus: transferStatus,
        ) {
            return WorkloadCreationProgress(phase: .failed)
        }

        if overlay != nil {
            switch transferStatus {
            case "decompressing":
                return WorkloadCreationProgress(phase: .decompressing)
            case "ready":
                break
            case "downloading", "uploading":
                return WorkloadCreationProgress(
                    phase: .downloading,
                    percent: overlay?.downloadPercent ?? lastProgress?.percent,
                )
            default:
                if let percent = overlay?.downloadPercent ?? lastProgress?.percent {
                    return WorkloadCreationProgress(phase: .downloading, percent: percent)
                }
                return WorkloadCreationProgress(phase: .initiating)
            }
        }

        switch provisionTaskStatus {
        case .queued, .running:
            return WorkloadCreationProgress(phase: .provisioning)
        case .completed:
            if vmState == "provisioning" {
                return WorkloadCreationProgress(phase: .provisioning)
            }
        case .failed, .cancelled:
            return WorkloadCreationProgress(phase: .failed)
        case nil:
            break
        }

        if vmState == "provisioning" {
            if overlay != nil {
                return WorkloadCreationProgress(phase: .provisioning)
            }
            return WorkloadCreationProgress(phase: .initiating)
        }

        return WorkloadCreationProgress(phase: .created)
    }

    public static func provisionTaskIDs(vmID: String) -> [String] {
        ["disk-clone:\(vmID)", TemplateDeployService.deployTaskID(vmID: vmID)]
    }

    private static func isFailed(
        vmState: String,
        lastProgress: ImageProgressEvent?,
        provisionTaskStatus: BackgroundTaskManager.TaskStatus?,
        transferStatus: String?,
    ) -> Bool {
        if vmState == "error" { return true }
        if transferStatus == "error" { return true }
        if lastProgress?.status == "error" { return true }
        if provisionTaskStatus == .failed || provisionTaskStatus == .cancelled { return true }
        return false
    }
}
