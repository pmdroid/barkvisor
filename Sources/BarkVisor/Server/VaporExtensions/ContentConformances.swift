import BarkVisorCore
import Vapor

// MARK: - Vapor Content conformances for BarkVisorCore types

// These types are Codable in BarkVisorCore but need Content conformance for Vapor routes.

extension Disk: Content {}
extension Network: Content {}
extension SSHKey: Content {}
extension MetricSample: Content {}
extension APIKeyResponse: Content {}
extension APIKeyCreateResponse: Content {}
extension BackupInfo: Content {}
extension BackupSettings: Content {}
extension VM: Content {}
extension VMImage: Content {}
extension VMTemplate: Content {}
extension User: Content {}
extension AuditEntry: Content {}
extension GuestInfoRecord: Content {}
extension ImageRepository: Content {}
extension RepositoryImage: Content {}
extension PortForwardRule: Content {}
extension TusUpload: Content {}
extension AppSetting: Content {}
extension BridgeRecord: Content {}
extension LogEntry: Content {}
extension ImageProgressEvent: Content {}
extension DiskImageInfo: Content {}
