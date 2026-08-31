#if canImport(SwiftUI)
import SwiftUI

/// Hazır rıza ekranı.
///
/// Kendi tasarımınızı çizmek isterseniz bu görünümü hiç kullanmayın —
/// `Veribenim` tüm kararları verir. Bu "hızlı başlangıç" içindir.
///
/// KVKK Rehberi No:69 Bölüm 7.3 gereği "Reddet" butonu "Kabul Et" ile aynı
/// görsel ağırlıkta ve aynı ekranda durur; gizlenemez, ikinci adıma atılamaz.
@available(iOS 15.0, macOS 12.0, *)
public struct ConsentSheet: View {
    private let veribenim: Veribenim
    private let accent: Color
    private let onDecided: ((ConsentPreferences) -> Void)?

    @State private var categories: [ConsentCategoryInfo] = []
    @State private var showingDetails = false
    @State private var draft = ConsentPreferences.denied
    @State private var busy = false

    public init(
        veribenim: Veribenim,
        accent: Color = Color(red: 0.02, green: 0.59, blue: 0.41),
        onDecided: ((ConsentPreferences) -> Void)? = nil
    ) {
        self.veribenim = veribenim
        self.accent = accent
        self.onDecided = onDecided
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gizlilik Tercihleriniz")
                .font(.headline)

            Text(
                "Uygulamayı geliştirmek ve size uygun içerik sunmak için cihazınızda "
                + "tanımlayıcılar kullanıyoruz. Zorunlu olanlar dışındakiler yalnızca "
                + "izninizle çalışır."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if showingDetails {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(optionalCategories, id: \.self) { category in
                            row(for: category)
                        }
                        requiredRow
                    }
                }
                .frame(maxHeight: 260)
            }

            // Kabul ve Reddet aynı ağırlıkta — KVKK Rehberi No:69 Bölüm 7.3.
            HStack(spacing: 12) {
                Button {
                    decide { await veribenim.rejectAll() }
                } label: {
                    Text("Reddet")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(Color.gray.opacity(0.15))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    decide { await veribenim.accept(.granted) }
                } label: {
                    Text("Tümünü Kabul Et")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(busy)

            if showingDetails {
                Button("Seçimimi Kaydet") {
                    decide { await veribenim.accept(draft) }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .disabled(busy)
            } else {
                Button("Tercihleri Yönet") { showingDetails = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .task {
            // Beyan sunucudan gelir: kategori listesi ve metinler konsoldan
            // yönetilir, uygulamaya gömülmez. Ağ yoksa yerel yedek metinlerle
            // devam edilir — ziyaretçi rıza veremeden kilitli kalmamalı.
            categories = (try? await veribenim.refresh().categories) ?? []
        }
    }

    // MARK: - Parçalar

    private var optionalCategories: [ConsentCategory] {
        [.functional, .analytics, .marketing].filter { category in
            categories.isEmpty || categories.contains { $0.id == category.rawValue }
        }
    }

    private func label(for category: ConsentCategory) -> String {
        categories.first { $0.id == category.rawValue }?.label ?? fallbackLabel(category)
    }

    private func fallbackLabel(_ category: ConsentCategory) -> String {
        switch category {
        case .strictlyNecessary: return "Zorunlu"
        case .functional:        return "İşlevsel"
        case .analytics:         return "Analitik"
        case .marketing:         return "Pazarlama"
        }
    }

    private func row(for category: ConsentCategory) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: category)).font(.subheadline.weight(.semibold))

                // Mobilde depolama türü 'cookie' değil 'device_id' / 'app_storage'
                // olarak gösterilir — KVKK Rehberi No:69 beyan zorunluluğu.
                ForEach(trackers(for: category).prefix(3), id: \.id) { tracker in
                    Text(tracker.storageType.map { "\(tracker.name) · \($0)" } ?? tracker.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { draft[category] },
                set: { draft[category] = $0 }
            ))
            .labelsHidden()
            .tint(accent)
        }
        .padding(.vertical, 10)
    }

    private var requiredRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: .strictlyNecessary)).font(.subheadline.weight(.semibold))
                Text("Uygulamanın çalışması için gerekli — kapatılamaz.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: .constant(true)).labelsHidden().disabled(true)
        }
        .padding(.vertical, 10)
    }

    private func trackers(for category: ConsentCategory) -> [ConsentCategoryInfo.Tracker] {
        categories.first { $0.id == category.rawValue }?.cookies ?? []
    }

    private func decide(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            let prefs = await veribenim.preferences
            busy = false
            onDecided?(prefs)
        }
    }
}
#endif
