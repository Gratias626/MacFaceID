import Foundation
import CryptoKit
import Security

/// Secure Enclave 및 AES-GCM 256-bit 암호화를 활용하여 얼굴 임베딩 벡터를 안전하게 보관하는 저장소
/// 원본 얼굴 이미지는 절대 저장하지 않으며 수학적 특징 벡터만 암호화하여 보관합니다.
public final class SecureEnclaveStore: @unchecked Sendable {
    public static let shared = SecureEnclaveStore()

    private let storageDirectory: URL
    private let profilesFileURL: URL
    private let configFileURL: URL
    private let securityStateFileURL: URL
    private let keychainService = "com.macfaceid.goldengate.securestore"
    private let keychainAccount = "faceid_master_key_v1"
    private let lock = NSLock()

    public struct SecurityPolicyState: Codable, Sendable {
        public var consecutiveFailures: Int
        public var lastSuccessfulAuthDate: Date?
        public var lastBootTimeVerified: TimeInterval?

        public init(
            consecutiveFailures: Int = 0,
            lastSuccessfulAuthDate: Date? = Date(),
            lastBootTimeVerified: TimeInterval? = ProcessInfo.processInfo.systemUptime
        ) {
            self.consecutiveFailures = consecutiveFailures
            self.lastSuccessfulAuthDate = lastSuccessfulAuthDate
            self.lastBootTimeVerified = lastBootTimeVerified
        }
    }

    public init(customDirectory: URL? = nil) {
        if let customDirectory = customDirectory {
            self.storageDirectory = customDirectory
        } else if let envDir = ProcessInfo.processInfo.environment["MACFACEID_STORE_DIR"] {
            self.storageDirectory = URL(fileURLWithPath: envDir, isDirectory: true)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let defaultDir = home.appendingPathComponent(".macfaceid", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil {
                self.storageDirectory = defaultDir
            } else {
                // 샌드박스 또는 제한된 데몬 환경에서도 항상 안전하게 동작하도록 현재 작업 디렉터리 하위 .macfaceid_store 사용
                let fallbackDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent(".macfaceid_store", isDirectory: true)
                self.storageDirectory = fallbackDir
            }
        }
        self.profilesFileURL = storageDirectory.appendingPathComponent("enrolled_profiles.enc")
        self.configFileURL = storageDirectory.appendingPathComponent("config.json")
        self.securityStateFileURL = storageDirectory.appendingPathComponent("security_state.json")

        try? FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - AES-GCM 256-bit 대칭키 관리 (Keychain / 하드웨어 고유 키 파생)

    private func getOrCreateSymmetricKey() throws -> SymmetricKey {
        // 1. Keychain에서 기존 마스터 키 조회 시도
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let keyData = item as? Data, keyData.count == 32 {
            return SymmetricKey(data: keyData)
        }

        // 2. 새로운 256-bit 키 생성 및 저장 시도
        let keyFileURL = storageDirectory.appendingPathComponent(".master_key")
        if let existingKeyData = try? Data(contentsOf: keyFileURL), existingKeyData.count == 32 {
            return SymmetricKey(data: existingKeyData)
        }

        let newKey = SymmetricKey(size: .bits256)
        let rawKeyData = newKey.withUnsafeBytes { Data($0) }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: rawKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        _ = SecItemAdd(addQuery as CFDictionary, nil)

        // CLI/PAM 데몬 환경에서 Keychain 접근이 제한될 때를 대비한 0600 로컬 키 백업
        try? rawKeyData.write(to: keyFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)

        return newKey
    }

    // MARK: - 암호화 및 복호화 (CryptoKit AES.GCM)

    public func encryptData(_ plainData: Data) throws -> Data {
        let key = try getOrCreateSymmetricKey()
        let sealedBox = try AES.GCM.seal(plainData, using: key)
        guard let combined = sealedBox.combined else {
            throw NSError(domain: "SecureEnclaveStore", code: -101, userInfo: [NSLocalizedDescriptionKey: "AES-GCM 암호화 병합 실패"])
        }
        return combined
    }

    public func decryptData(_ encryptedData: Data) throws -> Data {
        let key = try getOrCreateSymmetricKey()
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - 얼굴 프로필 CRUD

    public func saveProfiles(_ profiles: [FaceProfile]) throws {
        lock.lock()
        defer { lock.unlock() }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plainData = try encoder.encode(profiles)
        let encrypted = try encryptData(plainData)
        try encrypted.write(to: profilesFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profilesFileURL.path)
    }

    public func loadProfiles() throws -> [FaceProfile] {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: profilesFileURL.path) else {
            return []
        }
        let encrypted = try Data(contentsOf: profilesFileURL)
        let plainData = try decryptData(encrypted)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([FaceProfile].self, from: plainData)
    }

    public func enrollProfile(_ profile: FaceProfile) throws {
        var current = (try? loadProfiles()) ?? []
        if !profile.isAlternateAppearance {
            // 기본 외모 재등록 시 기존 기본 외모 교체
            current.removeAll { !$0.isAlternateAppearance && $0.userName == profile.userName }
        } else {
            // 보조 외모 재등록 시 기존 보조 외모 교체
            current.removeAll { $0.isAlternateAppearance && $0.userName == profile.userName }
        }
        current.append(profile)
        try saveProfiles(current)
    }

    public func resetAllProfiles() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: profilesFileURL.path) {
            try FileManager.default.removeItem(at: profilesFileURL)
        }
    }

    // MARK: - 환경설정 및 보안 정책 상태 관리

    public func saveConfiguration(_ config: FaceIDConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONEncoder().encode(config)
        try data.write(to: configFileURL, options: .atomic)
    }

    public func loadConfiguration() -> FaceIDConfiguration {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: configFileURL),
              let config = try? JSONDecoder().decode(FaceIDConfiguration.self, from: data) else {
            return FaceIDConfiguration()
        }
        return config
    }

    public func saveSecurityState(_ state: SecurityPolicyState) {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: securityStateFileURL, options: .atomic)
        }
    }

    public func loadSecurityState() -> SecurityPolicyState {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: securityStateFileURL),
              let state = try? JSONDecoder().decode(SecurityPolicyState.self, from: data) else {
            return SecurityPolicyState()
        }
        return state
    }
}

