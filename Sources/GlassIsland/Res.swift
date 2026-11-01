import Foundation
import CoreText

/// Resolves bundled resources both in the SPM development layout and the
/// assembled .app bundle (see scripts/build-app.sh).
enum Res {
    static func url(_ subpath: String) -> URL? {
        let comps = subpath.split(separator: "/").map(String.init)
        guard let file = comps.last else { return nil }
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        let dir = comps.dropLast().joined(separator: "/")
        let dirs: [String?] = dir.isEmpty ? [nil, "Resources"] : [dir, "Resources/" + dir]
        for bundle in [Bundle.main, Bundle.module] {
            for d in dirs {
                if let u = bundle.url(forResource: name, withExtension: ext, subdirectory: d),
                   FileManager.default.fileExists(atPath: u.path) {
                    return u
                }
            }
        }
        return nil
    }

    static func string(_ subpath: String) -> String? {
        url(subpath).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    @MainActor
    static func registerFonts() {
        guard let url = url("fonts/Parisienne-Regular.ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
