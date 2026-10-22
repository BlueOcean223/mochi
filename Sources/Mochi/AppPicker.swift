import AppKit
import SwiftUI

/// 装在本机的应用，加「忽略的应用」时从这里挑。
struct InstalledApp: Identifiable {
    let id: String  // bundle id
    let name: String
    /// 文件名，英文系统名（中文系统下「备忘录」的文件名是 Notes），搜英文也能搜到。
    let fileName: String
    let url: URL
}

enum InstalledApps {
    /// 和 Raycast 的列表差不多。macOS 26 的「钥匙串访问」在 CoreServices 那个文件夹里，
    /// 不列它的话，默认忽略的钥匙串访问被移除以后就加不回来。装在别处的从「在其他位置找…」选。
    private static var folders: [URL] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
         "/System/Library/CoreServices/Applications"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            + [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    /// 按名字排：中文系统下 `localizedStandardCompare` 就是按拼音，和 Raycast 一样。同一个 bundle id 只留先找到的那个。
    @concurrent
    static func load() async -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for folder in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "app" {
                // /Applications/Safari.app 是指到 Cryptexes 里的符号链接。
                let resolved = url.resolvingSymlinksInPath()
                guard let id = Bundle(url: resolved)?.bundleIdentifier, seen.insert(id).inserted else { continue }
                apps.append(InstalledApp(id: id, name: FileManager.default.displayName(atPath: url.path),
                                         fileName: url.deletingPathExtension().lastPathComponent, url: resolved))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// 点「忽略的应用」右上角的 + 弹出来的列表：打字筛，↑↓ 选，回车加进去，Esc 关。按键在 SettingsWindowController 的按键监听里处理。
struct AppPicker: View {
    @Bindable var model: SettingsModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let rows = model.pickerRows
        let selected = min(model.pickerIndex, rows.count - 1)
        VStack(spacing: 0) {
            TextField("搜索应用…", text: $model.pickerQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 16)
                .frame(height: 44)
                .focused($isSearchFocused)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if rows.count == 1, !model.pickerQuery.isEmpty {
                            Text(verbatim: "没有叫「\(model.pickerQuery)」的应用")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .padding(.horizontal, 9)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if case .other = row, rows.count > 1 {
                                Divider().padding(.horizontal, 9).padding(.vertical, 4)
                            }
                            PickerRowView(row: row, isSelected: index == selected)
                                .id(row.id)
                                .onHover { if $0 { model.pickerIndex = index } }
                                .onTapGesture { model.choosePickerRow(at: index) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: model.pickerIndex) {
                    if rows.indices.contains(selected) { proxy.scrollTo(rows[selected].id) }
                }
            }
        }
        .frame(width: 360, height: 320)
        .onAppear { isSearchFocused = true }
    }
}

private struct PickerRowView: View {
    let row: SettingsModel.PickerRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            switch row {
            case .app(let app):
                Image(nsImage: Icons.app(app.id) ?? NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(app.name)
                    .lineLimit(1)
            case .other:
                Image(systemName: "folder")
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                Text("在其他位置找…")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("选 .app")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(isSelected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}
