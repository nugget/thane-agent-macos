import SwiftUI
import WebKit

struct DashboardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let url = appState.dashboardURL {
            WebView(url: url)
        } else {
            ContentUnavailableView {
                Label("No Server Available", systemImage: "server.rack")
            } description: {
                Text("Start a local server or connect to a remote server to open the dashboard.")
            }
        }
    }
}

// MARK: - WKWebView wrapper

private struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let current = nsView.url else {
            nsView.load(URLRequest(url: url))
            return
        }
        // Reload only if the base origin changed (ignore in-page navigation)
        if current.host != url.host || current.port != url.port || current.scheme != url.scheme {
            nsView.load(URLRequest(url: url))
        }
    }
}
