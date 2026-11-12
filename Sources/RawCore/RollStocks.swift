import Foundation

/// The roll stocks of the app (RollioRoll, formerly MoodRoll): what the user picks before shooting a roll
/// (24/36 frames). The whole roll is developed with that stock at the end.
/// Naming brief: docs/input/doi-ten-film-stock-RR-2026-11-11.md (rules R1–R10).
///
/// - A roll stock is an **identity layer**, not a new look. It names one of the generated looks (`FilmLooks2026`,
///   colour only, without flashDigicam), and sets:
///   - its own intensity;
///   - grain from its ISO (`RollStock.grain(iso:)`);
///   - the base look's halation and vignette.
/// - Several stocks can share a look. They then differ in ISO (grain) or intensity, never both the same (R5).
///   `RollStocksTests` checks this.
/// - Display names never contain a film maker's or product's name (R1, R7). The source stock each one is inspired
///   by lives only in `.orchestration/looks/RR_STOCKS_2026-11-11.md`, never in code, recipes or the UI (R6).
/// - No tier / paywall here: the host app decides (user, 2026-11-11). This library only needs the RAW and a stock id.
/// - Resolved by id through `FilmStock.named` (e.g. `RenderSettings.stock = "rr-vang-200"`). Not part of
///   `FilmStock.all`, which stays the bench / look-review list.
public struct RollStock: Equatable, Sendable {
    /// ASCII slug, used in settings, recipes and storage (R4): `rr-vang-200`.
    public var id: String
    /// UI name with full Vietnamese diacritics (R2, R3): `RR Vàng 200`.
    public var nameVi: String
    /// English UI name (user decision 2026-11-11: column B of `.orchestration/looks/RR_NAMES_EN_2026-11-11.md`).
    /// An ordinary English word that cues the feel, never a maker's product word. "Portrait …" is flagged for the
    /// trademark check before launch.
    public var nameEn: String { RollStocks.englishNames[id] ?? nameVi }
    /// ISO shown on the box. `tungsten` adds the "T" suffix (R8).
    public var iso: Int
    public var tungsten: Bool
    /// Generated look it develops with (`FilmLooks2026` name).
    public var look: String
    public var intensity: Float
    /// Colour feel, in English, with no brand words (shown in docs; the UI uses `nameVi`).
    public var vibe: String
    /// What is still provisional about this stock (shown in docs, not guessed).
    public var openQuestions: [String] = []

    /// Film grain by ISO (amount, size): finer for slow film, coarser for fast film. The base look's grain is replaced.
    /// Re-tuned 2026-11-11 for the filmDevelop decode (Apple sharpening x0.50-0.55), on native crops
    /// (.orchestration/looks/RR_GRAIN_2026-11-11.md). Grain is the same on every frame of a roll (measured grain std
    /// 0.063-0.080 log2 at ISO 800 on 5 files), so its flat-texture ratio vs Apple swings with the frame's own texture
    /// (ISO 800: 1.01 on a noisy ISO 200 indoor frame, 2.07 on an ISO 32 sky). No constant grain keeps every frame in
    /// 0.9-1.3; the table aims a typical frame at ~0.95 (100/160) / ~1.1 (400) / ~1.3 (800).
    /// 400 0.38 -> 0.35 (clean daylight frames read noisy); 200 0.28 -> 0.27 keeps a clean lab 400 above any 200.
    /// The 400 -> 800 step is mostly clump size: a bigger cell puts less energy in the fine band, so amount rises too.
    public static func grain(iso: Int, tungsten: Bool = false) -> (amount: Float, size: Float) {
        switch iso {
        case ..<130: return (0.18, 0.050)
        case ..<180: return (0.22, 0.055)
        case ..<300: return (0.27, 0.060)
        case ..<600: return (0.35, 0.070)
        default:     return tungsten ? (0.55, 0.085) : (0.50, 0.080)
        }
    }

