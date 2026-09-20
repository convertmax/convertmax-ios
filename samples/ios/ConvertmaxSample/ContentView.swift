import SwiftUI
import Convertmax

struct ContentView: View {
    @State private var sdk = Convertmax(configuration: .init(writeKey: "public", appID: "demo-ios"))
    @State private var log = "Consent starts unknown. Grant it, then identify, track, observe a purchase, or flush."

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text(log).font(.body)
                Button("Grant consent") { Task { await sdk.setConsent(.granted); log = "consent=granted" } }
                Button("Identify") { Task { await sdk.identify("account-a"); log = "identify account-a" } }
                Button("Track signup") {
                    Task { log = await sdk.track("signup").map { "track signup userId=\($0.userId ?? "nil")" } ?? "track dropped (consent?)" }
                }
                Button("Screen home") {
                    Task { log = await sdk.screen("home") == nil ? "screen dropped (consent?)" : "screen home" }
                }
                Button("Observe purchase") {
                    Task { log = await sdk.revenue(transactionReference: "txn-1", amount: "4.99", currency: "USD") == nil ? "purchase dropped" : "purchase_observed queued" }
                }
                Button("Flush queue") {
                    Task { let d = await sdk.diagnostics(); _ = await sdk.flush(); log = "flushed \(d.queued) queued events locally" }
                }
                Button("Reset") { Task { await sdk.reset(); log = "reset identity" } }
                Spacer()
            }
            .padding()
            .navigationBarTitle("Convertmax sample")
        }
    }
}
