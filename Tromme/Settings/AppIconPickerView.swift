import SwiftUI
import StoreKit

struct AppIconPickerView: View {
    @State private var currentIconName: String? = UIApplication.shared.alternateIconName
    @State private var applyError: String?
    @State private var plus = PlusStore.shared
    @State private var showPaywall = false
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

            packSection(title: "Premium Icon Pack", options: AppIconOption.premiumIconPack)
        }
        .navigationTitle("App Icon")
        .alert("Couldn't Change Icon", isPresented: Binding(get: { applyError != nil }, set: { if !$0 { applyError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(applyError ?? "")
        }
        .sheet(isPresented: $showPaywall) { PlusPaywallView() }
    }

    @ViewBuilder
    private func packSection(title: String, options: [AppIconOption]) -> some View {
        Section {
            if plus.isPlus {
                ForEach(options) { option in
                    iconRow(option)
                }
            } else {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppStyle.Radius.appIcon, style: .continuous)
                                .fill(.quaternary)
                            Image(systemName: "lock.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 60, height: 60)

                        Text("Unlock with Tromme Plus")
                            .foregroundStyle(.primary)
                            .fontWeight(.medium)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ForEach(options) { option in
                    lockedIconRow(option)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text("Included with Tromme Plus. New icons are added over time.")
        }
    }

    @ViewBuilder
    private func lockedIconRow(_ option: AppIconOption) -> some View {
        HStack(spacing: 14) {
            AppIconPreviewImage(named: option.previewImageName)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.appIcon, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppStyle.Radius.appIcon, style: .continuous)
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
                    .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.appIcon, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.Radius.appIcon, style: .continuous)
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
            selectedAppIconId = (AppIconOption.all + AppIconOption.premiumIconPack).first(where: { $0.iconName == actual })?.id ?? "default"
        }
    }
}

#Preview {
    NavigationStack {
        AppIconPickerView()
    }
}
