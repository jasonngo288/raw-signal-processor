import AVFoundation
import CaptureKit
import CoreImage
import RawCore
import SwiftUI

@main
struct RawFilmDemoApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

/// One press = one folder in Documents (visible in Files → On My iPhone → RawFilm):
/// capture.dng, apple.heic, capture.json, analysis.json (+ person-mask.png), developed.heic + .recipe.json,
/// and developed_<stock>.heic + .recipe.json for every other look the user saves.
struct Shot: Identifiable {
    let id = UUID()
    let folder: URL
    let stamp: String
    let dngURL: URL?
    let heicURL: URL?
    let metadata: CaptureMetadata
    /// The camera's own picture of the press (HEIC), shown before developing.
    let preview: UIImage?
}

enum Screen {
    case camera
    case preview(Shot)
    case developing(Shot)
    case result(Shot)
}

/// Flow: camera → preview (camera HEIC) → Develop (pipeline) → result → change the look (re-finish, no new decode)
/// → back to the camera. The analysis runs in the background right after the press (AGENTS.md product integration),
/// so Develop only decodes and finishes.
@MainActor
final class CameraModel: ObservableObject {
    let service = CaptureService()
    @Published var screen: Screen = .camera
    @Published var status = "Starting camera…"
    @Published var stock = "softPortrait"
    @Published var pluginsOn = true
    @Published var proRAW = false
    @Published var proRAWSupported = false
    @Published var capturing = false

    // Result state
    @Published var resultImage: UIImage?
    @Published var resultStock = "softPortrait"
    @Published var resultBusy = false
    @Published var resultNote = ""
    @Published var savedStocks: Set<String> = []

    nonisolated let developer = Developer()
    private let sessionQueue = DispatchQueue(label: "rawfilm.session")
    private var analysisTasks: [UUID: Task<Developer.Analysis?, Never>] = [:]
    private var base: Developer.Base?
    private var developedSeconds: Double = 0

