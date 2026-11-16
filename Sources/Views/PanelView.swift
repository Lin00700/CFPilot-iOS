import SwiftUI
import WebKit
import UIKit

/// 内置面板浏览器（WKWebView）
struct PanelWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var reloadToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.load(URLRequest(url: url))
        context.coordinator.lastReload = reloadToken
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReload != reloadToken {
            context.coordinator.lastReload = reloadToken
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PanelWebView
        var lastReload: Int = 0

        init(_ parent: PanelWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}

/// 面板页：直接用内置浏览器打开已部署的 CFPilot 管理面板
struct PanelView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var isLoading = true
    @State private var reloadToken = 0
    @State private var showPassword = false

    var body: some View {
        ZStack {
            InkBackground(showMountains: false)

            if let record = store.record, let url = record.panelURL {
                VStack(spacing: 0) {
                    credentialStrip(record)
                    Divider().opacity(0.3)
                    ZStack(alignment: .top) {
                        PanelWebView(url: url, isLoading: $isLoading, reloadToken: $reloadToken)
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(Ink.seal)
                        }
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        InkPageHeader(title: "面板", subtitle: "部署完成后，这里会直接打开你自己的 CFPilot 管理面板。")
                        InkCard {
                            InkEmptyState(
                                symbol: "rectangle.on.rectangle.angled",
                                title: "还没有部署实例",
                                message: "先到「部署」页跑一次一键部署，拿到面板地址与密码后，这个页面会自动接上。"
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func credentialStrip(_ record: DeploymentRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                InkStatusDot(color: Ink.jade)
                Text(record.controlSubdomain)
                    .font(InkFont.mono(11))
                    .foregroundStyle(Ink.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.seal)
                }
                .buttonStyle(.plain)
                CopyChip(text: record.panelURLString, label: "地址")
            }

            HStack(spacing: 8) {
                Text("面板密码")
                    .font(InkFont.body(11))
                    .foregroundStyle(Ink.textFaint)
                Text(showPassword ? record.panelPassword : String(repeating: "•", count: min(12, record.panelPassword.count)))
                    .font(InkFont.mono(12))
                    .foregroundStyle(Ink.text)
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.textFaint)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                CopyChip(text: record.panelPassword, label: "密码")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Ink.card.opacity(0.9))
    }
}
