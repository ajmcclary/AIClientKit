import Foundation
import CryptoKit

public final class AIKeychainStore: AISecureKeyValueBackend, Sendable {
	public typealias KeychainError = AIKeychainError
	public let persistsValuesAcrossLaunches = true
	private let namespace: AIStorageNamespace
	private let access: any AIKeychainAccess
	private let environment: AIStorageEnvironment
	private let fallback: AIIntegrityFallbackPolicy
	private let clockRollbackToleranceSeconds: Double
	public init(namespace: AIStorageNamespace, access: any AIKeychainAccess, environment: AIStorageEnvironment,
	            integrityFallback: AIIntegrityFallbackPolicy = .requireInstallSecret, clockRollbackToleranceSeconds: Double = 600) {
		self.namespace = namespace; self.access = access; self.environment = environment; self.fallback = integrityFallback; self.clockRollbackToleranceSeconds = clockRollbackToleranceSeconds
	}
	public func save(_ value: String, for key: String, withIntegrityProtection: Bool = true) throws {
		let data = withIntegrityProtection ? try AIIntegrityEnvelope.encode(value, key: integrityKey()) : Data(value.utf8)
		try? delete(for: key)
		try access.add(service: namespace.serviceName, account: namespace.account(for: key), data: data, accessibility: .afterFirstUnlock, synchronizable: false)
	}
	public func get(for key: String, verifyIntegrity: Bool = true) throws -> String {
		let data = try getRawData(for: key)
		if verifyIntegrity { return try AIIntegrityEnvelope.decode(data, key: integrityKey()) }
		guard let value = String(data: data, encoding: .utf8) else { throw AIKeychainError.invalidData }; return value
	}
	public func getRawData(for key: String) throws -> Data {
		guard let data = try access.read(service: namespace.serviceName, account: namespace.account(for: key)) else { throw AIKeychainError.itemNotFound }; return data
	}
	public func delete(for key: String) throws { try access.remove(service: namespace.serviceName, account: namespace.account(for: key)) }
	private func installSecret() throws -> Data {
		let account = namespace.account(for: namespace.integrityInstallSecretAccount)
		if let value = try access.read(service: namespace.serviceName, account: account) {
			guard !value.isEmpty else { throw AIKeychainError.invalidData }; return value
		}
		let bytes = try environment.randomBytes(32)
		guard !bytes.isEmpty else { throw AIKeychainError.invalidData }
		do {
			// Add is atomic. Never delete a concurrently-created installation secret.
			try access.add(service: namespace.serviceName, account: account, data: bytes, accessibility: .afterFirstUnlockDeviceOnly, synchronizable: false)
			return bytes
		} catch {
			if let existing = try? access.read(service: namespace.serviceName, account: account), !existing.isEmpty { return existing }
			throw error
		}
	}
	private func integrityKey() throws -> SymmetricKey {
		let secret: Data?
		if fallback == .requireInstallSecret { secret = try installSecret() } else { secret = try? installSecret() }
		let hardware = environment.hardwareIdentifier(), salt = namespace.integrityKeyDerivationSalt
		var material = Data()
		if let secret, !secret.isEmpty { material.append(secret) }
		if let hardware { material.append(Data(hardware.utf8)) }
		material.append(Data(salt.utf8))
		return SymmetricKey(data: Data(SHA256.hash(data: material)))
	}
	public func saveDate(_ date: Date, for key: String) throws {
		try save("\(date.timeIntervalSince1970)|\(environment.continuousSeconds())", for: key, withIntegrityProtection: true)
	}
	public func getDate(for key: String) throws -> (date: Date, clockRollbackDetected: Bool) {
		let components = try get(for: key, verifyIntegrity: true).split(separator: "|")
		guard components.count == 2, let stored = Double(components[0]), let monotonic = Double(components[1]) else { throw AIKeychainError.invalidData }
		let date = Date(timeIntervalSince1970: stored), now = environment.wallClock().timeIntervalSince1970
		let continuousDelta = environment.continuousSeconds() - monotonic
		if continuousDelta < 0 { return (date, false) }
		if !(now + clockRollbackToleranceSeconds < stored + continuousDelta) { return (date, false) }
		let uptimeDelta = environment.uptime() - monotonic
		if uptimeDelta >= 0 && !(now + clockRollbackToleranceSeconds < stored + uptimeDelta) { try? saveDate(date, for: key); return (date, false) }
		return (date, true)
	}
}
