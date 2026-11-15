import SwiftUI
import PhotosUI
import UIKit

enum AppVersion {
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
    static var display: String { "v\(short) (\(build))" }
}

struct MainView: View {
    @StateObject private var engine = CastEngine()
    @State private var presetIndex = 0
    @State private var host = "192.168.1.13"
    @State private var duplicateKeyframes = false
    @State private var chunk1400 = false
    @State private var gopTen = false
    @State private var pingOnly = false
    @State private var scanning = false
    @State private var tcpScanning = false
    @State private var probing = false
    @State private var scanSummary = ""
    @State private var diagText = Diag.tail(16)
    @State private var localIP = "-"
    @State private var pickedItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                // 版本横幅放最顶上，打开就能看到：装没装对包，一眼分辨
                Section {
                    HStack {
                        Text("v\(AppVersion.short) (\(AppVersion.build))")
                            .font(.title2)
                            .bold()
                            .monospacedDigit()
                        Spacer()
                        Text("显示 1.0 = 旧包（会闪退）")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("仪表预设") {
                    Picker("预设", selection: $presetIndex) {
                        ForEach(Array(DashboardPreset.all.enumerated()), id: \.element.id) { index, preset in
                            Text(preset.title).tag(index)
                        }
                    }
                    TextField("仪表 IP", text: $host)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    Text("本机 Wi-Fi 地址：\(localIP)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("关键前提：仪表必须已由九号自己的巡航逻辑进入投屏接收态（官方 App 车辆页 → 仪表投屏导航 → 投屏导航，等仪表出地图）。然后**从后台强退九号出行**（上滑划掉）——它活着就会占住本机 5012/5013 端口并持续心跳，我们的包根本发不出去（状态里出现「端口被占」就是这种情况）。iPhone 连上仪表热点后，IP 填热点详情页「路由器」那行，别填本机地址。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("画面来源") {
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Label(pickedImage == nil ? "选择图片投屏" : "更换图片",
                              systemImage: "photo.on.rectangle.angled")
                    }
                    if let pickedImage {
                        HStack(spacing: 12) {
                            Image(uiImage: pickedImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 48)
                                .clipped()
                                .cornerRadius(6)
                            Text("\(Int(pickedImage.size.width))×\(Int(pickedImage.size.height))，将按预设分辨率等比缩放")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        Button("清除图片（回到测试图）", role: .destructive) {
                            self.pickedImage = nil
                            self.pickedItem = nil
                            engine.setPhoto(nil)
                        }
                    }
                    Text("没选图片时发内置测试图（彩条 + 绿滑块 + 帧号）。图片是静态的，会按帧率持续重发，仪表上看到的是一张定住的图。视频和摄像头投屏放下一版。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("找不到 IP？按 ①②③ 来") {
                    Button {
                        fillGateway()
                    } label: {
                        Label("① 填入网关 .1（热点由车机发 DHCP，网关通常就是它）",
                              systemImage: "1.circle")
                    }
                    Button {
                        runProbe()
                    } label: {
                        Label(probing ? "体检中…" : "② 体检当前 IP（TCP 端口 + RTCP 5013）",
                              systemImage: "2.circle")
                    }
                    .disabled(probing)
                    Button {
                        runTcpScan()
                    } label: {
                        Label(tcpScanning ? "端口扫描中…（约 8 秒）" : "③ 扫全段端口（8443/80/443/5000…）",
                              systemImage: "3.circle")
                    }
                    .disabled(tcpScanning)
                    Button {
                        runScan()
                    } label: {
                        Label(scanning ? "RTCP 扫描中…（约 2 秒）" : "扫全段 RTCP 5013（需仪表在接收态）",
                              systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(scanning)
                    if !scanSummary.isEmpty {
                        Text(scanSummary)
                            .font(.footnote)
                            .monospaced()
                    }
                    Text("说明：8443 只是车机上常见的网页端口之一，不同车型/固件开的端口不一样（也有 80、443、5000、8080，甚至全关）。真正确定的投屏通道只有 UDP 5012/5013，来自官方 APK 逆向。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("投屏（协议已对齐官方 APK 与 iOS 逆向）") {
                    Toggle("关键帧重发（默认关：翻倍占带宽）", isOn: $duplicateKeyframes)
                    Toggle("分片 1400 字节（关 = 1380，APK 值）", isOn: $chunk1400)
                    Toggle("关键帧每 10 帧（关＝每 1 秒）", isOn: $gopTen)
                    Toggle("只发 ping（不编码，用于排查闪退）", isOn: $pingOnly)
                    Button {
                        engine.start(preset: DashboardPreset.all[presetIndex],
                                      host: host,
                                      duplicateKeyframes: duplicateKeyframes,
                                      packetSize: chunk1400 ? 1400 : 1380,
                                      gop: gopTen ? 10 : Int(DashboardPreset.all[presetIndex].fps),
                                      pingOnly: pingOnly)
                    } label: {
                        Label(pingOnly ? "开始（仅 ping）" : "开始投屏（测试图）",
                              systemImage: "play.rectangle.fill")
                    }
                    .disabled(engine.isRunning)
                    Button(role: .destructive) {
                        engine.stop()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                }

                Section("状态") {
                    Text(engine.statusText)
                    Text("已发送 \(engine.sentFrames) 帧 / \(engine.sentPackets) 包")
                        .monospacedDigit()
                    Text(engine.rtcpPongCount > 0
                         ? "RTCP 回应 \(engine.rtcpPongCount) 次 · 往返 \(max(0, engine.lastRTTMs))ms"
                         : "RTCP 尚无回应（等 2 秒以上）")
                        .monospacedDigit()
                        .foregroundColor(engine.rtcpPongCount > 0 ? .green : .secondary)
                    if !engine.dashboardReport.isEmpty {
                        Text(engine.dashboardReport)
                            .font(.footnote)
                            .foregroundColor(.blue)
                    }
                }

                Section("诊断（上次运行到哪一步）") {
                    Text(diagText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    HStack {
                        Button("刷新") { diagText = Diag.tail(20) }
                        Spacer()
                        Button("清空", role: .destructive) {
                            Diag.reset()
                            diagText = Diag.tail(4)
                        }
                    }
                    .font(.footnote)
                }

                Section("协议要点（逆向自官方 APK）") {
                    Text("视频 RTP 20 字节扩展头 · PT 32 · 1380 字节分片")
                    Text("时间戳毫秒 · 每帧带 SPS/PPS · 关键帧每秒 1 个")
                    Text("RTCP ping/pong 每秒 1 次（20 字节）")
                    Text("本机端口绑定 5012/5013")
                }

                Section {
                    Text("版本 \(AppVersion.display)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Ninebot Cast")
            .onAppear {
                localIP = LanScanner.localIPv4() ?? "未连 Wi-Fi"
                diagText = Diag.tail(16)
                Diag.log("MainView 出现，版本 \(AppVersion.display)")
            }
            .onChange(of: pickedItem) { item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    await MainActor.run {
                        pickedImage = image
                        engine.setPhoto(image)
                    }
                }
            }
        }
    }

    private func fillGateway() {
        guard let gateway = LanScanner.gatewayGuess() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        host = gateway
        scanSummary = "已填入网关 \(gateway)（车机热点自己发 DHCP，网关通常就是它）。\n填好点「② 体检」验一下，再开始投屏。"
    }

    private func runProbe() {
        let ip = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            scanSummary = "先填一个 IP 再体检"
            return
        }
        guard ip != localIP else {
            scanSummary = "这是本机地址（\(ip)），换仪表的 IP"
            return
        }
        probing = true
        scanSummary = "体检 \(ip) …（端口 + RTCP，约 3 秒）"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LanScanner.probe(ip: ip)
            DispatchQueue.main.async {
                probing = false
                var lines: [String] = []
                if result.openPorts.isEmpty {
                    lines.append("TCP：常见端口都没开")
                } else {
                    lines.append("TCP 开放：\(result.openPorts.map { String($0) }.joined(separator: ", "))")
                }
                lines.append(result.rtcpPong
                             ? "RTCP 5013：有 pong（\(result.rttMs)ms）"
                             : "RTCP 5013：无回应（不在接收态，或 IP 不对）")
                if !result.pongHex.isEmpty {
                    lines.append(result.pongHex)
                }
                scanSummary = lines.joined(separator: "\n")
            }
        }
    }

    private func runTcpScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        tcpScanning = true
        scanSummary = "扫 \(prefix).1-254 的 8443/80/443/5000/8080/8000/9000 …"
        LanScanner.tcpScan(prefix: prefix) { ip in
            host = ip
            scanSummary = "发现有开放端口：\(ip)（已回填）"
        } completion: { hits in
            tcpScanning = false
            if hits.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机开放这些端口。\n换「① 网关 .1」或「扫 RTCP 5013」试试——端口只是线索，投屏通道是 UDP 5012/5013。"
            } else {
                scanSummary = hits
                    .map { "\($0.ip)  端口 \($0.ports.map { String($0) }.joined(separator: "/"))" }
                    .joined(separator: "\n")
            }
        }
    }

    private func runScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        scanning = true
        scanSummary = "扫描 \(prefix).1-254 的 5013（含广播探测）…"
        LanScanner.scan(prefix: prefix) { hit in
            // 第一个回应的主机直接回填
            host = hit.ip
            scanSummary = "先回应的：\(hit.ip) \(hit.rttMs)ms\n\(hit.replyHex)"
        } completion: { hits in
            scanning = false
            if hits.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机在 5013 回应（本机已排除）。\n仪表多半还没进入投屏接收态——先在仪表/官方 App 里进接收态，再扫一次。"
            } else {
                scanSummary = hits.map { "\($0.ip)  \($0.rttMs)ms  ×\($0.replyCount)  \($0.replyHex)" }
                    .joined(separator: "\n")
            }
        }
    }
}
