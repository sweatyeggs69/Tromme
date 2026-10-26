import SwiftUI
import StoreKit

struct SettingsView: View {
    @AppStorage("hasRequestedAppReview") private var hasRequestedAppReview = false
    @State private var showReviewPrompt = false
    @State private var plus = PlusStore.shared
    @State private var showPaywall = false
    @State private var showManageSubscription = false

    var body: some View {
        Form {
            if !hasRequestedAppReview {
                Section {
                    Button("Leave a Review") {
                        showReviewPrompt = true
                    }
                }
            }

            Section {
                if plus.isGrandfathered {
                    Button("Support Tromme") { showPaywall = true }
                } else if plus.isPlus {
                    Button("Manage Tromme Plus") { showManageSubscription = true }
                } else {
                    Button("Get Tromme Plus") { showPaywall = true }
                }
            }

            Section {
                NavigationLink("Interface") { HomeSettingsView() }
                NavigationLink("Playback") { PlaybackSettingsView() }
                NavigationLink("Downloads") { OfflineSettingsView() }
                NavigationLink("App Icon") { AppIconPickerView() }
            }

            Section {
                VStack(spacing: 4) {
                    Text("Tromme")
                        .font(.footnote.weight(.medium))
                    Text(appVersionString)
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showPaywall) { PlusPaywallView() }
        .manageSubscriptionsSheet(isPresented: $showManageSubscription)
        .alert("Leave a Review?", isPresented: $showReviewPrompt) {
            Button("No Thanks", role: .cancel) {
                hasRequestedAppReview = true
            }
            Button("Leave Review") {
                requestAppReviewIfNeeded()
            }
        } message: {
            Text("Thanks for using Tromme! If you like it, let us know what you think.")
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Version \(version)"
    }

    private func requestAppReviewIfNeeded() {
        guard !hasRequestedAppReview else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }
        AppStore.requestReview(in: scene)
        hasRequestedAppReview = true
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(DownloadManager())
            .environment(AudioPlayerService())
    }
}