    /// Layer-1 arguments on top of `look` (T2 D2): intensity, ISO, grain, decode character, light leak. `stock` is
    /// `FilmStock.resolve(look:arguments:)`, the same merge an app catalog entry goes through.
    public var arguments: LookArguments = LookArguments()

    /// Decode profile (plan §4) from `arguments` (ISO class + `develop` character); plugin `filmDevelop` applies it.
    public var develop: FilmDevelop { FilmDevelop.stockProfile(iso: iso, character: arguments.develop ?? .auto) }

    /// The stock the developer runs: `look` + `arguments` merged by `FilmStock.resolve`. Its name is the id, so the
    /// recipe records the roll stock (not the brand).
    public var stock: FilmStock {
        do {
            var stock = try FilmStock.resolve(look: look, arguments: arguments)
            stock.name = id
            stock.summary = "\(nameVi) · ISO \(iso)\(tungsten ? "T" : "") · \(vibe)"
            return stock
        } catch {
            preconditionFailure("roll stock \(id) does not resolve on look \(look): \(error)")
        }
    }
}

public enum RollStocks {
    /// One entry: names and box ISO, plus its `LookArguments` spelled out (develop character, grain scale, light leak).
    /// `intensity`, `iso` and `tungsten` go into the arguments as given; grain is always the ISO form.
    static func s(_ id: String, _ nameVi: String, _ iso: Int, _ look: String, _ intensity: Float,
                  _ vibe: String, tungsten: Bool = false, develop: LookArguments.DevelopCharacter, grainScale: Float = 1,
                  lightLeak: String? = nil, open: [String] = []) -> RollStock {
        RollStock(id: id, nameVi: nameVi, iso: iso, tungsten: tungsten, look: look, intensity: intensity,
                  vibe: vibe, openQuestions: open,
                  arguments: LookArguments(stockId: id, intensity: intensity, iso: iso, tungsten: tungsten ? true : nil,
                                           grain: .iso(scale: grainScale), lightLeak: lightLeak, develop: develop))
    }

