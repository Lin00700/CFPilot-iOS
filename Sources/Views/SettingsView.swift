import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var tokenDraft: String = ""
    @State private var showToken: Bool = false
    @State private var savedNotice: String?
    @State private var confirmForget = false

    var body: some View {
        ZStack {
            InkBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InkPageHeader(title: "设置", subtitle: "凭据只放在本机钥匙串，App 不会把它发往任何第三方服务。")

                    tokenCard
                    deploymentCard
                    proberDefaultsCard
                    aboutCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if tokenDraft.isEmpty { tokenDraft = store.token }
        }
        .alert("忘记本机部署记录？", isPresented: $confirmForget) {
            Button("取消", role: .cancel) {}
            Button("删除记录", role: .destructive) {
                store.forgetDeployment()
            }
        } message: {
            Text("只删除这台手机上的记录与面板密码。Cloudflare 上的 Pages 项目、Worker 与 KV 都会保留，你仍可在控制台管理它们。")
        }
    }

    // MARK: - Token

    private var tokenCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                InkSectionTitle(text: "Cloudflare API Token", subtitle: "当前：\(store.maskedToken())")

                InkField {
                    HStack(spacing: 8) {
                        if showToken {
                            TextField("粘贴 API Token", text: $tokenDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("粘贴 API Token", text: $tokenDraft)
                        }
                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .foregroundStyle(Ink.textFaint)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        store.saveToken(tokenDraft)
                        savedNotice = "已存进本机钥匙串"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            savedNotice = nil
                        }
                    } label: {
                        Text("保存 Token")
                    }
                    .buttonStyle(SealButtonStyle())

                    Button {
                        tokenDraft = ""
                        store.saveToken("")
                        savedNotice = "已清除"
                    } label: {
                        Text("清除")
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                if let savedNotice {
                    Text(savedNotice)
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.jade)
                }

                Link(destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!) {
                    Label("管理 API Token", systemImage: "arrow.up.right.square")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.seal)
                }
            }
        }
    }

    // MARK: - 部署记录

    private var deploymentCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                InkSectionTitle(text: "本机部署记录")

                if let record = store.record {
                    VStack(alignment: .leading, spacing: 8) {
                        InkKeyValueRow(label: "面板", value: record.panelURLString)
                        InkKeyValueRow(label: "KV", value: record.kvNamespaceId)
                        InkKeyValueRow(label: "控制面", value: record.controlProject)
                        InkKeyValueRow(label: "数据面", value: record.dataProject)
                        InkKeyValueRow(label: "形态", value: record.mode.label, mono: false)
                        InkKeyValueRow(label: "构建", value: record.build.isEmpty ? "未识别" : record.build)
                    }

                    Button {
                        confirmForget = true
                    } label: {
                        Text("忘记本机记录")
                    }
                    .buttonStyle(GhostButtonStyle())
                } else {
                    Text("这台手机还没有部署记录。")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.textFaint)
                }
            }
        }
    }

    // MARK: - 优选默认

    private var proberDefaultsCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                InkSectionTitle(text: "优选器默认值", subtitle: "只影响「优选」页的初始输入")

                Text("默认探测域名")
                    .font(InkFont.body(12))
                    .foregroundStyle(Ink.textFaint)
                InkField {
                    TextField("留空则用部署记录里的节点域名", text: Binding(
                        get: { store.proberHost },
                        set: { store.updateProberHost($0) }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                }

                HStack {
                    Text("候选数量")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.textSecondary)
                    Spacer(minLength: 0)
                    Stepper("\(store.proberCandidates)", value: Binding(
                        get: { store.proberCandidates },
                        set: { store.updateProberOptions(builtin: store.proberUsesBuiltinRanges, candidates: $0) }
                    ), in: 20...400, step: 20)
                    .font(InkFont.mono(12))
                    .foregroundStyle(Ink.text)
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 10) {
                InkSectionTitle(text: "关于 CFPilot")
                Text("CFPilot-iOS 是 xmwengxing/CFPilot 的独立 iOS 客户端：一键双面部署、真连接优选、内置面板。内核产物运行时从上游 Release 拉取，本仓库只包含 SwiftUI 源码。")
                    .font(InkFont.body(12))
                    .foregroundStyle(Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: URL(string: "https://github.com/xmwengxing/CFPilot")!) {
                    Label("上游项目 xmwengxing/CFPilot", systemImage: "link")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.seal)
                }

                Link(destination: URL(string: "https://github.com/Lin00700/CFPilot-iOS")!) {
                    Label("本工程 CFPilot-iOS", systemImage: "link")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.seal)
                }

                Text("版本 1.0.0 · iOS 17+")
                    .font(InkFont.body(11))
                    .foregroundStyle(Ink.textFaint)
            }
        }
    }
}
