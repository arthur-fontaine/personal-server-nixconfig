import Foundation

/// A pet on disk: `pet.json` + its spritesheet. The build bundles the server's current pet
/// (`Pet/` in the app, written by app-delivery); the app caches newer ones in the App Group.
public struct PetPackage: Sendable, Equatable {
    public var manifest: PetManifest
    public var spritesheet: URL

    public init(manifest: PetManifest, spritesheet: URL) {
        self.manifest = manifest
        self.spritesheet = spritesheet
    }

    public static func load(directory: URL) -> PetPackage? {
        guard let data = try? Data(contentsOf: directory.appending(path: "pet.json")),
              let manifest = try? JSONDecoder().decode(PetManifest.self, from: data) else { return nil }
        let sheet = directory.appending(path: manifest.spritesheetPath)
        guard FileManager.default.fileExists(atPath: sheet.path) else { return nil }
        return PetPackage(manifest: manifest, spritesheet: sheet)
    }
}

public enum BundledPet {
    public static func load(bundle: Bundle = .main) -> PetPackage? {
        guard let dir = bundle.url(forResource: "Pet", withExtension: nil) else { return nil }
        return PetPackage.load(directory: dir)
    }
}
