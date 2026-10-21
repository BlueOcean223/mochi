import SwiftUI

/// 设置窗口里的内容，只有 requirements.md「设置和隐私」里列的五项。
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var isChoosingApps = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutButton(model: model)
                } label: {
                    Text("呼出快捷键")
                    // 总有一行小字，开始录的时候窗口不跳。
                    if let problem = model.shortcutProblem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text(model.isRecording ? "按下新的组合，Esc 取消" : "点按钮录新的组合")
                    }
                }
                Picker(selection: Binding(get: { model.retention }, set: { model.chooseRetention($0) })) {
                    ForEach(Retention.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("保留时长")
                    Text("置顶的不过期")
                }
                Toggle(isOn: Binding(get: { model.loginItem != .off }, set: { model.setLaunchAtLogin($0) })) {
                    Text("开机启动")
                    if let problem = model.loginProblem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
                if model.loginItem == .needsApproval {
                    LabeledContent {
                        Button("打开登录项") { model.openLoginItems() }
                    } label: {
                        Text("还要在系统设置里允许")
                        Text("系统设置 › 通用 › 登录项与扩展，打开 Mochi")
                    }
                }
            }

            Section {
                LabeledContent {
                    if model.isTrusted {
                        Label("已授权", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("去授权") { model.openAccessibilitySettings() }
                    }
                } label: {
                    Text("辅助功能权限")
                    Text(model.isTrusted ? "回车直接粘贴到前台应用" : "没有它，回车只复制，要自己按 ⌘V")
                }
            }

            Section {
                ForEach(model.ignoredApps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("移除") { model.stopIgnoring(app.id) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("添加应用…") { isChoosingApps = true }
                    .buttonStyle(.borderless)
            } header: {
                Text("忽略的应用")
            } footer: {
                Text("这些应用在前台时复制的东西不记。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 窗口跟着内容一样高；忽略的应用多到窗口太高时改成固定高度，里面滚动。
        .frame(width: 480, height: scrolls ? 720 : nil)
        .fixedSize(horizontal: false, vertical: !scrolls)
        .scrollDisabled(!scrolls)
        .fileImporter(isPresented: $isChoosingApps, allowedContentTypes: [.applicationBundle], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.ignoreApps(at: urls) }
        }
        .fileDialogDefaultDirectory(URL(filePath: "/Applications", directoryHint: .isDirectory))
        .alert(retentionTitle, isPresented: Binding(get: { model.retentionChange != nil }, set: { if !$0 { model.retentionChange = nil } }),
               presenting: model.retentionChange) { change in
            Button(role: .destructive) {
                model.confirmRetentionChange()
            } label: {
                Text(verbatim: "删掉 \(change.count) 条")
            }
            Button("取消", role: .cancel) {}
        } message: { change in
            Text(verbatim: "超过 \(change.retention.title)的 \(change.count) 条记录会马上删掉，置顶的不删。删了找不回来。")
        }
    }

    private var scrolls: Bool { model.ignoredApps.count > 8 }

    private var retentionTitle: String {
        "改成只保留 \(model.retentionChange?.retention.title ?? "")？"
    }
}

/// 点一下开始录，再点一下或者按 Esc 取消。录的时候显示已经按住的修饰键。
private struct ShortcutButton: View {
    let model: SettingsModel

    var body: some View {
        Button {
            model.isRecording ? model.stopRecording() : model.startRecording()
        } label: {
            Text(verbatim: label)
                .frame(minWidth: 72)
        }
        .buttonStyle(.bordered)
        .tint(model.isRecording ? .accentColor : nil)
        .overlay {
            if model.isRecording {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private var label: String {
        guard model.isRecording else { return model.shortcut.description }
        return model.heldModifiers.isEmpty ? "录制中…" : model.heldModifiers
    }
}

private extension Retention {
    var title: String {
        switch self {
        case .week: "7 天"
        case .month: "30 天"
        case .threeMonths: "3 个月"
        case .year: "1 年"
        case .forever: "永久"
        }
    }
}
