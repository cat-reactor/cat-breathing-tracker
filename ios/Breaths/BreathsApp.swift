import SwiftUI
import SwiftData

@main
struct BreathsApp: App {
    let container: ModelContainer = {
        let schema = Schema([Reading.self])
        // With an iCloud container in the app's entitlements, SwiftData syncs automatically;
        // without one it simply stores on the device.
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Never wipe the store to recover: stop instead, so no data is lost.
            fatalError("Couldn't open the readings store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}

struct ContentView: View {
    @AppStorage(Prefs.appearance) private var appearance: Appearance = .system

    var body: some View {
        TabView {
            CountView()
                .tabItem { Label("Count", systemImage: "timer") }
            LogView()
                .tabItem { Label("Log", systemImage: "list.bullet") }
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .preferredColorScheme(appearance == .light ? .light : appearance == .dark ? .dark : nil)
    }
}
