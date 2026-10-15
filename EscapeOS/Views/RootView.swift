import SwiftUI
import UniformTypeIdentifiers

private enum MainTab: Hashable {
    case apps
    case reclaim
    case backups
    case settings
}

/// Top-level navigation: native SwiftUI tab bar + pairing onboarding.
struct RootView: View {
    @StateObject private var viewModel = AppListViewModel()
    @AppStorage("HasAcknowledgedLimits") private var hasAcknowledgedLimits = false
    @State private var selectedTab: MainTab = .apps
    @ObservedObject private var copyFeedback = CopyFeedback.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationView {
                appsContent
                    .navigationTitle("Apps")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                viewModel.reload()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(viewModel.isLoading)
                        }
                    }
            }
            .tabItem {
                Label("Apps", systemImage: "square.grid.2x2.fill")
            }
            .tag(MainTab.apps)

            NavigationView {
                ReclaimTabView(appList: viewModel)
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("Reclaim", systemImage: "internaldrive")
            }
            .tag(MainTab.reclaim)

            NavigationView {
                BackupsListView(appList: viewModel)
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("Backups", systemImage: "externaldrive.fill.badge.timemachine")
            }
            .tag(MainTab.backups)

            NavigationView {
                SettingsForm(onResetPairing: {
                    viewModel.resetPairing()
                    selectedTab = .apps
                })
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(MainTab.settings)
        }
        .overlay(CopyBanner(message: copyFeedback.message))
        .sheet(isPresented: Binding(
            get: { !hasAcknowledgedLimits },
            set: { if !$0 { hasAcknowledgedLimits = true } }
        )) {
            LimitsDisclaimerView {
                hasAcknowledgedLimits = true
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            if hasAcknowledgedLimits {
                viewModel.reload()
            }
        }
        .onChange(of: hasAcknowledgedLimits) { acknowledged in
            if acknowledged {
                viewModel.reload()
            }
        }
    }

    @ViewBuilder
    private var appsContent: some View {
        if viewModel.isLoading && viewModel.apps.isEmpty && !viewModel.needsPairing {
            ProgressView("Loading apps…")
        } else if viewModel.needsPairing {
            PairingSetupView(viewModel: viewModel)
        } else if let error = viewModel.errorMessage, viewModel.apps.isEmpty {
            ErrorStateView(message: error, onRetry: { viewModel.reload() })
        } else if viewModel.apps.isEmpty {
            EmptyStateView(diagnostics: "No user apps returned by the device.")
        } else {
            AppListView(viewModel: viewModel)
        }
    }
}

/// Shown when no pairing file is present: import + LocalDevVPN instructions.
struct PairingSetupView: View {
    @ObservedObject var viewModel: AppListViewModel
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)

                Text("One-Time Setup")
                    .font(.title2).bold()
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 14) {
                    SetupStep(number: 1, title: "Install LocalDevVPN",
                               text: "Install LocalDevVPN from the App Store. Leave Device IP / Tunnel IP on the defaults (10.7.0.1) and connect it, with Wi-Fi on.")
                    SetupStep(number: 2, title: "Get a pairing file",
                               text: "Sideload with iPASide on Windows. It creates the same kind of pairing file as iLoader (USB trust keys plus Remote Pairing keys) and places pairingFile.plist automatically. You can also import an iLoader file here. After that, unplug — EscapeOS talks to this iPhone over LocalDevVPN, not over USB. On iOS 26.4+ the Remote Pairing keys are required; on iOS 18 the USB-trust half is enough.")
                    SetupStep(number: 3, title: "Load apps",
                               text: "EscapeOS then lists your installed apps so you can browse or back up their data.")
                }
                .padding(.horizontal)

                Button {
                    showImporter = true
                } label: {
                    Label("Import Pairing File", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)

                if let importError = importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Button("I already did this — Retry") {
                    viewModel.reload()
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [
                .item,
                .data,
                .content,
                .propertyList,
                .xml,
                .text,
                UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data) ?? .data
            ]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    let contents: String
                    if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
                        contents = utf8
                    } else if let xml = try? PropertyListSerialization.data(
                        fromPropertyList: try PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                        format: .xml,
                        options: 0
                    ), let text = String(data: xml, encoding: .utf8) {
                        contents = text
                    } else {
                        throw NSError(
                            domain: "EscapeOS",
                            code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Could not read that pairing file."]
                        )
                    }
                    try viewModel.importPairingFile(contents)
                    importError = nil
                    viewModel.reload()
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }
}

struct SetupStep: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundColor(.secondary)
            }
        }
    }
}

/// Generic error state with retry.
struct ErrorStateView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if message.contains("tunnel") || message.contains("LocalDevVPN") || message.contains("Heartbeat") {
                Text("Tip: reset LocalDevVPN to its default 10.7.0.1 addresses, stay on Wi-Fi, and let iPASide place a pairing file (or import one here). Custom LAN IPs are not required on iOS 26.5.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

/// Shown when no user apps are discoverable.
struct EmptyStateView: View {
    let diagnostics: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Apps Found")
                .font(.headline)
            Text(diagnostics)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

/// Settings form embedded in the Settings tab.
struct SettingsForm: View {
    var onResetPairing: () -> Void
    @AppStorage("TunnelDeviceIP") private var tunnelIP: String = "10.7.0.1"
    @AppStorage(DeleteConfirmation.preferenceKey) private var confirmFileDeletes = true

    var body: some View {
        Form {
            Section(header: Text("Local Tunnel"), footer: Text("Must match LocalDevVPN's Tunnel/Device IP. Keep the default 10.7.0.1 unless you changed LocalDevVPN.")) {
                TextField("Device IP (default 10.7.0.1)", text: $tunnelIP)
                    .keyboardType(.numbersAndPunctuation)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            Section(header: Text("Deleting"), footer: Text("Folders always ask first, because they take everything inside them.")) {
                Toggle("Confirm before deleting files", isOn: $confirmFileDeletes)
            }

            Section {
                Button("Reset Pairing File", role: .destructive) {
                    onResetPairing()
                }
            }

            Section(header: Text("Limits")) {
                Text(ProductLimits.title)
                    .font(.headline)
                Text(ProductLimits.body)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("About")) {
                Text(Self.aboutLine)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private static var aboutLine: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "EscapeOS \(short) (\(build))"
    }
}
