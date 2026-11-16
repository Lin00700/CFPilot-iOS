import SwiftUI

/// 部署页：有记录时显示实例状态，没有时引导一键部署
struct DeployHomeView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var showWizard = false

    var body: some View {
        ZStack {
            InkBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InkPageHeader(
                        title: "CFPilot",
                        subtitle: "一键双面部署 · 控制面 Pages + 数据面 Pages/Workers，同一个 KV 互通。",
                        badge: store.record == nil ? "未部署" : "已部署"
                    )

                    if let record = store.record {
                        deployedCard(record)
                        actionsCard(record)
                    } else {
                        onboardingCard
                    }

                    Text("部署流程与 xmwengxing/CFPilot 官方 CLI 一致：先建项目并配好 KV 与环境变量，再部署数据面，最后部署控制面并回写清单。")
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.textFaint)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showWizard) {
            DeployWizardView(isPresented: $showWizard)
                .environmentObject(store)
        }
    }

    // MARK: - 已部署

    private func deployedCard(_ record: DeploymentRecord) -> some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    InkStatusDot(color: Ink.jade)
                    Text("实例在线")
                        .font(InkFont.title(15))
                        .foregroundStyle(Ink.text)
                    Spacer(minLength: 0)
                    Text(record.mode == .pages ? "Pages 数据面" : "Workers 数据面")
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.textFaint)
                }

                InkDivider()

                VStack(alignment: .leading, spacing: 8) {
                    InkKeyValueRow(label: "面板地址", value: record.panelURLString, accent: Ink.brush)
                    InkKeyValueRow(label: "面板密码", value: record.panelPassword, accent: Ink.seal)
                    InkKeyValueRow(label: "节点域名", value: record.nodeHost)
                    InkKeyValueRow(label: "账号", value: record.accountName)
                    InkKeyValueRow(label: "控制面", value: record.controlProject)
                    InkKeyValueRow(label: "数据面", value: record.dataProject)
                }

                HStack(spacing: 10) {
                    CopyChip(text: record.panelURLString, label: "复制地址")
                    CopyChip(text: record.panelPassword, label: "复制密码")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func actionsCard(_ record: DeploymentRecord) -> some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                InkSectionTitle(text: "接下来", subtitle: "更新部署会沿用已有的 UUID / WS 路径 / 面板密码")
                Button {
                    showWizard = true
                } label: {
                    Label("更新部署 / 重新部署", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SealButtonStyle())

                if let url = record.panelURL {
                    Link(destination: url) {
                        Label("在面板里管理节点与订阅", systemImage: "safari")
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                HStack(spacing: 6) {
                    Text("内核构建")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.textFaint)
                    Text(record.build.isEmpty ? "未识别" : record.build)
                        .font(InkFont.mono(12))
                        .foregroundStyle(Ink.textSecondary)
                    Spacer(minLength: 0)
                    Text(record.deployedAt.formatted(date: .numeric, time: .shortened))
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.textFaint)
                }
            }
        }
    }

    // MARK: - 未部署

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            InkCard {
                VStack(alignment: .leading, spacing: 12) {
                    InkSectionTitle(text: "三步上线", subtitle: "全部在 App 里完成，不需要电脑")
                    step(index: "壹", title: "填 Cloudflare 凭据", detail: "API Token（含 Account Settings / Pages / Workers KV 权限）+ Account ID。Token 只存进本机钥匙串。")
                    step(index: "贰", title: "一键双面部署", detail: "自动建独立 KV、建控制面与数据面项目、配环境变量、上传内核、回写清单。")
                    step(index: "叁", title: "拿面板地址与密码", detail: "部署完成直接显示面板 URL 与密码，可在「面板」页用内置浏览器打开。")
                }
            }

            Button {
                showWizard = true
            } label: {
                Label("开始一键部署", systemImage: "checkmark.seal")
            }
            .buttonStyle(SealButtonStyle())
        }
    }

    private func step(index: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(index)
                .font(InkFont.title(15))
                .foregroundStyle(Ink.seal)
                .frame(width: 26, height: 26)
                .background(
                    Circle().strokeBorder(Ink.seal.opacity(0.35), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(InkFont.title(14))
                    .foregroundStyle(Ink.text)
                Text(detail)
                    .font(InkFont.body(12))
                    .foregroundStyle(Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
