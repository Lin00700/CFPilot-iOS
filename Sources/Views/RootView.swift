import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var selection: Int = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DeployHomeView()
            }
            .tabItem {
                Label("部署", systemImage: "cloud.sun.rain")
            }
            .tag(0)

            NavigationStack {
                ProberView()
            }
            .tabItem {
                Label("优选", systemImage: "speedometer")
            }
            .tag(1)

            NavigationStack {
                PanelView()
            }
            .tabItem {
                Label("面板", systemImage: "rectangle.on.rectangle.angled")
            }
            .tag(2)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "slider.horizontal.3")
            }
            .tag(3)
        }
        .onAppear {
            configureTabBarAppearance()
        }
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterial)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

/// 页面顶部的题头
struct InkPageHeader: View {
    let title: String
    let subtitle: String
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(InkFont.title(28))
                    .foregroundStyle(Ink.text)
                if let badge {
                    Text(badge)
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.seal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().strokeBorder(Ink.seal.opacity(0.6), lineWidth: 1)
                        )
                }
                Spacer(minLength: 0)
            }
            Text(subtitle)
                .font(InkFont.body(13))
                .foregroundStyle(Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 复制小按钮
struct CopyChip: View {
    let text: String
    let label: String
    @State private var copied = false

    init(text: String, label: String = "复制") {
        self.text = text
        self.label = label
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text(copied ? "已复制" : label)
                    .font(InkFont.body(12))
            }
            .foregroundStyle(copied ? Ink.jade : Ink.seal)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Ink.seal.opacity(0.08))
            )
            .overlay(
                Capsule().strokeBorder(Ink.seal.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 空状态：一枚淡淡的印章 + 一句说明
struct InkEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .strokeBorder(Ink.seal.opacity(0.22), lineWidth: 1)
                    .frame(width: 76, height: 76)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Ink.seal.opacity(0.8))
            }
            Text(title)
                .font(InkFont.title(18))
                .foregroundStyle(Ink.text)
            Text(message)
                .font(InkFont.body(13))
                .foregroundStyle(Ink.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
    }
}
