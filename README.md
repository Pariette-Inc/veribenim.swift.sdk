# VeribenimKit (iOS / Swift)

KVKK & GDPR rıza yönetimi — native iOS uygulamaları için. Web SDK'sı
(`@veribenim/core`) tarayıcıya bağlıdır ve mobilde çalışmaz; bu paket onun
native karşılığıdır.

Sıfır üçüncü parti bağımlılık.

## Kurulum

```swift
.package(url: "https://github.com/pariette/veribenim.swift.sdk", from: "1.0.0")
```

## Kullanım

```swift
let vb = Veribenim(config: .init(appIdentifier: "com.ornek.uygulama"))

if await vb.needsConsent() {
    // Kendi rıza ekranınızı gösterin.
    // Kategori metinleri sunucudan: try await vb.refresh()
}

await vb.accept(.granted)          // veya .init(functional: true, analytics: true)
await vb.rejectAll()

if await vb.isAllowed(.analytics) {
    FirebaseAnalytics.setAnalyticsCollectionEnabled(true)
}
```

### Google Consent Mode v2

```swift
await vb.onConsentChange { prefs in
    Analytics.setConsent([
        .analyticsStorage: prefs.analytics ? .granted : .denied,
        .adStorage:        prefs.marketing ? .granted : .denied,
        .adUserData:       prefs.marketing ? .granted : .denied,
        .adPersonalization:prefs.marketing ? .granted : .denied,
    ])
}
```

### ATT sırası (önemli)

Apple, ATT prompt'undan önce kendi izin ekranınızı göstermenize izin verir ama
ATT'yi **atlamanıza** izin vermez. Doğru sıra:

```swift
await vb.accept(prefs)
if await vb.shouldRequestTracking {
    ATTrackingManager.requestTrackingAuthorization { _ in }
}
```

SDK ATT'yi kendisi çağırmaz — yalnızca ne zaman çağırmanız gerektiğini söyler.
Ters sıra App Store reddi sebebidir.

## Tasarım notları

- **Önce diske, sonra ağa.** Ziyaretçinin kararı ağ hatasında kaybolmaz; banner
  bir sonraki açılışta ikinci kez çıkmaz.
- **Offline kuyruk.** Gönderilemeyen rıza kaydı diskte bekler. Rıza ispatı
  (KVKK Md.3) veri sorumlusundadır — kaybolmamalı.
- **İmzalı istekler.** Her rıza kaydı HMAC-SHA256 ile imzalanır; imza gövdeyi ve
  zaman damgasını kapsar. Sunucu karşılığı `AppDeviceSession::verifySignature`.
- **`strictlyNecessary` ayarlanamaz.** Reddedilemeyen bir kategoriyi ayarlanabilir
  göstermek yanıltıcıdır.

## Test

```bash
swift test
```
