import SwiftUI
import UIKit

/// 真连接优选器：真的握手，只留能服务你域名的 IP
struct ProberView: View {
    @EnvironmentObject private var store: SettingsStore
    @StateObject private var vm = ProberViewModel()

    private let countOptions = [40, 80, 150, 300]

    var body: some View {
        ZStack {
            InkBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InkPageHeader(
                        title: "真连接优选",
                        subtitle: "对候选 IP 做真实 TCP + TLS 握手（SNI 用你自己的域名），握手成功才保留 —— 不再有 -1 假延迟。",
                        badge: vm.isRunning ? "探测中" : nil
                    )

                    targetCard
                    sourceCard
                    runCard

                    if !vm.visibleResults.isEmpty {
                        resultCard
                    } else if !vm.results.isEmpty {
                        InkCard {
                            Text("本次没有任何 IP 完成 TLS 握手。")
                                .font(InkFont.body(13))
                                .foregroundStyle(Ink.textFaint)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { vm.prepare(store: store) }
    }

    // MARK: - 目标

    private var targetCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                InkSectionTitle(text: "探测目标", subtitle: "TLS SNI 与 HTTP Host 都用这个域名")

                InkField {
                    TextField("数据面域名，例如 xxx.pages.dev", text: $vm.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                if let record = store.record {
                    HStack(spacing: 8) {
                        Text("用已部署的节点域名")
                            .font(InkFont.body(11))
                            .foregroundStyle(Ink.textFaint)
                        Button(record.nodeHost) {
                            vm.host = record.nodeHost
                        }
                        .font(InkFont.mono(11))
                        .foregroundStyle(Ink.seal)
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("端口")
                            .font(InkFont.body(11))
                            .foregroundStyle(Ink.textFaint)
                        InkField {
                            TextField("443", text: $vm.port)
                                .keyboardType(.numberPad)
                        }
                        .frame(width: 90)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("并发")
                            .font(InkFont.body(11))
                            .foregroundStyle(Ink.textFaint)
                        InkField {
                            Text("10")
                                .foregroundStyle(Ink.textFaint)
                        }
                        .frame(width: 90)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 候选来源

    private var sourceCard: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    InkSectionTitle(text: "候选 IP")
                    Spacer(minLength: 0)
                    Toggle("内置网段", isOn: $vm.useBuiltinRanges)
                        .labelsHidden()
                        .tint(Ink.seal)
                }

                Text(vm.useBuiltinRanges
                     ? "从 Cloudflare 官方公布的 15 个 IPv4 网段里随机采样，尽量分散到不同边缘。"
                     : "按行填 IP 或 CIDR（支持 # 注释），从这些网段里随机采样。")
                    .font(InkFont.body(11))
                    .foregroundStyle(Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("候选数量")
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.textSecondary)
                    Picker("候选数量", selection: $vm.candidateCount) {
                        ForEach(countOptions, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if !vm.useBuiltinRanges {
                    TextEditor(text: $vm.customText)
                        .font(InkFont.mono(11))
                        .foregroundStyle(Ink.text)
                        .scrollContentBackground(.hidden)
                        .frame(height: 120)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Ink.fieldBackground.opacity(0.72))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Ink.cardStroke.opacity(0.30), lineWidth: 1)
                        )
                }
            }
        }
    }

    // MARK: - 执行

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = vm.lastError {
                Text(message)
                    .font(InkFont.body(12))
                    .foregroundStyle(Ink.seal)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
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
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    Text(vm.isRunning ? "握手探测中 \(vm.progressText)" : "开始真连接探测")
                }
            }
            .buttonStyle(SealButtonStyle())
            .disabled(!vm.canStart)
            .opacity(vm.canStart ? 1 : 0.5)

            if !vm.results.isEmpty {
                Text("可用 \(vm.reachableCount) / \(vm.results.count) · 排序按 TLS 握手耗时（这才是客户端实际等待的时间）")
                    .font(InkFont.body(11))
                    .foregroundStyle(Ink.textFaint)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - 结果

    private var resultCard: some View {
        InkCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    InkSectionTitle(text: "结果")
                    Spacer(minLength: 0)
                    Toggle("只看可用", isOn: $vm.onlyReachable)
                        .font(InkFont.body(11))
                        .tint(Ink.seal)
                }

                InkDivider()

                resultHeader

                ForEach(vm.visibleResults) { item in
                    resultRow(index: rowNumber(of: item), item: item)
                    if item.id != vm.visibleResults.last?.id {
                        InkDivider().opacity(0.5)
                    }
                }

                InkDivider()

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = vm.visibleResults.map { $0.ip }.joined(separator: "\n")
                    } label: {
                        Text("复制 IP 列表")
                    }
                    .buttonStyle(GhostButtonStyle())

                    Button {
                        vm.pushToPanel(store: store)
                    } label: {
                        HStack(spacing: 6) {
                            if vm.isSyncing {
                                ProgressView().progressViewStyle(.circular)
                            }
                            Text(vm.isSyncing ? "写入中…" : "写入面板优选池")
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(vm.isSyncing)
                }

                if let message = vm.syncMessage {
                    Text(message)
                        .font(InkFont.body(11))
                        .foregroundStyle(Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var resultHeader: some View {
        HStack(spacing: 6) {
            Text("#").frame(width: 20, alignment: .leading)
            Text("IP").frame(maxWidth: .infinity, alignment: .leading)
            Text("TLS").frame(width: 62, alignment: .trailing)
            Text("TCP").frame(width: 46, alignment: .trailing)
            Text("状态").frame(width: 42, alignment: .trailing)
            Text("机房").frame(width: 44, alignment: .trailing)
        }
        .font(InkFont.body(10))
        .foregroundStyle(Ink.textFaint)
    }

    private func rowNumber(of item: ProbeResult) -> Int {
        (vm.visibleResults.firstIndex(where: { $0.id == item.id }) ?? 0) + 1
    }

    private func resultRow(index: Int, item: ProbeResult) -> some View {
        Button {
            UIPasteboard.general.string = item.ip
        } label: {
            HStack(spacing: 6) {
                Text("\(index)")
                    .font(InkFont.mono(10))
                    .foregroundStyle(Ink.textFaint)
                    .frame(width: 20, alignment: .leading)
                Text(item.ip)
                    .font(InkFont.mono(12))
                    .foregroundStyle(Ink.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.tlsMs > 0 ? "\(item.tlsMs)" : "—")
                    .font(InkFont.mono(12))
                    .foregroundStyle(item.tlsMs > 0 && item.tlsMs < 400 ? Ink.jade : Ink.text)
                    .frame(width: 62, alignment: .trailing)
                Text(item.tcpText)
                    .font(InkFont.mono(11))
                    .foregroundStyle(Ink.textFaint)
                    .frame(width: 46, alignment: .trailing)
                Text(item.statusText)
                    .font(InkFont.mono(11))
                    .foregroundStyle(item.httpStatus >= 400 ? Ink.sealSoft : Ink.textSecondary)
                    .frame(width: 42, alignment: .trailing)
                Text(item.colo.isEmpty ? "—" : item.colo)
                    .font(InkFont.mono(11))
                    .foregroundStyle(Ink.brush)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
    }
}
