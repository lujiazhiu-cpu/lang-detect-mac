# 语种识别 · Lang Detect for macOS

一款常驻 **macOS 菜单栏** 的截图语种识别小工具。点击菜单栏图标（或按快捷键 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd>）即可框选屏幕任意区域，自动 OCR 识别其中文字并**逐块标注语种**，在左上角汇总各语种占比并判断是否为混语图。

底层完全基于 Apple 原生框架，无需任何网络请求、无第三方依赖：

- **[Vision](https://developer.apple.com/documentation/vision)** —— 文字识别（OCR），返回逐块位置与置信度
- **[NaturalLanguage](https://developer.apple.com/documentation/naturallanguage)** —— 语种判定

## ✨ 功能特性

- 常驻菜单栏，无 Dock 图标（`LSUIElement`），不打扰日常使用
- 点击图标或全局快捷键 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> 一键截图框选
- 框选区域 OCR（原始像素、关闭纠错、自动语种检测）
- 逐块标注语种：不同语种不同颜色框 + 标签
- 左上角汇总各语种占比 + 是否混语提示
- 文字太小 / 模糊 / 置信度低 → 标注「未识别」，绝不乱猜语种
- **设置窗口**（⌘,）：勾选启用的识别语种、调节 OCR/语种置信度阈值与文字最小高度、开关「识别后自动打开预览」，配置持久化
- **历史记录窗口**：列表查看历次识别的主体语种 / 占比 / 是否混语 / 标注图快照，可重新打开或一键清空

### 覆盖语种

意大利语 `it` / 葡萄牙语 `pt` / 越南语 `vi` / 印尼语 `id` / 日语 `ja` / 韩语 `ko` / 泰语 `th` / 阿拉伯语 `ar` / 德语 `de` / 法语 `fr` / 英语 `en`（另可识别中文 `zh`）。

## 📦 仓库结构

```
lang-detect-mac/
├── LangBarApp.swift        # App 主源码（菜单栏常驻 + 截图 OCR + 语种标注 + 菜单入口）
├── Settings.swift          # 全局设置存储（语种开关 / 阈值 / 行为，持久化到 UserDefaults）
├── SettingsWindow.swift    # 设置窗口 GUI（语种勾选 + 阈值滑块 + 恢复默认）
├── HistoryStore.swift      # 识别历史存储（元数据 + 标注图快照）
├── HistoryWindow.swift     # 历史记录窗口 GUI（列表 + 详情预览 + 清空）
├── build_app.sh            # 一键编译打包脚本（编译目录下全部 .swift），产出「语种识别.app」
├── fix_all.sh              # 常见问题一键修复脚本
├── README.md
└── Resources/
    ├── AppIcon_1024.png        # 打包用 App 图标源（1024×1024）
    ├── menubar_icon.png        # 菜单栏图标（1x）
    ├── menubar_icon@2x.png     # 菜单栏图标（2x，Retina）
    ├── app_icon_final.png      # App 主图标 · 最终版
    └── menubar_icon_final.png  # 菜单栏图标 · 最终版
```

## 🚀 安装 / 构建

> 需要 macOS 11.0+，并安装 Xcode 命令行工具（首次运行脚本会自动触发 `xcode-select --install`）。

```bash
# 克隆仓库
git clone https://github.com/lujia.zhiu/lang-detect-mac.git
cd lang-detect-mac

# 一键编译打包，产物位于 ~/Applications/语种识别.app
bash build_app.sh
```

打包完成后：

1. 在菜单栏右上角会出现「取景框 + A」图标。
2. 首次点击图标截图（或按 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd>）后，如系统提示授权：
   **系统设置 → 隐私与安全性 → 屏幕录制 → 勾选「语种识别」→ 重开 App**。

如遇异常，可执行修复脚本：

```bash
bash fix_all.sh
```

## 🎮 使用方法

- **点击菜单栏图标** 或按 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> → 框选屏幕区域
- 识别结果会以彩色框 + 语种标签叠加显示，左上角展示各语种占比与是否混语

## 🛠 技术栈

| 模块 | 说明 |
|------|------|
| Vision | OCR 文字识别（逐块位置 + 置信度） |
| NaturalLanguage | 语种判定（拉丁语系概率阈值 0.55） |
| AppKit / ImageIO | 菜单栏 UI、截图与图像处理 |
| Carbon HIToolbox | 全局快捷键 `RegisterEventHotKey` |
| UserNotifications | 结果通知 |

## 📄 License

MIT
