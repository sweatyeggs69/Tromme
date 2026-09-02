import SwiftUI
import StoreKit

struct AppIconOption: Identifiable {
    let id: String
    let displayName: String
    let iconName: String?         // nil = primary icon
    let previewImageName: String  // asset catalog name for the picker thumbnail
    let accentColor: Color
}

extension AppIconOption {
    static let all: [AppIconOption] = [
        AppIconOption(id: "default",   displayName: "Default",   iconName: nil,                previewImageName: "preview-default",   accentColor: Color(red: 1.0,  green: 0.40, blue: 0.00)),
        AppIconOption(id: "blue",      displayName: "Blue",      iconName: "BlueAppIcon",      previewImageName: "preview-blue",      accentColor: Color(red: 0.20, green: 0.47, blue: 0.95)),
        AppIconOption(id: "green",     displayName: "Green",     iconName: "GreenAppIcon",     previewImageName: "preview-green",     accentColor: Color(red: 0.18, green: 0.72, blue: 0.38)),
        AppIconOption(id: "purple",    displayName: "Purple",    iconName: "PurpleAppIcon",    previewImageName: "preview-purple",    accentColor: Color(red: 0.55, green: 0.25, blue: 0.90)),
        AppIconOption(id: "red",       displayName: "Red",       iconName: "RedAppIcon",       previewImageName: "preview-red",       accentColor: Color(red: 0.95, green: 0.20, blue: 0.25)),
        AppIconOption(id: "pink",      displayName: "Pink",      iconName: "PinkAppIcon",      previewImageName: "preview-pink",      accentColor: Color(red: 0.97, green: 0.30, blue: 0.65)),
        AppIconOption(id: "yellow",    displayName: "Yellow",    iconName: "YellowAppIcon",    previewImageName: "preview-yellow",    accentColor: Color(red: 0.92, green: 0.70, blue: 0.05)),
        AppIconOption(id: "white",     displayName: "White",     iconName: "WhiteAppIcon",     previewImageName: "preview-white",     accentColor: Color(red: 0.85, green: 0.85, blue: 0.85)),
        AppIconOption(id: "black",     displayName: "Black",     iconName: "BlackAppIcon",     previewImageName: "preview-black",     accentColor: Color(red: 0.15, green: 0.15, blue: 0.15)),
    ]

    static let premiumIconPack: [AppIconOption] = [
        AppIconOption(id: "knocktua-dark",  displayName: "Knocktua Dark",  iconName: "KnocktuaDarkAppIcon",  previewImageName: "preview-knocktua-dark",  accentColor: Color(red: 0.529, green: 0.345, blue: 0.267)),
        AppIconOption(id: "knocktua-light", displayName: "Knocktua Light", iconName: "KnocktuaLightAppIcon", previewImageName: "preview-knocktua-light", accentColor: Color(red: 0.851, green: 0.792, blue: 0.639)),
        AppIconOption(id: "masterchief",    displayName: "Mister Chief",   iconName: "MasterChiefAppIcon",   previewImageName: "preview-masterchief",    accentColor: Color(red: 0.35, green: 0.55, blue: 0.25)),
        AppIconOption(id: "trommeify",      displayName: "Trommeify",      iconName: "TrommeifyAppIcon",     previewImageName: "preview-trommeify",      accentColor: Color(red: 0.20, green: 0.83, blue: 0.15)),
        AppIconOption(id: "usa",            displayName: "USA",            iconName: "USAAppIcon",           previewImageName: "preview-usa",            accentColor: Color(red: 0.70, green: 0.10, blue: 0.15)),
    ]

