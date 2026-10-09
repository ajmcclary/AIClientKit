import Foundation
import CryptoKit

public enum AIKeychainError: Error, LocalizedError, Equatable, Sendable {
	case itemNotFound, duplicateItem, invalidData, integrityCheckFailed
	case unexpectedStatus(Int32)
	public var errorDescription: String? {
		switch self {
		case .itemNotFound: return "Item not found in keychain"
		case .duplicateItem: return "Item already exists"
		case .invalidData: return "Invalid data format"
		case .integrityCheckFailed: return "Data integrity check failed - possible tampering detected"
		case .unexpectedStatus(let status): return "Keychain error: \(status)"
		}
	}
}
public protocol AISecureKeyValueBackend: AnyObject, Sendable {
	var persistsValuesAcrossLaunches: Bool { get }
	func save(_ value: String, for key: String, withIntegrityProtection: Bool) throws
	func get(for key: String, verifyIntegrity: Bool) throws -> String
	func getRawData(for key: String) throws -> Data
	func delete(for key: String) throws
}
public enum AIStorageBackendKind: Equatable, Sendable { case persistentKeychain, ephemeral }
public struct AIStorageSigningEvidence: Equatable, Sendable {
	public let teamIdentifier: String?, codeIdentifier: String?
	public let isAdHocSignature: Bool?
	public let appleTeamSignatureVerified: Bool
	public let detectionErrorDescription: String?
	public init(teamIdentifier: String?, codeIdentifier: String?, isAdHocSignature: Bool?, appleTeamSignatureVerified: Bool, detectionErrorDescription: String? = nil) {
		self.teamIdentifier = teamIdentifier; self.codeIdentifier = codeIdentifier; self.isAdHocSignature = isAdHocSignature
		self.appleTeamSignatureVerified = appleTeamSignatureVerified; self.detectionErrorDescription = detectionErrorDescription
	}
}
public enum AIStoragePersistencePolicy: Equatable, Sendable {
	case ephemeralOnly
	case verifiedAppleTeam
	case requiredAppleIdentity(teamIdentifier: String, codeIdentifier: String)
}
public enum AIStorageRuntimePolicy {
	public static func isValidAppleTeamIdentifier(_ value: String) -> Bool {
		let bytes = Array(value.utf8)
		return bytes.count == 10 && bytes.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
	}
	public static func backendKind(for evidence: AIStorageSigningEvidence, policy: AIStoragePersistencePolicy) -> AIStorageBackendKind {
		guard policy != .ephemeralOnly, evidence.detectionErrorDescription == nil,
		      let team = evidence.teamIdentifier, isValidAppleTeamIdentifier(team),
		      let code = evidence.codeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty,
		      evidence.isAdHocSignature == false, evidence.appleTeamSignatureVerified else { return .ephemeral }
		if case .requiredAppleIdentity(let expectedTeam, let expectedCode) = policy {
			guard team == expectedTeam, code == expectedCode else { return .ephemeral }
		}
		return .persistentKeychain
	}
	public static func select(for evidence: AIStorageSigningEvidence, policy: AIStoragePersistencePolicy,
	                          persistent: () -> any AISecureKeyValueBackend, ephemeral: () -> any AISecureKeyValueBackend) -> AIStorageBackendSelection {
		let kind = backendKind(for: evidence, policy: policy)
		return .init(kind: kind, backend: kind == .persistentKeychain ? persistent() : ephemeral())
	}
}
public struct AIStorageBackendSelection: Sendable {
	public let kind: AIStorageBackendKind
	public let backend: any AISecureKeyValueBackend
	public init(kind: AIStorageBackendKind, backend: any AISecureKeyValueBackend) { self.kind = kind; self.backend = backend }
}
public struct AIStorageNamespace: Equatable, Sendable {
	public let serviceName: String, accountPrefix: String, integrityInstallSecretAccount: String, integrityKeyDerivationSalt: String
	public init(serviceName: String, accountPrefix: String = "", integrityInstallSecretAccount: String, integrityKeyDerivationSalt: String) {
		self.serviceName = serviceName; self.accountPrefix = accountPrefix
		self.integrityInstallSecretAccount = integrityInstallSecretAccount; self.integrityKeyDerivationSalt = integrityKeyDerivationSalt
	}
	public static func application(identifier: String) -> Self {
		.init(serviceName: identifier+".keychain", integrityInstallSecretAccount: "ai_integrity_install_secret_v1", integrityKeyDerivationSalt: identifier+".AIStorage-v1")
	}
	public func account(for key: String) -> String { accountPrefix+key }
}
public struct AIStorageEnvironment: Sendable {
	public let randomBytes: @Sendable (Int) throws -> Data
	public let hardwareIdentifier: @Sendable () -> String?
	public let wallClock: @Sendable () -> Date
	public let continuousSeconds: @Sendable () -> Double
	public let uptime: @Sendable () -> Double
	public init(randomBytes: @escaping @Sendable (Int) throws -> Data, hardwareIdentifier: @escaping @Sendable () -> String?, wallClock: @escaping @Sendable () -> Date,
	            continuousSeconds: @escaping @Sendable () -> Double, uptime: @escaping @Sendable () -> Double) {
		self.randomBytes = randomBytes; self.hardwareIdentifier = hardwareIdentifier; self.wallClock = wallClock; self.continuousSeconds = continuousSeconds; self.uptime = uptime
	}
}
public enum AIIntegrityFallbackPolicy: Sendable { case requireInstallSecret, legacyDeviceOrSalt }

/// Legacy framing: 32-byte HMAC followed by UTF-8 bytes, without a version prefix.
public enum AIIntegrityEnvelope {
	public static func encode(_ value: String, key: SymmetricKey) throws -> Data {
		guard let payload = value.data(using: .utf8) else { throw AIKeychainError.invalidData }
		var data = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key)); data.append(payload); return data
	}
	public static func decode(_ data: Data, key: SymmetricKey) throws -> String {
		guard data.count > 32 else { throw AIKeychainError.invalidData }
		let payload = data.suffix(from: 32)
		guard data.prefix(32) == Data(HMAC<SHA256>.authenticationCode(for: payload, using: key)) else { throw AIKeychainError.integrityCheckFailed }
		guard let result = String(data: payload, encoding: .utf8) else { throw AIKeychainError.invalidData }; return result
	}
}
