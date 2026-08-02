# Artemis 原生适配

## 结论

Yoghourt 的 Artemis 路径使用 SDK 原生静态库，不再通过 WKWebView、WebAssembly、
Asyncify、HTTP 资源服务或 Emscripten FS 启动游戏。

原生方案让 Artemis 自己同步读取用户目录中的 `root.pfs`、分包和散文件。不存在
“一次 `fread` 对应一次 HTTP 请求”，也不需要复制或展开整个游戏。旧 Swift
`PFSReader` 是为 WASM 虚拟文件系统设计的宿主侧解析器；原生运行时不经过它。

```text
Yoghourt
  └─ ArtemisRunner
       └─ ArtemisPlayer.app
            ├─ AppKit 窗口与输入
            ├─ ANGLE GLES2 → Metal
            ├─ Artemis 原生静态库
            └─ 用户游戏目录
                 ├─ system.ini（可选，允许位于 PFS 内）
                 ├─ root.pfs
                 ├─ root.pfs.NNN
                 └─ 散文件
```

## 运行时边界

本仓库提交 Artemis 的 macOS 宿主源码（yogurt-artemis 子模块），但不提交闭源 SDK
产物。使用者将锁定文件放入被忽略的 `Vendor/ArtemisNative/`：

```text
Vendor/ArtemisNative/
├── libartemis_static_macos.a
├── libEGL.dylib
├── libGLESv2.dylib
├── EGL/
│   ├── egl.h
│   └── eglplatform.h
└── GLES2/
    └── gl2.h
```

三项二进制的 SHA-256 由 `Runtime.lock.json` 与
`Scripts/bootstrap-runtimes.sh` 同时锁定。SDK 的取得、使用和再分发受其许可
约束；Yoghourt 不联网下载这些文件。

构建命令：

```zsh
Scripts/bootstrap-runtimes.sh artemis
```

脚本使用 CMake/Ninja 构建 arm64、macOS 15.6 的 `ArtemisPlayer.app`，静态链接
FreeType，并嵌入 ANGLE dylib。Xcode 的 `Embed Optional Runtimes` 阶段再以
Yoghourt 的签名身份签署 helper 与 dylib。

## PFS 与文件访问

SDK 静态库的 iOS 入口默认从可执行文件附近寻找 `root.pfs`。宿主在
`ArtemisStatic::Launch` 前完成三件事：

1. 将 security-scoped bookmark 解析出的实际游戏根目录设为工作目录。
2. 通过 `ArtemisSetGameRoot` 保存该根目录。
3. 在锁定静态库的链接符号中，将文件 I/O 重定向到薄包装层。

包装层只在 SDK 错把 PFS 定位到 app bundle 时将其重定向回游戏根目录。读、
seek、tell 仍调用系统 stdio，macOS arm64 的 `long` 为 64 位，已验证可读取
2 GiB 以上偏移。游戏文件不会被复制、修改或写回。

`ArtemisRunner` 支持导入目录本身包含资源，也支持资源位于第一层子目录的常见
`archive/<作品>/root.pfs` 布局。实际启动参数始终传解析后的内容根目录。

## 存档隔离

Artemis 的 iOS 静态 SDK 通过
`NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, ...)` 获取存档
目录。若直接使用系统结果，所有游戏都会落入 Yoghourt 沙盒的同一个
`Documents`，产生跨作品串档。

构建时将静态 SDK 对该函数的引用改接到宿主包装层。包装层要求启动请求提供
`YOGHOURT_GAME_ID` 与统一的 `YOGHOURT_SAVE_ROOT`，将 SDK 眼中的
Documents 重定向到该作品的 Artemis live 目录：

```text
Application Support/Yoghourt/Saves/<save namespace>/engines/artemis/live
```