    static let prideIconPack: [AppIconOption] = [
        AppIconOption(id: "pride",        displayName: "Pride",              iconName: "PrideAppIcon",        previewImageName: "preview-pride",        accentColor: Color(red: 0.93, green: 0.12, blue: 0.11)),
        AppIconOption(id: "progress",     displayName: "Progress Pride",     iconName: "ProgressAppIcon",     previewImageName: "preview-progress",     accentColor: Color(red: 0.60, green: 0.22, blue: 0.80)),
        AppIconOption(id: "trans",        displayName: "Trans",              iconName: "TransAppIcon",        previewImageName: "preview-trans",        accentColor: Color(red: 0.37, green: 0.74, blue: 0.95)),
        AppIconOption(id: "bisexual",     displayName: "Bisexual",           iconName: "BisexualAppIcon",     previewImageName: "preview-bisexual",     accentColor: Color(red: 0.84, green: 0.18, blue: 0.50)),
        AppIconOption(id: "pansexual",    displayName: "Pansexual",          iconName: "PansexualAppIcon",    previewImageName: "preview-pansexual",    accentColor: Color(red: 1.00, green: 0.22, blue: 0.58)),
        AppIconOption(id: "nonbinary",    displayName: "Nonbinary",          iconName: "NonbinaryAppIcon",    previewImageName: "preview-nonbinary",    accentColor: Color(red: 0.99, green: 0.82, blue: 0.00)),
        AppIconOption(id: "genderfluid",  displayName: "Genderfluid",        iconName: "GenderfluidAppIcon",  previewImageName: "preview-genderfluid",  accentColor: Color(red: 0.97, green: 0.42, blue: 0.60)),
        AppIconOption(id: "genderqueer",  displayName: "Genderqueer",        iconName: "GenderqueerAppIcon",  previewImageName: "preview-genderqueer",  accentColor: Color(red: 0.71, green: 0.49, blue: 0.88)),
        AppIconOption(id: "asexual",      displayName: "Asexual",            iconName: "AsexualAppIcon",      previewImageName: "preview-asexual",      accentColor: Color(red: 0.44, green: 0.09, blue: 0.69)),
        AppIconOption(id: "demisexual",   displayName: "Demisexual",         iconName: "DemisexualAppIcon",   previewImageName: "preview-demisexual",   accentColor: Color(red: 0.48, green: 0.38, blue: 0.58)),
        AppIconOption(id: "intersex",     displayName: "Intersex",           iconName: "IntersexAppIcon",     previewImageName: "preview-intersex",     accentColor: Color(red: 0.93, green: 0.75, blue: 0.00)),
        AppIconOption(id: "bigender",     displayName: "Bigender",           iconName: "BigenderAppIcon",     previewImageName: "preview-bigender",     accentColor: Color(red: 0.91, green: 0.50, blue: 0.75)),
        AppIconOption(id: "bigender7",    displayName: "Bigender (7-Stripe)",iconName: "Bigender7AppIcon",    previewImageName: "preview-bigender7",    accentColor: Color(red: 0.45, green: 0.65, blue: 0.90)),
        AppIconOption(id: "transnonb",    displayName: "Trans + Nonbinary",  iconName: "TransNonBAppIcon",    previewImageName: "preview-transnonb",    accentColor: Color(red: 0.36, green: 0.64, blue: 0.74)),
        AppIconOption(id: "transpoc",     displayName: "Trans + PoC",        iconName: "TransPoCAppIcon",     previewImageName: "preview-transpoc",     accentColor: Color(red: 0.60, green: 0.35, blue: 0.20)),
        AppIconOption(id: "phillypride",  displayName: "Philly Pride",       iconName: "PhillyPrideAppIcon",  previewImageName: "preview-phillypride",  accentColor: Color(red: 0.75, green: 0.15, blue: 0.15)),
        AppIconOption(id: "lgbtqia+",     displayName: "LGBTQIA+",           iconName: "LGBTQIA+AppIcon",     previewImageName: "preview-lgbtqia+",     accentColor: Color(red: 0.50, green: 0.17, blue: 0.85)),
    ]

    static func accentColor(for iconId: String) -> Color {
        (all + premiumIconPack + prideIconPack).first { $0.id == iconId }?.accentColor ?? all[0].accentColor
    }
}

