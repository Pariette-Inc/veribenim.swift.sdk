import Foundation

/// Platformun otoritatif rıza kategorileri.
///
/// Web SDK'sı (`@veribenim/core` → `ConsentPreferences`) ve sunucu
/// (`CookieProvider::SIGNAL_CATEGORIES`) ile birebir aynı dört anahtar.
/// Mobilde kategori isimleri değişmez — değişen, altındaki teknolojidir:
/// çerez yerine cihaz tanımlayıcısı.
public enum ConsentCategory: String, CaseIterable, Codable, Sendable {
    case strictlyNecessary = "strictly_necessary"
    case functional
    case analytics
    case marketing

    /// Zorunlu kategori reddedilemez; ziyaretçiye kapalı bir anahtar gösterilmez.
    public var isRequired: Bool { self == .strictlyNecessary }
}

/// Kategori bazlı rıza durumu.
public struct ConsentPreferences: Equatable, Codable, Sendable {
    public var strictlyNecessary: Bool
    public var functional: Bool
    public var analytics: Bool
    public var marketing: Bool

    /// `strictlyNecessary` bilinçli olarak parametre DEĞİL: reddedilemeyen bir
    /// kategoriyi ayarlanabilir göstermek, çağıranı kapatabileceği yanılgısına
    /// düşürür. Daima `true`.
    public init(
        functional: Bool = false,
        analytics: Bool = false,
        marketing: Bool = false
    ) {
        self.strictlyNecessary = true
        self.functional = functional
        self.analytics = analytics
        self.marketing = marketing
    }

    /// Rıza alınmadan önceki durum: yalnızca zorunlu.
    public static let denied = ConsentPreferences()

    /// Tümünü kabul.
    public static let granted = ConsentPreferences(
        functional: true, analytics: true, marketing: true
    )

    public subscript(category: ConsentCategory) -> Bool {
        get {
            switch category {
            case .strictlyNecessary: return true
            case .functional:        return functional
            case .analytics:         return analytics
            case .marketing:         return marketing
            }
        }
        set {
            switch category {
            case .strictlyNecessary: break   // değiştirilemez
            case .functional:        functional = newValue
            case .analytics:         analytics = newValue
            case .marketing:         marketing = newValue
            }
        }
    }

    /// Sunucunun beklediği sözlük (`consents` alanı).
    public var payload: [String: Bool] {
        [
            ConsentCategory.strictlyNecessary.rawValue: true,
            ConsentCategory.functional.rawValue: functional,
            ConsentCategory.analytics.rawValue: analytics,
            ConsentCategory.marketing.rawValue: marketing,
        ]
    }

    public init(payload: [String: Bool]) {
        self.init(
            functional: payload[ConsentCategory.functional.rawValue] ?? false,
            analytics: payload[ConsentCategory.analytics.rawValue] ?? false,
            marketing: payload[ConsentCategory.marketing.rawValue] ?? false
        )
    }
}

/// Ziyaretçinin verdiği karar — sunucuya `action` olarak gider.
public enum ConsentAction: String, Codable, Sendable {
    case acceptAll = "accept_all"
    case rejectAll = "reject_all"
    case savePreferences = "save_preferences"
    case withdraw
}

/// Kaydedilmiş rıza — kararın kendisi + ne zaman ve hangi beyan sürümüne verildiği.
public struct ConsentRecord: Equatable, Codable, Sendable {
    public let preferences: ConsentPreferences
    public let action: ConsentAction
    public let decidedAt: Date
    /// Sunucudaki beyan sürümü. Değişirse rıza yeniden sorulur.
    public let consentVersion: String?
    /// Cihaz oturumu değiştiğinde bile kararı taşıyan yerel oturum kimliği.
    public let sessionId: String

    public init(
        preferences: ConsentPreferences,
        action: ConsentAction,
        decidedAt: Date = Date(),
        consentVersion: String? = nil,
        sessionId: String
    ) {
        self.preferences = preferences
        self.action = action
        self.decidedAt = decidedAt
        self.consentVersion = consentVersion
        self.sessionId = sessionId
    }
}
