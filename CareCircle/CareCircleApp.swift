import SwiftUI

@main
struct CareCircleApp: App {
    init() {
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
