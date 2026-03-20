import Foundation

/// Summary of the client's encryption, key backup, and recovery state.
public struct EncryptionStatus: Sendable {
    public let backupEnabled: Bool
    public let recoveryEnabled: Bool

    public init(backupEnabled: Bool = false, recoveryEnabled: Bool = false) {
        self.backupEnabled = backupEnabled
        self.recoveryEnabled = recoveryEnabled
    }
}
