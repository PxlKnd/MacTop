import SwiftUI
import WidgetKit

@main
struct MacTopKitApp: App {
    var body: some Scene {
        WindowGroup("MacTop Monitor") {
            VStack(alignment: .leading, spacing: 14) {
                Text("MacTop Monitor").font(.title2.bold())
                Text("So kommt das Widget auf den Schreibtisch:")
                    .font(.headline)
                Text("""
                1. Rechtsklick auf den Schreibtisch → „Widgets bearbeiten…"
                   (oder Widget-Center in der Menüleiste öffnen)
                2. Unten links nach „MacTop Monitor" suchen
                3. Auf den Schreibtisch ziehen — fertig
                """)
                .font(.body.monospaced(false))
                HStack {
                    Button("Widget jetzt aktualisieren") {
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
                Divider()
                Text("Das Live-Desktop-Dashboard bleibt unabhängig davon unter\nMacTopWidget erhalten.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(width: 460, height: 290)
            .onAppear {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