    /// The roll stocks, in the brief's order (§3). 19 of the brief's 21: RR Chuẩn 160 and 800 were cut on 2026-11-11
    /// (same colour as RR Chuẩn 400, grain only; .orchestration/looks/RR_LOOKS_2026-11-11.md).
    public static let all: [RollStock] = [
        s("rr-sao-mai-200", "RR Sao Mai 200", 200, "everydayGreen", 0.70, "everyday warm, medium saturation and contrast",
          develop: .auto, open: ["R3a: if legal wants it safer, rename to RR Ngày 200"]),
        s("rr-sao-hom-400", "RR Sao Hôm 400", 400, "everydayGreen", 0.85, "everyday warm 400, more grain, better in low light",
          develop: .auto, open: ["R3a: if legal wants it safer, rename to RR Chiều 400"]),
        s("rr-mat-200", "RR Mát 200", 200, "pastelCool", 0.80, "cool, light green cast, medium saturation", develop: .auto),
        s("rr-gio-400", "RR Gió 400", 400, "trialCoolFade", 0.85, "cool 400, medium-high saturation, visible grain",
          develop: .auto, open: ["trialCoolFade is still a low-confidence trial look"]),
        s("rr-vang-200", "RR Vàng 200", 200, "goldenDay", 0.85, "honey warm, rich colour, fine grain", develop: .auto),
        s("rr-am-200", "RR Ấm 200", 200, "warmMuted", 0.85, "soft amber-red warm, moderate colour, muted greens and skies", develop: .auto),
        s("rr-ruc-400", "RR Rực 400", 400, "vividFine", 0.75, "warm and saturated all-rounder 400, visible grain", develop: .vivid),
        s("rr-hoai-co-100", "RR Hoài Cổ 100", 100, "sunFade", 0.60, "nostalgic warm, low-medium saturation and contrast, fine grain", develop: .auto),
        s("rr-hoai-co-200", "RR Hoài Cổ 200", 200, "sunFade", 0.70, "nostalgic warm, medium grain", develop: .auto),
        s("rr-lang-kinh-200", "RR Lăng Kính 200", 200, "warmEvening", 0.70, "warm vintage, medium saturation and contrast", develop: .auto),
        s("rr-lang-kinh-400", "RR Lăng Kính 400", 400, "warmEvening", 0.80, "warm vintage 400, more grain", develop: .auto),
        s("rr-la-phong-100", "RR Lá Phong 100", 100, "mapleRed", 0.85, "warm, deep crimson reds with cyan-teal blues and shadows, low-medium contrast, fine grain",
          develop: .auto, lightLeak: "laPhong", open: ["light leak built as plugin lightLeak (needs rollID / rollFrameIndex / rollFrameCount); open numbers listed in WORK_LOG 2026-11-11"]),
        s("rr-nang-100", "RR Nắng 100", 100, "brightTravel", 0.85, "bright sunny daylight, high saturation, clean whites, fine grain", develop: .auto),
        s("rr-ruc-ro-100", "RR Rực Rỡ 100", 100, "vividFine", 0.95, "very saturated, high contrast, strong reds, finest grain", develop: .vivid),
        s("rr-da-mem-160", "RR Da Mềm 160", 160, "softPortrait", 0.85, "pastel warm, low contrast, best skin, fine grain", develop: .portrait),
        s("rr-chan-dung-400", "RR Chân Dung 400", 400, "naturalPortrait", 0.85, "natural warm, medium saturation and contrast, good skin", develop: .portrait),
        s("rr-dem-mem-800", "RR Đêm Mềm 800", 800, "naturalPortrait", 1.0, "warm natural portrait, coarse grain, for low light", develop: .portrait),
        s("rr-den-vang-800t", "RR Đèn Vàng 800T", 800, "tungstenGlow", 0.90, "tungsten night film, halation, teal shadows",
          tungsten: true, develop: .auto),
        s("rr-chuan-400", "RR Chuẩn 400", 400, "cleanLab", 0.85, "clean neutral lab scan, accurate skin, clean whites, medium grain", develop: .auto, grainScale: 0.8),
    ]

    public static let stocks: [FilmStock] = all.map(\.stock)

    /// English names by id (`RollStock.nameEn`).
    static let englishNames: [String: String] = [
        "rr-sao-mai-200": "RR Daylight 200", "rr-sao-hom-400": "RR Dusk 400",
        "rr-mat-200": "RR Cool 200", "rr-gio-400": "RR Cool 400",
        "rr-vang-200": "RR Golden 200", "rr-am-200": "RR Warm 200", "rr-ruc-400": "RR Bold 400",
        "rr-hoai-co-100": "RR Retro 100", "rr-hoai-co-200": "RR Retro 200",
        "rr-lang-kinh-200": "RR Spectrum 200", "rr-lang-kinh-400": "RR Spectrum 400",
        "rr-la-phong-100": "RR Red Leaf 100", "rr-nang-100": "RR Sunny 100", "rr-ruc-ro-100": "RR Vivid 100",
        "rr-da-mem-160": "RR Portrait 160", "rr-chan-dung-400": "RR Portrait 400", "rr-dem-mem-800": "RR Portrait 800",
        "rr-den-vang-800t": "RR Tungsten 800T", "rr-chuan-400": "RR Lab 400",
    ]

    public static func named(_ id: String) -> RollStock? { all.first { $0.id == id } }
}

extension FilmLooks2026 {
    /// Listed, trial or retired generated look by name.
    static func anyStock(named n: String) -> FilmStock? {
        (stocks + trialStocks + retiredStocks).first { $0.name == n }
    }
}

// MARK: - Layer 1: look + arguments (T2 D2)