    /// The 2026 film-look set first (it replaces MoodRoll's looks), then the older stocks.
    static let stockNames = ["none"] + FilmLooks2026.names + FilmStock.all.map(\.name).filter { !FilmLooks2026.names.contains($0) }

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { status = "Camera access denied (Settings → RawFilm)"; return }
        let service = self.service
        sessionQueue.async {
            do {
                try service.configure()
                service.session.startRunning()
                let raw = service.bayerRawFormat.map { CaptureMetadata.fourCC($0) } ?? "none (fallback: HEIC only)"
                let pro = service.proRAWSupported
                Task { @MainActor in self.proRAWSupported = pro; self.status = "Ready · Bayer RAW: \(raw) · ProRAW: \(pro ? "available" : "not on this model")" }
            } catch {
                Task { @MainActor in self.status = "Camera error: \(error)" }
            }
        }
    }

    /// Bayer (single frame) vs ProRAW (multi-frame fused) where the device supports it.
    func setProRAW(_ on: Bool) {
        let service = self.service
        sessionQueue.async { service.setRawPreference(on ? .proRAWWhenSupported : .bayer) }
    }

    // MARK: Camera → preview

    func shoot() {
        guard !capturing else { return }
        capturing = true
        status = "Capturing…"
        let service = self.service
        sessionQueue.async {
            service.capture { result in
                Task { @MainActor in self.handle(result) }
            }
        }
    }

    private func handle(_ result: Result<CaptureResult, Error>) {
        capturing = false
        switch result {
        case .failure(let e):
            status = "Capture failed: \(e)"
        case .success(let cap):
            do {
                let shot = try Self.save(cap)
                status = shot.dngURL == nil ? "No RAW from this press (HEIC only)" : "Saved \(shot.stamp) · analysing in background…"
                startAnalysis(shot)
                screen = .preview(shot)
            } catch {
                status = "Could not save the capture: \(error)"
            }
        }
    }

    /// Writes the press to its own folder in Documents right away, so it is in Files even if the app stops here.
    nonisolated static func save(_ cap: CaptureResult) throws -> Shot {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = docs.appendingPathComponent(stamp)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(cap.metadata).write(to: dir.appendingPathComponent("capture.json"))
        var heicURL: URL?
        if let heic = cap.heic { heicURL = dir.appendingPathComponent("apple.heic"); try heic.write(to: heicURL!) }
        var dngURL: URL?
        if let dng = cap.dng { dngURL = dir.appendingPathComponent("capture.dng"); try dng.write(to: dngURL!) }
        return Shot(folder: dir, stamp: stamp, dngURL: dngURL, heicURL: heicURL, metadata: cap.metadata,
                    preview: cap.heic.flatMap(UIImage.init(data:)))
    }

    /// Capture-time analysis, stored next to the DNG (analysis.json + person-mask.png). Develop awaits it.
    private func startAnalysis(_ shot: Shot) {
        guard let dng = shot.dngURL else { return }
        let developer = self.developer
        let ref = shot.heicURL?.path
        let folder = shot.folder
        analysisTasks[shot.id] = Task.detached(priority: .utility) {
            do {
                let a = try developer.analyze(url: dng, cameraReference: ref)
                try a.write(to: folder, renderer: developer.renderer)
                return a
            } catch {
                return nil   // develop will analyse itself and say so in the recipe
            }
        }
    }

    // MARK: Preview → develop → result

    func develop(_ shot: Shot) {
        guard let dng = shot.dngURL else { status = "This press has no RAW to develop"; return }
        screen = .developing(shot)
        resultNote = ""
        savedStocks = []
        let analysisTask = analysisTasks[shot.id]
        let developer = self.developer
        var settings = RenderSettings(mode: .explicit)
        settings.stock = stock == "none" ? nil : stock
        settings.plugins = pluginsOn ? nil : []
        settings.cameraReference = shot.heicURL?.path
        let chosen = stock
        Task {
            let t0 = Date()
            let analysis = await analysisTask?.value
            do {
                let base = try await Task.detached(priority: .userInitiated) {
                    try developer.developBase(url: dng, settings: settings, auto: true, scaleFactor: 1, analysis: analysis)
                }.value
                self.base = base
                self.developedSeconds = Date().timeIntervalSince(t0)
                await self.applyLook(chosen, shot: shot, save: true)
                self.screen = .result(shot)
            } catch {
                self.status = "Develop failed: \(error)"
                self.screen = .preview(shot)
            }
        }
    }

    /// Re-finishes the stored base with another stock: no decode, only look + skin protection + grain/halation.
    func applyLook(_ name: String, shot: Shot, save: Bool) async {
        guard var b = base else { return }
        resultBusy = true
        resultStock = name
        b.settings.stock = name == "none" ? nil : name
        b.settings.look = nil
        b.settings.finish = nil
        let developer = self.developer
        let wasBase = b
        let developedSeconds = self.developedSeconds
        let folder = shot.folder
        let out: (UIImage?, String)? = try? await Task.detached(priority: .userInitiated) {
            let o = try developer.finish(wasBase)
            let img = Self.displayImage(o.image, renderer: developer.renderer)
            var note = String(format: "%@ · developed in %.1f s", name, developedSeconds)
            if save {
                try Self.export(o, stock: name, folder: folder, primary: true, renderer: developer.renderer)
                note += " · saved developed.heic"
            }
            return (img, note)
        }.value
        resultImage = out?.0 ?? resultImage
        resultNote = out?.1 ?? "Could not apply \(name)"
        if save, out != nil { savedStocks.insert(name) }
        resultBusy = false
    }

    /// Full-resolution export of the current look into the shot's folder.
    func saveCurrentLook(_ shot: Shot) async {
        guard var b = base else { return }
        let name = resultStock
        b.settings.stock = name == "none" ? nil : name
        b.settings.look = nil
        b.settings.finish = nil
        resultBusy = true
        let developer = self.developer
        let wasBase = b
        let folder = shot.folder
        let ok: Bool = (try? await Task.detached(priority: .userInitiated) {
            try Self.export(developer.finish(wasBase), stock: name, folder: folder, primary: false, renderer: developer.renderer)
            return true
        }.value) ?? false
        if ok { savedStocks.insert(name); resultNote = "Saved developed_\(Self.fileTag(name)).heic in Files" }
        else { resultNote = "Saving \(name) failed" }
        resultBusy = false
    }

    func backToCamera() {
        base = nil
        resultImage = nil
        screen = .camera
        status = "Ready"
    }

    // MARK: Helpers (off the main actor)

    nonisolated static func fileTag(_ stock: String) -> String { stock.replacingOccurrences(of: " ", with: "_") }

    nonisolated static func export(_ o: Developer.Output, stock: String, folder: URL, primary: Bool, renderer: Renderer) throws {
        let name = primary ? "developed" : "developed_\(fileTag(stock))"
        let data = try renderer.export(o.image, format: .heic10, recipe: o.recipe)
        try data.write(to: folder.appendingPathComponent(name + ".heic"))
        try o.recipe.prettyJSON().write(to: folder.appendingPathComponent(name + ".recipe.json"), atomically: true, encoding: .utf8)
    }

    /// Screen-sized copy for display (the full-resolution image is only rendered on export).
    nonisolated static func displayImage(_ image: CIImage, renderer: Renderer, longEdge: CGFloat = 1600) -> UIImage? {
        let e = image.extent
        let s = min(1, longEdge / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: s, y: s))
        return renderer.cgImage(small).map { UIImage(cgImage: $0) }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var model = CameraModel()

    var body: some View {
        Group {
            switch model.screen {
            case .camera: CameraScreen(model: model)
            case .preview(let shot): PreviewScreen(model: model, shot: shot)
            case .developing(let shot): DevelopingScreen(shot: shot)
            case .result(let shot): ResultScreen(model: model, shot: shot)
            }
        }
        .task { await model.start() }
    }
}

