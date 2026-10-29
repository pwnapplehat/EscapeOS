import SwiftUI
import UIKit
import QuickLook
import AVKit
import PDFKit

/// Opens a container file using Preview, text, hex, image, PDF, or media.
struct FileViewerView: View {
    let app: InstalledApp
    let item: FileItem
    let mode: FileOpenMode

    @StateObject private var vm = FileViewerViewModel()

    var body: some View {
        // A database is never read into memory whole: it is copied to a private place and opened there.
        if mode == .database || (mode == .auto && FileContentKind.opensAsDatabase(name: item.name)) {
            SQLiteViewerView(app: app, item: item)
        } else {
            viewer
        }
    }

    private var viewer: some View {
        Group {
            if vm.isLoading {
                ProgressView("Opening…")
            } else if let error = vm.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            } else {
                content
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.canSave {
                    Button("Save") { vm.save() }
                        .disabled(vm.isSaving)
                }
            }
        }
        .alert(item: $vm.saveAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .onAppear {
            vm.load(app: app, item: item, mode: mode)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.resolvedMode {
        case .image:
            if let image = vm.image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                }
            } else {
                fallbackHex
            }
        case .pdf:
            if let url = vm.previewURL {
                PDFKitView(url: url)
            } else {
                fallbackHex
            }
        case .media:
            if let url = vm.previewURL {
                MediaPlayerView(url: url)
            } else {
                fallbackHex
            }
        case .preview:
            if let url = vm.previewURL {
                QuickLookPreview(url: url)
            } else {
                fallbackHex
            }
        case .text:
            TextFileEditorView(vm: vm)
        case .hex, .auto, .database:
            HexEditorView(vm: vm)
        }
    }

    private var fallbackHex: some View {
        HexEditorView(vm: vm)
    }
}

final class FileViewerViewModel: ObservableObject {
    static let maxEditableBytes = 512 * 1024
    static let maxTextBytes = 2 * 1024 * 1024

    @Published var isLoading = true
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var resolvedMode: FileOpenMode = .hex
    @Published var text = ""
    @Published var bytes: [UInt8] = []
    @Published var image: UIImage?
    @Published var previewURL: URL?
    @Published var truncated = false
    @Published var saveAlert: NamedAlert?
    @Published var isDirty = false

    private var app: InstalledApp?
    private var item: FileItem?
    private var originalData = Data()
    private let escape = SandboxEscape()
    private let files = FileService()

    var canSave: Bool {
        !truncated && (resolvedMode == .text || resolvedMode == .hex) && isDirty
    }

    func load(app: InstalledApp, item: FileItem, mode: FileOpenMode) {
        self.app = app
        self.item = item
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try self.escape.withHandle(for: app.containerPath) { _ in
                    try self.files.readFile(at: item.path)
                }
                let kind = FileContentKind.classify(name: item.name, isDirectory: false)
                let resolved = self.resolve(mode: mode, kind: kind, data: data)
                let preview = try self.stagePreview(named: item.name, data: data)
                DispatchQueue.main.async {
                    self.originalData = data
                    self.previewURL = preview
                    self.resolvedMode = resolved
                    self.apply(data: data, mode: resolved)
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func save() {
        guard let app = app, let item = item, !truncated else { return }
        isSaving = true
        let payload: Data
        if resolvedMode == .text {
            payload = Data(text.utf8)
        } else {
            payload = Data(bytes)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.escape.withHandle(for: app.containerPath) { _ in
                    try self.files.writeFile(data: payload, to: item.path)
                }
                DispatchQueue.main.async {
                    self.originalData = payload
                    self.isDirty = false
                    self.isSaving = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.saveAlert = NamedAlert(title: "Save Failed", message: error.localizedDescription)
                }
            }
        }
    }

    func markDirty() {
        isDirty = true
    }

    private func resolve(mode: FileOpenMode, kind: FileContentKind, data: Data) -> FileOpenMode {
        if mode != .auto { return mode }
        if kind == .image, UIImage(data: data) != nil { return .image }
        if kind == .pdf { return .pdf }
        if kind == .audio || kind == .video { return .media }
        if kind == .text || kind == .plist || kind == .json || kind == .xml {
            if String(data: data, encoding: .utf8) != nil || String(data: data, encoding: .utf16) != nil {
                return .text
            }
        }
        if kind == .plist, (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil {
            return .text
        }
        if data.count <= Self.maxTextBytes, String(data: data, encoding: .utf8) != nil {
            return .text
        }
        return .hex
    }

    private func apply(data: Data, mode: FileOpenMode) {
        truncated = false
        switch mode {
        case .image:
            image = UIImage(data: data)
            bytes = Array(data.prefix(Self.maxEditableBytes))
        case .text:
            if data.count > Self.maxTextBytes {
                truncated = true
                text = String(decoding: data.prefix(Self.maxTextBytes), as: UTF8.self)
            } else if let utf8 = String(data: data, encoding: .utf8) {
                text = prettyPrintedIfNeeded(utf8, name: item?.name ?? "")
            } else if let plist = prettyPlist(from: data) {
                text = plist
            } else {
                truncated = data.count > Self.maxEditableBytes
                bytes = Array(data.prefix(Self.maxEditableBytes))
                resolvedMode = .hex
            }
        case .hex, .auto:
            truncated = data.count > Self.maxEditableBytes
            bytes = Array(data.prefix(Self.maxEditableBytes))
        default:
            bytes = Array(data.prefix(Self.maxEditableBytes))
        }
    }

    private func prettyPrintedIfNeeded(_ text: String, name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "json", let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let out = String(data: pretty, encoding: .utf8) {
            return out
        }
        return text
    }

    private func prettyPlist(from data: Data) -> String? {
        var format: PropertyListSerialization.PropertyListFormat = .xml
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) else {
            return nil
        }
        guard let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) else {
            return nil
        }
        return String(data: xml, encoding: .utf8)
    }

    private func stagePreview(named name: String, data: Data) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EscapeOSPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct NamedAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct TextFileEditorView: View {
    @ObservedObject var vm: FileViewerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if vm.truncated {
                Text("File is larger than 2 MB. Showing the first 2 MB as read-only.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.12))
            }
            TextEditor(text: $vm.text)
                .font(.system(size: 13, design: .monospaced))
                .disableAutocorrection(true)
                .onChange(of: vm.text) { _ in
                    if !vm.truncated { vm.markDirty() }
                }
                .disabled(vm.truncated)
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}

struct MediaPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
