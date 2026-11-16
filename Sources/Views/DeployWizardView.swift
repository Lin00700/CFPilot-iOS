import SwiftUI

/// 一键双面部署向导
struct DeployWizardView: View {
    @EnvironmentObject private var store: SettingsStore
    @Binding var isPresented: Bool
    @StateObject private var vm = DeployViewModel()

    init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
    }

    var body: some View {
        NavigationStack {
            ZStack {
                InkBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        credentialCard
                        modeCard
                        optionsCard
                        runCard

                        if !vm.logs.isEmpty {
                            logCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 30)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(vm.finishedRecord == nil ? "一键部署" : "部署完成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { isPresented = false }
                        .foregroundStyle(Ink.textSecondary)
                }
            }
        }
        .onAppear { vm.prepare(store: store) }
    }

    // MARK: - 凭据

    private var credentialCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                InkSectionTitle(text: "Cloudflare 凭据", subtitle: "只写本机钥匙串，不上传任何服务器")

                Text("API Token")
                    .font(InkFont.body(12))
                    .foregroundStyle(Ink.textFaint)
                InkField {
                    SecureField("粘贴 API Token", text: $vm.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Text("Account ID（可留空，默认取 Token 下的第一个账号）")
                    .font(InkFont.body(12))
                    .foregroundStyle(Ink.textFaint)
                InkField {
                    TextField("32 位账号 ID", text: $vm.accountId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                }

                HStack(spacing: 10) {
                    Button {
                        vm.fetchAccounts()
                    } label: {
                        HStack(spacing: 6) {
                            if vm.isFetchingAccounts {
                                ProgressView().progressViewStyle(.circular)
                            }
                            Text(vm.isFetchingAccounts ? "读取中…" : "读取 Token 下的账号")
                        }
                        .font(InkFont.body(12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.seal)
                    .disabled(vm.isFetchingAccounts)

                    if !vm.accounts.isEmpty {
                        Menu {
                            ForEach(vm.accounts) { account in
                                Button(account.name + " · " + String(account.id.prefix(8))) {
                                    vm.accountId = account.id
                                }
                            }
                        } label: {
                            Text("共 \(vm.accounts.count) 个账号")
                                .font(InkFont.body(12))
                                .foregroundStyle(Ink.brush)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let accountError = vm.accountError {
                    Text(accountError)
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.seal)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Token 需要的权限：")
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.textSecondary)
                    Text("Account / Account Settings / Read\nAccount / Pages / Edit\nAccount / Workers KV Storage / Edit\n（数据面选 Workers 时再加 Workers Scripts / Edit）")
                        .font(InkFont.mono(11))
                        .foregroundStyle(Ink.textFaint)
                }
                .padding(.top, 2)

                Link(destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!) {
                    Label("去 Cloudflare 创建 Token", systemImage: "arrow.up.right.square")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.seal)
                }
            }
        }
    }

    // MARK: - 部署形态

    private var modeCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                InkSectionTitle(text: "数据面形态", subtitle: "控制面永远部署在 Pages")

                Picker("数据面形态", selection: $vm.mode) {
                    ForEach(DataPlaneMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(vm.mode.detail)
                    .font(InkFont.body(12))
                    .foregroundStyle(Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                if vm.mode == .workers {
                    Text("数据面节点域名（可选）")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.textFaint)
                    InkField {
                        TextField("例如 w1.example.com", text: $vm.dataHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    Text("填了它，App 会把控制面的 DATA_HOST 指到这个域名；但绑定需要你到 Cloudflare 控制台自己加 —— 工具不动你的 DNS。")
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 选项

    private var optionsCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                InkSectionTitle(text: "部署选项")

                Toggle(isOn: $vm.enableTrojan) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 Trojan")
                            .font(InkFont.body(14))
                            .foregroundStyle(Ink.text)
                        Text("与 VLESS 共用同一个 WS 入口")
                            .font(InkFont.body(11))
                            .foregroundStyle(Ink.textFaint)
                    }
                }
                .tint(Ink.seal)

                Toggle(isOn: $vm.enableXhttp) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 XHTTP")
                            .font(InkFont.body(14))
                            .foregroundStyle(Ink.text)
                        Text("内核按需把 HTTP/2/3 流量转成 XHTTP 隧道")
                            .font(InkFont.body(11))
                            .foregroundStyle(Ink.textFaint)
                    }
                }
                .tint(Ink.seal)

                if store.record != nil {
                    Toggle(isOn: $vm.keepCredentials) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("沿用旧凭据")
                                .font(InkFont.body(14))
                                .foregroundStyle(Ink.text)
                            Text("UUID / WS 路径 / 面板密码不变，客户端订阅地址不会失效")
                                .font(InkFont.body(11))
                                .foregroundStyle(Ink.textFaint)
                        }
                    }
                    .tint(Ink.seal)

                    Toggle(isOn: $vm.freshDeploy) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全新部署（新建 KV）")
                                .font(InkFont.body(14))
                                .foregroundStyle(Ink.text)
                            Text("不复用旧 KV；旧实例需要你到控制台自行清理")
                                .font(InkFont.body(11))
                                .foregroundStyle(Ink.textFaint)
                        }
                    }
                    .tint(Ink.seal)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("项目名（可留空，默认随机无特征名）")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.textFaint)
                    HStack(spacing: 8) {
                        InkField {
                            TextField("控制面", text: $vm.controlProject)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        InkField {
                            TextField("数据面", text: $vm.dataProject)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 执行

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let record = vm.finishedRecord {
                resultCard(record)
            }

            if let message = vm.failureText {
                InkCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            InkStatusDot(color: Ink.seal)
                            Text("部署中止")
                                .font(InkFont.title(14))
                                .foregroundStyle(Ink.text)
                        }
                        Text(message)
                            .font(InkFont.body(12))
                            .foregroundStyle(Ink.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

            Button {
                vm.start(store: store)
            } label: {
                HStack(spacing: 8) {
                    if vm.isRunning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.seal")
                    }
                    Text(vm.isRunning ? "部署中…" : (store.record == nil ? "开始一键部署" : "开始更新部署"))
                }
            }
            .buttonStyle(SealButtonStyle())
            .disabled(!vm.canStart)
            .opacity(vm.canStart ? 1 : 0.5)

            if vm.isRunning {
                Text("部署期间请不要锁屏或切到后台。Pages 部署需要 30~90 秒。")
                    .font(InkFont.body(11))
                    .foregroundStyle(Ink.textFaint)
            }
        }
    }

    private func resultCard(_ record: DeploymentRecord) -> some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    InkStatusDot(color: Ink.jade)
                    Text("部署完成")
                        .font(InkFont.title(16))
                        .foregroundStyle(Ink.text)
                    Spacer(minLength: 0)
                }
                InkDivider()
                InkKeyValueRow(label: "面板地址", value: record.panelURLString, accent: Ink.brush)
                InkKeyValueRow(label: "面板密码", value: record.panelPassword, accent: Ink.seal)
                InkKeyValueRow(label: "节点域名", value: record.nodeHost)
                InkKeyValueRow(label: "UUID", value: record.uuid)
                InkKeyValueRow(label: "WS 路径", value: record.wsPath)
                HStack(spacing: 10) {
                    CopyChip(text: record.panelURLString, label: "复制地址")
                    CopyChip(text: record.panelPassword, label: "复制密码")
                    Spacer(minLength: 0)
                }
                Button {
                    isPresented = false
                } label: {
                    Text("回到首页")
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }

    // MARK: - 日志

    private var logCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    InkSectionTitle(text: "部署日志")
                    Spacer(minLength: 0)
                    Text("\(vm.logs.count) 条")
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.textFaint)
                }
                InkDivider()
                ForEach(vm.logs) { entry in
                    logRow(entry)
                }
            }
        }
    }

    private func logRow(_ entry: DeployLogEntry) -> some View {
        let color: Color
        switch entry.level {
        case .info: color = Ink.brush
        case .success: color = Ink.jade
        case .warning: color = Ink.sealSoft
        case .failure: color = Ink.seal
        }

        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(InkFont.body(13))
                    .foregroundStyle(Ink.text)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(InkFont.mono(11))
                        .foregroundStyle(Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
