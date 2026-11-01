import Foundation

enum IslandMode: String, Codable {
    case island
    case floating
}

struct Config: Codable {
    var vault: String = ""
    var sourcePath: String = ""
    var noteFile: String = ""
    var mode: IslandMode = .island
    var floatingOriginX: Double?
    var floatingOriginY: Double?
    var pinnedOnTop: Bool = false

    init() {}

    // Synthesized Codable would throw on any missing key; tolerate partial
    // config files by falling back to the defaults field by field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vault = try c.decodeIfPresent(String.self, forKey: .vault) ?? ""
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        noteFile = try c.decodeIfPresent(String.self, forKey: .noteFile) ?? ""
        mode = try c.decodeIfPresent(IslandMode.self, forKey: .mode) ?? .island
        floatingOriginX = try c.decodeIfPresent(Double.self, forKey: .floatingOriginX)
        floatingOriginY = try c.decodeIfPresent(Double.self, forKey: .floatingOriginY)
        pinnedOnTop = try c.decodeIfPresent(Bool.self, forKey: .pinnedOnTop) ?? false
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassIsland", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static func load() -> Config {
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        return Config()
    }

    func save() {
        let dir = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    var isConfigured: Bool {
        !sourcePath.isEmpty && FileManager.default.fileExists(atPath: sourcePath)
    }
}