struct CameraScreen: View {
    @ObservedObject var model: CameraModel

    var body: some View {
        VStack(spacing: 12) {
            CameraPreview(session: model.service.session).background(Color.black)
            Toggle("Plugins (highlight recovery, camera match, vignette)", isOn: $model.pluginsOn)
            Toggle("ProRAW (multi-frame, Pro models)", isOn: $model.proRAW)
                .disabled(!model.proRAWSupported)
                .onChange(of: model.proRAW) { _, on in model.setProRAW(on) }
            Button(action: model.shoot) {
                Text(model.capturing ? "Capturing…" : "Shoot RAW").frame(maxWidth: .infinity).padding()
            }
            .buttonStyle(.borderedProminent).disabled(model.capturing)
            Text(model.status).font(.footnote).multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct PreviewScreen: View {
    @ObservedObject var model: CameraModel
    let shot: Shot

    var body: some View {
        VStack(spacing: 12) {
            Text("Camera preview (Apple HEIC)").font(.headline)
            Group {
                if let img = shot.preview {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Text("No HEIC preview for this press").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Picker("Look", selection: $model.stock) { ForEach(CameraModel.stockNames, id: \.self) { Text($0) } }
                .pickerStyle(.menu)
            Button { model.develop(shot) } label: {
                Text("Develop").frame(maxWidth: .infinity).padding()
            }
            .buttonStyle(.borderedProminent)
            .disabled(shot.dngURL == nil)
            Button("Retake", role: .cancel) { model.backToCamera() }
            Text(model.status).font(.footnote).multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct DevelopingScreen: View {
    let shot: Shot

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Developing \(shot.stamp)…").font(.headline)
            Text("Waits for the background analysis, then decodes the RAW and applies the look.")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResultScreen: View {
    @ObservedObject var model: CameraModel
    let shot: Shot
    @State private var showCamera = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if showCamera, let img = shot.preview {
                    Image(uiImage: img).resizable().scaledToFit()
                } else if let img = model.resultImage {
                    Image(uiImage: img).resizable().scaledToFit()
                }
                if model.resultBusy { ProgressView().controlSize(.large) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onLongPressGesture(minimumDuration: 0.1, maximumDistance: 50, pressing: { showCamera = $0 }, perform: {})
            Text(showCamera ? "Camera HEIC (release to see the develop)" : "Hold the photo to compare with the camera HEIC")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CameraModel.stockNames, id: \.self) { name in
                        Button(label(name)) { Task { await model.applyLook(name, shot: shot, save: false) } }
                            .buttonStyle(.bordered)
                            .tint(name == model.resultStock ? .accentColor : .secondary)
                            .disabled(model.resultBusy)
                    }
                }
                .padding(.horizontal, 4)
            }
            HStack {
                Button("New photo") { model.backToCamera() }
                    .buttonStyle(.bordered)
                Button(model.savedStocks.contains(model.resultStock) ? "Saved" : "Save this look") {
                    Task { await model.saveCurrentLook(shot) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.resultBusy || model.savedStocks.contains(model.resultStock))
            }
            Text(model.resultNote + " · Files → On My iPhone → RawFilm → \(shot.stamp)")
                .font(.footnote).multilineTextAlignment(.center)
        }
        .padding()
    }

    private func label(_ name: String) -> String { name.replacingOccurrences(of: "PRESET_26_", with: "26 ") }
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
