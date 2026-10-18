import SwiftUI

@main
struct CareCircleApp: App {
    init() {
        #if DEBUG
        if let path = Bundle.main.url(forResource: "LocalConnection", withExtension: "plist"),
           let data = try? Data(contentsOf: path),
           let profile = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
           let address = profile["serverAddress"], let token = profile["connectionToken"],
           let profileID = profile["profileID"],
           UserDefaults.standard.string(forKey: "careCircleBundledProfileID") != profileID,
           (try? CareCircleAPI.validatedURL(address)) != nil {
            do {
                try ConnectionToken.save(token)
                UserDefaults.standard.set(address, forKey: "careCircleServerAddress")
                UserDefaults.standard.set(profileID, forKey: "careCircleBundledProfileID")
            } catch {
                // A failed secure save leaves connection setup available in the menu.
            }
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        // Local developer launch only. Oracle credentials are never passed to the app.
        let environment = ProcessInfo.processInfo.environment
        if let address = environment["CARECIRCLE_SERVER_ADDRESS"],
           let token = environment["CARECIRCLE_CONNECTION_TOKEN"], token.count >= 32,
           (try? CareCircleAPI.validatedURL(address)) != nil {
            do {
                try ConnectionToken.save(token)
                UserDefaults.standard.set(address, forKey: "careCircleServerAddress")
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