/// What a stock sets on top of a supported look (`SupportedLooks`). `nil` everywhere = the look's own default.
/// The host app keeps a catalog of stocks as (look id, `LookArguments`); a new stock on an existing look needs no RSP
/// release. Set `RenderSettings.stock = <look id>` and `RenderSettings.lookArguments`; RSP merges them in
/// `FilmStock.resolve(look:arguments:)`, the same merge the built-in `RollStocks` go through.
///
/// JSON shape (synthesised Codable): `{"intensity":0.85,"iso":400,"grain":{"iso":{"scale":0.8}},"develop":"auto"}`.
public struct LookArguments: Codable, Equatable, Sendable {
    /// Film grain. `.iso` takes amount and size from `RollStock.grain(iso:tungsten:)` (needs `iso`) and multiplies the
    /// amount by `scale`; `.explicit` sets both.
    public enum Grain: Codable, Equatable, Sendable {
        case iso(scale: Float)
        case explicit(amount: Float, size: Float)
    }
    /// Halation replacing the look's (`FilmFinish` units).
    public struct Halation: Codable, Equatable, Sendable {
        public var amount: Float
        public var threshold: Float
        public var radius: Float
        public init(amount: Float, threshold: Float, radius: Float) {
            self.amount = amount; self.threshold = threshold; self.radius = radius
        }
    }
    /// Decode character on top of the ISO class (`FilmDevelop.stockProfile`): `vivid` keeps more sharpness,
    /// `portrait` is softer.
    public enum DevelopCharacter: String, Codable, Sendable, CaseIterable {
        case auto, vivid, portrait
    }

    /// Label for recipes and logs only; never changes the render.
    public var stockId: String?
    /// 0...1, replaces the look's default intensity.
    public var intensity: Float?
    /// Box ISO: drives `.iso` grain and the decode profile. nil = the look's own grain and no decode profile (D13).
    public var iso: Int?
    /// Tungsten grain for the ISO class (needs `iso`).
    public var tungsten: Bool?
    public var grain: Grain?
    /// nil = the look's halation.
    public var halation: Halation?
    /// 0...1; nil = the look's vignette.
    public var vignette: Float?
    /// A leak RSP ships (`LookArguments.lightLeaks`); nil = none.
    public var lightLeak: String?
    /// Decode character (needs `iso`); nil with an ISO = `auto`.
    public var develop: DevelopCharacter?

    public init(stockId: String? = nil, intensity: Float? = nil, iso: Int? = nil, tungsten: Bool? = nil, grain: Grain? = nil,
                halation: Halation? = nil, vignette: Float? = nil, lightLeak: String? = nil, develop: DevelopCharacter? = nil) {
        self.stockId = stockId; self.intensity = intensity; self.iso = iso; self.tungsten = tungsten; self.grain = grain
        self.halation = halation; self.vignette = vignette; self.lightLeak = lightLeak; self.develop = develop
    }

    /// Named light leaks RSP ships.
    public static let lightLeaks: [String: LightLeakSpec] = ["laPhong": .laPhong]
    /// ISO range RSP accepts (an app catalog may be stricter).
    public static let isoRange: ClosedRange<Int> = 25...6400
    /// Range of the `.iso` grain multiplier RSP accepts (an app catalog may be stricter).
    public static let grainScaleRange: ClosedRange<Float> = 0...2
}

