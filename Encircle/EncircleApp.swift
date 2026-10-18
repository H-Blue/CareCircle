import SwiftUI

@main
struct EncircleApp: App {
    init() {
        // Preserve settings from existing installations during the product rename.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "encircleBrandMigrationCompleted") {
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("careCircle") {
                let renamed = "encircle" + key.dropFirst("careCircle".count)
                if defaults.object(forKey: renamed) == nil { defaults.set(value, forKey: renamed) }
            }
            defaults.set(true, forKey: "encircleBrandMigrationCompleted")
        }
        #if DEBUG
        if let path = Bundle.main.url(forResource: "LocalConnection", withExtension: "plist"),
           let data = try? Data(contentsOf: path),
           let profile = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
           let address = profile["serverAddress"], let token = profile["connectionToken"],
           let profileID = profile["profileID"],
           UserDefaults.standard.string(forKey: "encircleBundledProfileID") != profileID,
           (try? EncircleAPI.validatedURL(address)) != nil {
            do {
                try ConnectionToken.save(token)
                UserDefaults.standard.set(address, forKey: "encircleServerAddress")
                UserDefaults.standard.set(profileID, forKey: "encircleBundledProfileID")
            } catch {
                // A failed secure save leaves connection setup available in the menu.
            }
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        // Local developer launch only. Oracle credentials are never passed to the app.
        let environment = ProcessInfo.processInfo.environment
        if let address = environment["ENCIRCLE_SERVER_ADDRESS"],
           let token = environment["ENCIRCLE_CONNECTION_TOKEN"], token.count >= 32,
           (try? EncircleAPI.validatedURL(address)) != nil {
            do {
                try ConnectionToken.save(token)
                UserDefaults.standard.set(address, forKey: "encircleServerAddress")
            } catch {
                // Settings remains available if the simulator Keychain cannot be updated.
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
    }
}