struct AppIconPickerView: View {
    @State private var currentIconName: String? = UIApplication.shared.alternateIconName
    @State private var applyError: String?
    @State private var iconPackStore = IconPackStore(productID: "PremiumIP")
    @State private var pridePackStore = IconPackStore(productID: "PrideIP")
    @AppStorage("selectedAppIconId") private var selectedAppIconId: String = "default"

    var body: some View {
        List {
            Section {
                ForEach(AppIconOption.all) { option in
                    iconRow(option)
                }
            } footer: {
                Text("Accent color takes effect after restarting the app.")
            }

            packSection(title: "Premium Icon Pack", options: AppIconOption.premiumIconPack, store: iconPackStore)
            packSection(title: "Pride Pack", options: AppIconOption.prideIconPack, store: pridePackStore)
        }
        .navigationTitle("App Icon")
        .alert("Couldn't Change Icon", isPresented: Binding(get: { applyError != nil }, set: { if !$0 { applyError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(applyError ?? "")
        }
        .alert("Purchase Failed", isPresented: Binding(get: { iconPackStore.purchaseError != nil }, set: { if !$0 { iconPackStore.purchaseError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(iconPackStore.purchaseError ?? "")
        }
        .alert("Purchase Failed", isPresented: Binding(get: { pridePackStore.purchaseError != nil }, set: { if !$0 { pridePackStore.purchaseError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pridePackStore.purchaseError ?? "")
        }
    }

    @ViewBuilder
    private func packSection(title: String, options: [AppIconOption], store: IconPackStore) -> some View {
        Section {
            if store.isPurchased {
                ForEach(options) { option in
                    iconRow(option)
                }
            } else {
                purchaseRow(title: title, store: store)

                ForEach(options) { option in
                    lockedIconRow(option)
                }

                Button {
                    Task { await store.restore() }
                } label: {
                    Text("Restore Purchases")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        } header: {
            Text(title)
        } footer: {
            Text("One-time purchase. Icon packs may grow over time and new additions are always free for existing purchasers!")
        }
    }

    @ViewBuilder
    private func purchaseRow(title: String, store: IconPackStore) -> some View {
        Button {
            Task { await store.purchase() }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.quaternary)
                    Image(systemName: "lock.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .fontWeight(.medium)
                }

                Spacer()

                if store.isPurchasing {
                    ProgressView()
                } else if store.isLoadingProduct {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if let product = store.product {
                    Text(product.displayPrice)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                } else {
                    Text("Buy")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isPurchasing || store.isLoadingProduct)
    }

    @ViewBuilder
    private func lockedIconRow(_ option: AppIconOption) -> some View {
        HStack(spacing: 14) {
            AppIconPreviewImage(named: option.previewImageName)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )

            Text(option.displayName)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    @ViewBuilder
    private func iconRow(_ option: AppIconOption) -> some View {
        Button {
            apply(option)
        } label: {
            HStack(spacing: 14) {
                AppIconPreviewImage(named: option.previewImageName)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(.separator), lineWidth: 0.5)
                    )

                Text(option.displayName)
                    .foregroundStyle(.primary)

                Spacer()

                if option.iconName == currentIconName {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func apply(_ option: AppIconOption) {
        guard option.iconName != currentIconName else { return }
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(option.iconName)
            } catch {
                // iOS can throw even when the icon change succeeds — fall through
                // and read back the actual system state below.
            }
            let actual = UIApplication.shared.alternateIconName
            currentIconName = actual
            selectedAppIconId = (AppIconOption.all + AppIconOption.premiumIconPack + AppIconOption.prideIconPack).first(where: { $0.iconName == actual })?.id ?? "default"
        }
    }
}

private struct AppIconPreviewImage: View {
    let named: String

    var body: some View {
        if let image = UIImage(named: named) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary)
                .overlay(Image(systemName: "app").font(.title2).foregroundStyle(.tertiary))
        }
    }
}

#Preview {
    NavigationStack {
        AppIconPickerView()
    }
}
