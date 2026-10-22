<p align="center"><img src="docs/images/icon.png" width="128" height="128" alt=""></p>

<h1 align="center">Mochi</h1>

<p align="center">只做剪切板历史的 macOS 小工具。</p>

<p align="center"><a href="README.md">English</a> · 简体中文</p>

Mochi 记下你复制过的文字、图片和文件，按一个快捷键就能找回来。面板和快捷键照 Raycast 的剪切板历史（Clipboard History）做，用惯了 Raycast 的话，用法一样。原生 Swift 应用（AppKit 加 SwiftUI），没有第三方依赖，闲着时占内存 15 MB 左右。

![Mochi 的面板](docs/images/panel-light.png)

## 功能

- **⌃⌘V 呼出**（可以改）。面板浮在正在用的应用上面，不抢它的焦点；出现在鼠标所在的屏幕上，全屏应用上也能呼出。
- **搜索和筛选**。打字搜文字和文件名；按类型筛（⌘P）：文本、图片、文件、链接、邮箱、颜色。按置顶、今天、昨天、本周、更早分组。
- **预览**：全文、图片、文件、颜色色块，还有来源应用、大小、复制时间。
- **粘贴**到刚才在用的应用（↵）、只复制（⌘↵）、粘贴且不关闭面板（⌥↵）、粘贴为纯文本（⌃⌘↵）、选一种存下的格式粘贴，比如 RTF、HTML（⌥⌘↵）。设置里可以把 ↵ 改成复制。
- **⌘K 操作面板**，右键一行也能打开：打开链接或文件、用其他应用打开、在 Finder 中显示、Quick Look、编辑文字、改名、置顶和调整置顶顺序、删除、删除最近几分钟的、清空。
- **⌘1 … ⌘0** 直接对前十条做回车的操作；按住 ⌘ 显示数字。可以把一条拖到别的应用里。
- **按顺序粘贴**：另一个全局快捷键，每按一次粘贴下一条更早的记录，从最新的一条开始。
- **隐私**。标了「机密」「临时」的内容（密码管理器会这么标）一律不记。可以指定忽略的应用，默认忽略钥匙串访问和「密码」。可以暂停记录。默认保留 3 个月，可以选 1 小时到永久。剪切板历史不会离开你的 Mac，Mochi 唯一的联网是下面的检查更新。
- **更新**。Mochi 每天问一次 GitHub 有没有新版本，设置里可以关。有新版本时点「更新」，Mochi 下载、确认是同一张证书签的、替换自己、重启。

![⌘K 操作面板](docs/images/actions-dark.png)

## 快捷键

| 按键 | 操作 |
| --- | --- |
| ⌃⌘V | 呼出、收起面板 |
| ↑ ↓ · ⌘↑ ⌘↓ | 上下移动 · 跳到上一组、下一组 |
| ↵ | 粘贴到前台应用 |
| ⌘↵ | 复制 |
| ⌥↵ | 粘贴且不关闭面板 |
| ⌃⌘↵ | 粘贴为纯文本 |
| ⌥⌘↵ | 选格式粘贴 |
| ⌘K | 操作面板 |
| ⌘P | 按类型筛选 |
| ⌘. | 置顶、取消置顶 |
| ⌥⌘↑ ⌥⌘↓ | 在置顶里上移、下移 |
| ⌘E · ⇧⌘E | 编辑文字 · 改名 |
| ⌘O | 打开链接或文件 |
| ⇧⌘O | 在 Finder 中显示 |
| ⌘Y | Quick Look |
| ⌃X | 删除 |
| ⇧⌘X | 删除最近几分钟的 |
| ⌃⇧X | 清空（置顶的留着） |
| ⌘1 … ⌘0 | 对第 1 到第 10 条做回车的操作 |
| ⌘, | 设置 |
| ⌘Q | 退出 Mochi |
| Esc | 先清空搜索词，再收起面板 |

## 系统要求

- macOS 26 或更新。
- 辅助功能权限：Mochi 要替你按 ⌘V。没有它的话，↵ 只复制，要自己粘贴。第一次用时 Mochi 会请求；也可以在「系统设置 › 隐私与安全性 › 辅助功能」里打开。

Mochi 没有 Dock 图标，常驻在菜单栏。菜单栏图标被隐藏时，面板左下角的「设置」按钮能打开设置、退出 Mochi。

## 安装

从 [Releases](../../releases) 下载 `Mochi-<版本号>.zip`，解压，把 Mochi.app 拖进「应用程序」。

Mochi 没有经过苹果公证，第一次打开会被系统拦下。去「系统设置 › 隐私与安全性」点「仍要打开」，或者运行：

```sh
xattr -dr com.apple.quarantine /Applications/Mochi.app
```

## 从源码构建

要 Xcode 26，或者 Xcode 26 的 Command Line Tools。

```sh
git clone <这个仓库>
cd mochi
scripts/test.sh             # 单元测试
scripts/bundle.sh release   # 打包成 build/Mochi.app
open build/Mochi.app
```

钥匙串里有名为「Mochi Development」的证书时，`scripts/bundle.sh` 用它签名，没有就用 ad-hoc 签名。辅助功能权限认签名，ad-hoc 签名每次重新构建都要重新给权限。想省掉这一步，在「钥匙串访问」里建一张自签的代码签名证书（证书助理 › 创建证书…，证书类型选「代码签名」），名字叫 Mochi Development。

每次推送，GitHub Actions 都会构建、跑测试。推一个 `v` 开头的标签（比如 `v0.2.0`）会发布一个 Release，附上打包好的应用。发布的版本要用仓库 Secrets 里的证书签名：`MOCHI_CERT_P12`（证书和私钥导出的 .p12，base64）和 `MOCHI_CERT_PASSWORD`。Mochi 只更新到同一张证书签的版本，所以没有这两项时发布会失败。

应用图标是 `scripts/icon.swift` 画的。

## 数据在哪

剪切板历史存在 `~/Library/Application Support/com.blueocean223.mochi/`：一个 SQLite 数据库和一个图片文件夹。想从头来，退出 Mochi 后删掉这个文件夹。

## 代码结构

- `Sources/MochiCore`：读剪切板、认内容类型、存储（用系统自带的 libsqlite3）、图片处理。测试在 `Tests/MochiCoreTests`。
- `Sources/Mochi`：应用本身：菜单栏、面板、设置窗口、全局快捷键、粘贴、更新。
- `scripts`：构建、测试、画图标的脚本。

## 致谢

面板、快捷键和大部分行为照 [Raycast](https://www.raycast.com) 的剪切板历史做。Mochi 和 Raycast 没有关系。

## 许可

[MIT](LICENSE)