extension FilmStock {
    /// A supported look (`SupportedLooks`) with `arguments` merged on top. The result is named after the look (generated
    /// LUT caches key on the name). Throws `invalidSettings` for an unsupported look, an out-of-range value, `.iso`
    /// grain / `tungsten` / `develop` without `iso`, or an unknown light leak. Nothing falls back silently.
    public static func resolve(look: String, arguments a: LookArguments) throws -> FilmStock {
        guard SupportedLooks.named(look) != nil, let base = FilmLooks2026.stocks.first(where: { $0.name == look }) else {
            throw RawCoreError.invalidSettings("lookArguments need a supported look; \(look) is not one (SupportedLooks: \(SupportedLooks.all.map(\.id).joined(separator: ", ")))")
        }
        func bad(_ m: String) -> RawCoreError { .invalidSettings("lookArguments\(a.stockId.map { " (\($0))" } ?? "") on \(look): \(m)") }
        if let i = a.intensity, !(0...1).contains(i) { throw bad("intensity must be in 0...1") }
        if let iso = a.iso, !LookArguments.isoRange.contains(iso) {
            throw bad("iso must be in \(LookArguments.isoRange.lowerBound)...\(LookArguments.isoRange.upperBound)")
        }
        if a.iso == nil, a.tungsten != nil { throw bad("tungsten needs iso") }
        if a.iso == nil, a.develop != nil { throw bad("develop needs iso") }
        var finish = base.finish
        switch a.grain {
        case nil: break
        case .iso(let scale)?:
            guard let iso = a.iso else { throw bad("grain .iso needs iso") }
            guard LookArguments.grainScaleRange.contains(scale) else { throw bad("grain scale must be in 0...2") }
            let g = RollStock.grain(iso: iso, tungsten: a.tungsten ?? false)
            finish.grainAmount = g.amount * scale; finish.grainSize = g.size
        case .explicit(let amount, let size)?:
            finish.grainAmount = amount; finish.grainSize = size
        }
        if let h = a.halation {
            finish.halationAmount = h.amount; finish.halationThreshold = h.threshold; finish.halationRadius = h.radius
        }
        if let v = a.vignette { finish.vignette = v }
        if let leak = a.lightLeak {
            guard let spec = LookArguments.lightLeaks[leak] else {
                throw bad("unknown light leak \(leak) (known: \(LookArguments.lightLeaks.keys.sorted().joined(separator: ", ")))")
            }
            finish.lightLeak = spec
        }
        do { try finish.validate() } catch RawCoreError.invalidSettings(let m) { throw bad(m) }
        var stock = FilmStock(name: look, source: base.source, lookIntensity: a.intensity ?? base.lookIntensity, finish: finish,
                              summary: base.summary, allowsSkinProtection: base.allowsSkinProtection,
                              minSkinProtection: base.minSkinProtection)
        stock.lookInput = base.lookInput; stock.lookColorSpace = base.lookColorSpace; stock.logPrimaries = base.logPrimaries
        if let iso = a.iso { stock.develop = FilmDevelop.stockProfile(iso: iso, character: a.develop ?? .auto) }
        return stock
    }
}

extension FilmDevelop {
    /// Decode profile of a stock (plan §4), from its ISO class and character.
    /// - ISO class: <400 sharp x0.55 (floor 0.30), 400...1599 x0.50 and luma NR no higher than Apple's, >=1600 x0.40
    ///   and luma NR at most +0.05.
    /// - Character replaces the ISO class's sharp scale: vivid x0.70, portrait x0.50.
    /// - Tuned 2026-11-11 on native crops (WORK_LOG): x0.25 and below reads as mush on faces and fabric; the plan's
    ///   x0.45 / portrait x0.45 with face −0.10 gave HF ratio 0.57 on mooncake.
    public static func stockProfile(iso: Int, character: LookArguments.DevelopCharacter) -> FilmDevelop {
        var scale: Float, cap: Float?, cls: String
        switch iso {
        case ..<400:  scale = 0.55; cap = nil;  cls = "iso<400"
        case ..<1600: scale = 0.50; cap = 0;    cls = "iso400-1599"
        default:      scale = 0.40; cap = 0.05; cls = "iso>=1600"
        }
        var profile = cls
        switch character {
        case .auto: break
        case .vivid: scale = 0.70; profile += "+vivid"
        case .portrait: scale = 0.50; profile += "+portrait"
        }
        return FilmDevelop(profile: profile, sharpScale: scale, lumaNRMaxDelta: cap)
    }
}
