import AVFoundation
import CaptureKit
import CoreImage
import RawCore
import SwiftUI

@main
struct RawFilmDemoApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

/// Camera → CaptureService (Bayer RAW + HEIC, one press) → Developer (auto + stock) → files in Documents.
/// Every shot gets its own folder: capture.dng, apple.heic, capture.json, developed.heic, developed.recipe.json.
@MainActor
final class CameraModel: ObservableObject {
    let service = CaptureService()
    @Published var status = "Starting camera…"
    @Published var preview: UIImage?
    @Published var stock = "warm400"
    @Published var pluginsOn = true
    @Published var busy = false
    @Published var lastFolder: String?

    private let sessionQueue = DispatchQueue(label: "rawfilm.session")
    private let developer = Developer()

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { status = "Camera access denied (Settings → RawFilm)"; return }
        let service = self.service
        sessionQueue.async {
            do {
                try service.configure()
                service.session.startRunning()
                let raw = service.bayerRawFormat.map { CaptureMetadata.fourCC($0) } ?? "none (fallback: HEIC only)"
                Task { @MainActor in self.status = "Ready · Bayer RAW: \(raw)" }
            } catch {
                Task { @MainActor in self.status = "Camera error: \(error)" }
            }
        }
    }

    func shoot() {
        guard !busy else { return }
        busy = true
        status = "Capturing…"
        let service = self.service
        sessionQueue.async {
            service.capture { result in
                Task { @MainActor in self.handle(result) }
            }
        }
    }

    private func handle(_ result: Result<CaptureResult, Error>) {
        switch result {
        case .failure(let e):
            status = "Capture failed: \(e)"; busy = false
        case .success(let cap):
            status = "Developing…"
            let stock = self.stock, pluginsOn = self.pluginsOn, developer = self.developer
            Task.detached(priority: .userInitiated) {
                do {
                    let (folder, image, seconds) = try Self.develop(cap, stock: stock, pluginsOn: pluginsOn, developer: developer)
                    await MainActor.run {
                        self.preview = image
                        self.lastFolder = folder
                        self.status = String(format: "Done in %.1f s · Files app → On My iPhone → RawFilm → %@", seconds, folder)
                        self.busy = false
                    }
                } catch {
                    await MainActor.run { self.status = "Develop failed: \(error)"; self.busy = false }
                }
            }
        }
    }

    nonisolated static func develop(_ cap: CaptureResult, stock: String, pluginsOn: Bool, developer: Developer) throws -> (String, UIImage?, Double) {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = docs.appendingPathComponent(stamp)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(cap.metadata).write(to: dir.appendingPathComponent("capture.json"))
        if let heic = cap.heic { try heic.write(to: dir.appendingPathComponent("apple.heic")) }
        guard let dng = cap.dng else { return (stamp, cap.heic.flatMap(UIImage.init(data:)), 0) }   // fallback: nothing to develop
        let dngURL = dir.appendingPathComponent("capture.dng")
        try dng.write(to: dngURL)

        let t0 = Date()
        var settings = RenderSettings(mode: .explicit)
        settings.stock = stock == "none" ? nil : stock
        settings.plugins = pluginsOn ? nil : []
        let out = try developer.develop(url: dngURL, settings: settings, auto: true, scaleFactor: 1)
        let data = try developer.renderer.export(out.image, format: .heic10, recipe: out.recipe)
        try data.write(to: dir.appendingPathComponent("developed.heic"))
        try out.recipe.prettyJSON().write(to: dir.appendingPathComponent("developed.recipe.json"), atomically: true, encoding: .utf8)
        let seconds = Date().timeIntervalSince(t0)

        let small = out.image.transformed(by: CGAffineTransform(scaleX: 0.3, y: 0.3))
        let preview = developer.renderer.cgImage(small).map { UIImage(cgImage: $0) }
        return (stamp, preview, seconds)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var model = CameraModel()
    private let stocks = ["none"] + FilmStock.all.map(\.name)

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                CameraPreview(session: model.service.session).background(Color.black)
                if let img = model.preview {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(maxWidth: 140).border(.white, width: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(8)
                }
            }
            Picker("Stock", selection: $model.stock) { ForEach(stocks, id: \.self) { Text($0) } }.pickerStyle(.segmented)
            Toggle("Plugins (highlight recovery, vignette)", isOn: $model.pluginsOn)
            Button(action: model.shoot) {
                Text(model.busy ? "Working…" : "Shoot RAW").frame(maxWidth: .infinity).padding()
            }
            .buttonStyle(.borderedProminent).disabled(model.busy)
            Text(model.status).font(.footnote).multilineTextAlignment(.center)
        }
        .padding()
        .task { await model.start() }
    }
}