`SaveStore` 在首次启动时会把能明确归属当前 `Game` 的旧版 Artemis 隔离目录
复制进 live 目录，不覆盖已经存在的文件，也不删除旧存档。更早期写入沙盒
公共 `Documents` 的混合存档仍不会自动迁移，因为宿主无法可靠判断它们属于
哪款游戏。游戏资源继续从 security-scoped 原目录只读加载；缺失 game ID 或
统一存档根目录时，宿主拒绝退回公共目录并输出明确诊断，避免静默重新串档。

## 图形与窗口

原生 SDK 使用 OpenGL ES 2 接口。宿主通过用户 SDK 中锁定的 ANGLE 将 GLES2
映射到 Metal，并提供 UIKit/EAGL 的最小 AppKit 兼容层。

- 只允许 Artemis 创建一个 EAGLContext；宿主不再创建第二个 bootstrap
  context，避免两个 FBO 命名空间互相污染。
- 所有兼容 context 共享同一个 CAMetalLayer EGL window surface。
- 渲染 backing 固定为引擎尺寸；窗口缩放与原生全屏只缩放显示，避免 viewport
  随窗口改变后只显示左上区域。
- 16:9 游戏视图在非 16:9 屏幕中居中 letterbox，不拉伸画面。
- AppKit 管理 `MetalGLView` 根 `CAMetalLayer` 的 frame；宿主只更新
  `drawableSize`。不要把根 layer 的 frame 设成 `self.bounds`，否则画面会
  回到容器左下角，而鼠标仍按居中的 NSView 换算。
- 鼠标从 AppKit 左下原点转换到 Artemis/iOS 左上原点，并按固定 backing 尺寸
  换算坐标。
- `YOGHOURT_DISPLAY_MODE=fullscreen` 使用 `NSWindow.toggleFullScreen`，不是
  Zoom。
- helper 明确关闭 Display Safe Area Compatibility Mode；系统原生全屏仍按
  当前 Mac 的屏幕安全区放置窗口，游戏视图再在可用区域内居中。

SDK 中部分效果文件是旧 HLSL 像素函数，而 ANGLE 需要 GLSL。宿主只在
`glShaderSource` 边界转换已识别的旧格式；普通 GLSL 原样提交。转换失败不会
伪造成功，调试时可用 `YOGHOURT_ARTEMIS_SHADER_TRACE=1` 输出原始 shader。

## macOS 兼容层

`UICompat` 提供 SDK 实际引用的 UIKit 类型。macOS 私有 UIFoundation 也包含
名为 `UIFont` 的类，因此构建时将静态库引用与兼容类等长改名为 `YGFont`，
避免 Objective-C runtime 类冲突。

音频直接链接系统 AudioToolbox/CoreAudio；不使用返回伪成功的 AudioQueue
stub。应用失去焦点时只静音，不能调用引擎 `Terminate()`，否则恢复焦点后 GL
资源已经被销毁。

窗口标题、Dock 图标、locale 和显示模式来自 Yoghourt 注入的环境变量：

```text
YOGHOURT_GAME_TITLE
YOGHOURT_GAME_ICON
YOGHOURT_GAME_ID
YOGHOURT_DISPLAY_MODE
LANG / LC_ALL / LC_CTYPE
```

## 验证

常规验证：

```zsh
Scripts/bootstrap-runtimes.sh artemis
xcodebuild -project Yoghourt.xcodeproj \
  -scheme Yoghourt \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

实机验收至少覆盖：

- 《樱之诗》：标题、鼠标、Start、正文、存档和读档。
- 《樱之刻》：外置/内置 `system.ini` 两种包、Config、窗口缩放与全屏。
- 两款游戏各自保存并重启后，只能看到自己的存档；统一存档目录按 namespace
  隔离，公共 Documents 与游戏原目录均不再变化。
- 标题页静置十分钟不黑屏、不重启。
- `otool -L` 不出现 `/opt/homebrew`，`LC_BUILD_VERSION` 最低版本为 15.6。

当前原生路径不依赖 WebKit JIT 或 macOS 26 的 Enhanced Security API，因此
macOS 15.6 不存在旧 WASM 路径的 JIT 内存膨胀问题。
