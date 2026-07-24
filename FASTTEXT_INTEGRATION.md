# fastText 集成说明（任务B）

本次已在 `LangBarApp.swift` 中把 **fastText 作为 Apple NaturalLanguage 的补充验证层** 接好了。
核心策略：**NL 引擎置信度 < 0.70 时，用 fastText 结果覆盖**（fastText 概率 ≥ 0.50 且落在目标语种白名单内才采信）。
两条链路：
- 短块（≤3 纯 ASCII 且 NL 置信 < 0.50）：先试 fastText，仍不可信 → 归「未识别」。
- 普通块（stage ④）与兜底（stage ⑦）：NL 不够自信时用 fastText 覆盖。

> **重要：默认零风险降级。** 只要没准备好 fastText 二进制/模型，`fastTextLang()` 返回 `nil`，App 行为与之前完全一致，**不影响编译、不影响运行**。

---

## 方案对比

| 方案 | 代码位置 | 优点 | 缺点 | 状态 |
|---|---|---|---|---|
| **方式2：Process() 调 CLI**（默认启用） | 已写进 `LangBarApp.swift` | 零改工程、最简单、易调试 | 每块启动一次进程（已加缓存，OCR 块数有限，开销可接受） | ✅ 开箱即用 |
| **方式1：C++ 静态库 + bridging header**（推荐、性能最佳） | `fasttext-bridge/` 全套框架代码 | 进程内调用无 fork 开销、可打进 .app | 需改 Xcode 工程/加编译步骤 | 🧩 框架已备，按需切换 |

---

## 方式2（默认）：Process() 调用 fasttext CLI —— ★ 在 Mac 上执行 ★

只需一步，App 会自动发现并启用：

```bash
cd ~/lang-detect-mac && bash setup_fasttext.sh
```

该脚本会：
1. 安装/编译 `fasttext` 可执行文件（优先 brew，无 brew 则源码编译到 `bin/fasttext`）；
2. 下载 `lid.176.ftz`（约 1MB）到 `Resources/lid.176.ftz`；
3. 跑一条自检预测。

App 端自动发现顺序（无需改代码，见 `resolveFastTextBinary` / `resolveFastTextModel`）：
- 二进制：`$FASTTEXT_BIN` → `/opt/homebrew/bin/fasttext` → `/usr/local/bin/fasttext` → `/usr/bin/fasttext` → `~/lang-detect-mac/bin/fasttext`
- 模型：`$FASTTEXT_MODEL` → `App.app/Contents/Resources/lid.176.ftz` → `~/lang-detect-mac/Resources/lid.176.ftz` → `./Resources/lid.176.ftz`

`build_app.sh` 已加逻辑：若存在 `Resources/lid.176.ftz` 会自动打进 `.app`，使打包后的应用自带模型。

关闭 fastText（仅用 NL + 规则）：`export LANGBAR_DISABLE_FASTTEXT=1` 后再启动 App。

---

## 方式1（推荐、进程内）：C++ 静态库 + bridging header

已提供的框架文件（`fasttext-bridge/`）：
- `FastTextBridge.h` —— 暴露给 Swift 的纯 C 接口（`ftbridge_load_model` / `ftbridge_is_ready` / `ftbridge_predict`）
- `FastTextBridge.mm` —— Objective-C++ 实现，调用 fastText C++ API（`loadModel` / `predictLine`，log 概率已 `exp` 还原）
- `LangBar-Bridging-Header.h` —— Swift 桥接头
- `CMakeLists.txt` —— 编译 fastText 源码 + 本封装为 `libfasttext_bridge.a`

### 步骤（★ 全部在 Mac 上执行 ★）

```bash
cd ~/lang-detect-mac/fasttext-bridge
# 1) 拉 fastText 源码
git clone --depth 1 https://github.com/facebookresearch/fastText third_party/fastText
# 2) 编译静态库（Universal: arm64 + x86_64）
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
#   产物: build/libfasttext_bridge.a
```

### 与 Swift 对接（命令行 swiftc 版）

```bash
swiftc LangBarApp.swift \
  -import-objc-header fasttext-bridge/LangBar-Bridging-Header.h \
  -I fasttext-bridge -I fasttext-bridge/third_party/fastText/src \
  -L fasttext-bridge/build -lfasttext_bridge -lc++ \
  -o 语种识别
```

（Xcode 工程版：Build Settings → *Objective-C Bridging Header* 指向 `LangBar-Bridging-Header.h`；把 `libfasttext_bridge.a` 加入 *Link Binary With Libraries*；`Header Search Paths` 加 `fasttext-bridge` 与 `.../fastText/src`。）

### 切换 Swift 端调用（把 CLI 版换成进程内版）

在 `LangBarApp.swift` 的 `fastTextLang(_:)` 里，把 Process() 实现替换为桥接调用即可（保持函数签名不变，其余逻辑无需动）：

```swift
func fastTextLang(_ text: String) -> (code: String, prob: Double)? {
    // 首次调用时加载模型（幂等）
    if ftbridge_is_ready() == 0 {
        guard let model = fastTextModel else { return nil }
        if ftbridge_load_model(model) == 0 { return nil }
    }
    let key = normalizedKey(text)
    ftCacheLock.lock()
    if let cached = ftCache[key] { ftCacheLock.unlock(); return cached.value }
    ftCacheLock.unlock()

    var buf = [CChar](repeating: 0, count: 32)
    var prob: Float = 0
    let ok = text.withCString { ftbridge_predict($0, &buf, 32, &prob) }
    let result: (code: String, prob: Double)? =
        (ok == 1) ? (ftLabelToCode("__label__" + String(cString: buf)) ?? "", Double(prob)) : nil
    let cleaned: (code: String, prob: Double)? =
        (result != nil && !result!.code.isEmpty) ? result : nil

    ftCacheLock.lock(); ftCache[key] = FTCacheEntry(value: cleaned); ftCacheLock.unlock()
    return cleaned
}
```

> 进程内版仍复用 `resolveFastTextModel()` 找模型；不再需要 fasttext CLI 二进制。

---

## 阈值调参（都在 `LangBarApp.swift` 顶部）

| 常量 | 默认 | 含义 |
|---|---|---|
| `NL_HIGH_CONF` | 0.70 | NL 概率 ≥ 此值直接采信 NL，不问 fastText |
| `FASTTEXT_TRUST_PROB` | 0.50 | fastText 概率 ≥ 此值才采信其结果 |
| `SHORT_ASCII_MIN_PROB` | 0.50 | 纯 ASCII ≤3 短词 NL 概率下限，低于则不强判 |

---

## 任务A：字符特征规则（已随本次一并生效，无需额外操作）

- 含意语重音 `à è é ì ò ù`（且不含法语 `â ê î ô û ç`）的 ≤4 字符短词 → 直接判 **意大利语**，不走 NL。
- 含法语专有 `â ê î ô û ç ë ï œ` → 判 **法语**。
- 含 `ä ö ü ß` → 强制 **德语**。
- 纯 ASCII ≤3 短词且 NL 置信度 < 0.5 → 不强判（先试 fastText，否则归「未识别」）。
- 优先级：强制词表 > 字符特征 > 形态/NL/fastText，保证 `qué`/`café` 等仍归其既有语种。
