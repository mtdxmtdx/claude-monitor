# Claude Code Monitor — 部署说明

## 项目结构

```
claude-monitor/
├── bridge/           ← 运行在 Windows PC 上
│   ├── bridge.js     ← 核心桥接服务
│   ├── package.json
│   └── start.bat     ← 双击启动
└── app/              ← Android 端 Flutter 项目
    ├── pubspec.yaml
    └── lib/
        └── main.dart ← 完整 App（单文件）
```

---

## Windows 端部署

### 前置要求
- Node.js 18+（https://nodejs.org）
- Claude Code 已安装（`npm install -g @anthropic-ai/claude-code`）
- Tailscale（跨网络使用时，https://tailscale.com）

### 启动
```
双击 bridge/start.bat
```

首次运行会自动安装依赖、添加防火墙规则。

启动后终端会显示所有可用 IP：
```
╔══════════════════════════════╗
║   Claude Code Bridge 已启动   ║
╠══════════════════════════════╣
║  (局域网)     192.168.1.100   ║
║  (Tailscale)  100.88.12.34    ║
║  端口: 8765                   ║
╚══════════════════════════════╝
```

---

## Android 端部署

### 前置要求
- Flutter SDK 3.x+（https://flutter.dev）

### 构建
```bash
cd app
flutter pub get
flutter run          # 调试模式直接运行
flutter build apk    # 构建 APK
```

APK 路径：`build/outputs/flutter-apk/app-release.apk`

### 权限（AndroidManifest.xml 需确认含有）
```xml
<uses-permission android:name="android.permission.INTERNET"/>
```
Flutter 新项目默认已包含。

---

## 使用方法

| 场景 | 选择模式 | 填写 IP |
|------|---------|---------|
| 手机和电脑在同一 WiFi | 局域网 | 192.168.x.x |
| 手机开热点，电脑连热点 | 局域网 | 192.168.43.1（固定） |
| 不同网络（需安装 Tailscale） | Tailscale | 100.x.x.x |

两个 IP 分别记忆，切换模式无需重新输入。

---

## 功能说明

| 功能 | 说明 |
|------|------|
| 局域网 / Tailscale 一键切换 | 分别保存 IP，切换即用 |
| 断线历史回放 | 重连后自动补全断线期间输出 |
| 自动重连 | 断开后每 5 秒尝试重连 |
| ANSI 颜色 | 完整 VT100 终端渲染 |
| 底部快捷键栏 | Ctrl+C / Tab / Esc / ↑↓ / Enter |
| 清屏 | AppBar 右侧扫帚按钮 |
| 终端历史 | 保留最近 10000 行 |
| 目录跳转 | AppBar 文件夹图标，按名称模糊搜索 Windows 文件夹并 `cd` 过去；支持自定义常用根目录 |

---

## 目录跳转

连接后点击 AppBar 上的文件夹图标即可打开抽屉：

- **根目录条**：默认包含主目录、桌面、文档、下载和所有可用盘符；点击 `+` 可添加自定义根（例如 `D:\projects`），长按自定义根可删除。
- **搜索框**：输入关键字后会在所选根目录下做不区分大小写的文件夹名匹配（深度 4 层、最多 200 条、自动跳过 `node_modules` / `.git` / `AppData` 等噪音目录）。
- **点击结果**：直接向 Claude shell 发送 `cd /d "完整路径"` 并回车，抽屉自动关闭。

自定义根目录持久化到 `bridge/roots.json`，重启 bridge 不会丢失。
