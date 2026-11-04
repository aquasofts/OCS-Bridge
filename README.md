# OCS Bridge 0.2.2

Flutter Windows 题库桥接工具。参考 FlClash 的 Material 3 导航、卡片与过渡风格，界面以功能名和状态为主，未使用 FlClash 的源码或图标。

## 使用

解压完整发布包，运行 `ocs_bridge.exe`，保留旁边的 DLL 和 `data` 目录。

0.2.1 修复了 0.2.0 从资源管理器双击时可能立即闪退的问题：日志初始化不再调用要求控制台存在的 Flutter 输出流重建接口。

0.2.2 遇到 TLS 连接失败、网络连接失败或连接中断时自动建立新连接重试，最多重连 3 次，依次等待 1、2、4 秒。重连与等待共享原有请求超时，不延长 OCS 所需超时；停止服务或退出时立即取消重连。鉴权、参数及响应格式错误不会自动重试。网络日志记录每次尝试及重连原因。

1. **供应商**：填写 OpenAI、DeepSeek 或兼容服务的 Base URL 和 API Key。
2. **模型**：手动添加，或获取供应商模型列表；单独设置供应商、协议、搜索、思考模式和深度、Token、温度、超时、图片及扩展参数。
3. **概览**：选择当前模型并启动服务。
4. **OCS 接入**：复制配置，在 OCS 题库配置中粘贴保存。
5. OCS 的题库超时应大于模型超时至少 15 秒，并发不超过 4。

OCS 与本软件需在同一台电脑运行。脚本管理器需要允许访问 `127.0.0.1`，浏览器可能需要用户允许本地网络访问。

## 功能

多供应商、模型列表、连接测试、独立模型配置、Responses、Chat Completions、搜索关闭/自动/强制、思考模式与深度、图片输入、单选/多选/判断/填空/简答、答题调试、来源链接、Token 统计、请求详情、内存缓存、深浅色主题、统一动效弹窗、端口设置、接入令牌、打开软件时启动服务。

请求记录支持全部或单条导出，提供 JSON、CSV、TXT、Markdown，可只导出成功答案。CSV 使用 UTF-8 BOM，保留中文、换行和引号。导出文件由用户选择保存位置，不参与日志自动清理。

Responses 会统计供应商返回的已完成搜索调用与网页读取；返回引用时可直接打开来源。DeepSeek 内置搜索使用 `deepseek-v4-pro` + Responses，Flash 的搜索组合会被拦截。

能力由所选模型决定，开关不会为模型新增能力。DeepSeek Chat 搜索会被拒绝，应使用支持联网的 Responses 模型。OpenAI Responses 使用“思考深度”，思考模式保持默认。供应商可能忽略其不支持的参数。API 调用使用用户的供应商额度。

## 数据

API Key 使用原生 Windows `CredWriteW / CredReadW / CredDeleteW` 存入当前用户凭据存储，不写入 JSON 配置或 OCS 题库配置。按用户要求，本版本的操作、凭据调用及网络日志会保留明文 Key。配置位于应用支持目录，可从“设置 → 配置目录”打开。

题目会发送到所选供应商。本机接口只监听 IPv4 回环地址，要求随机接入令牌，最多同时处理 4 个请求。界面展示简短错误，日志保存原始错误响应和完整异常堆栈。

缓存最多 100 条，保存在内存，退出清空。请求记录不设 200 条上限，保留最近 24 小时并在重启时恢复；界面按每页 50 条显示。清空记录会清空请求记录视图，原始审计事件仍遵循 24 小时保留规则。缓存键包含供应商、模型设置、题目、选项、题型和图片的 SHA-256 摘要。首次运行没有虚构的模型和历史数据。

## 日志

默认启用，不脱敏、不截断已收到的正文。位置为 `%LOCALAPPDATA%\OCSBridge\logs`，可从“设置 → 日志目录”打开。“日志状态”会显示存储或原生日志初始化异常。

- **操作**：鼠标按下、抬起、移动、滚轮、触摸、缩放、坐标、命中控件路径和文字、控件语义、按键及修饰键、焦点、输入前后原文、光标选择、中文输入法组合区。密码框和 API Key 输入也保存原文；范围为本软件界面。
- **处理**：启动环境、控制台输出、内存心跳、页面和主题切换、弹窗开关、提示、配置加载原文及保存、供应商和模型操作、凭据读写、校验错误、请求调度、缓存、合并请求、JSON 解析、答案和用量、记录恢复、导出内容与结果、异常类型及完整堆栈。
- **网络**：本机 OCS 和上游供应商 HTTP 的方法、URL、请求头、响应头、状态码、完整请求/响应正文、逐块数据、字节数、时间、连接地址/端口、服务器证书、压缩状态、超时及中断。Authorization、接入令牌、题目、图片、回答及服务商返回的内容均保留原文。UTF-8 文本与 Base64 字节同时保存，关联 ID 可串起整次请求。
- **原生**：Windows 窗口消息、引擎与进程 stdout/stderr、启动退出、关闭落盘流程，以及可被未处理异常处理器捕获的原生崩溃摘要和 `.dmp` 线程/堆栈转储。系统保存对话框记录调用与最终结果。

JSONL 每行一个事件，包含 UTC 时间、当地时区偏移、会话、进程、序号、启动后耗时、分类及完整数据。`interaction-*` 为操作，`runtime-*` 为运行/处理，`network-*` 为 HTTP，`answers-*` 为请求记录，`native-*` 为原生输出/转储。

按分钟轮转，运行期间每分钟清理超过 24 小时的数据；关闭期间不运行后台服务，下次启动时清理。日志不设大小上限，写入失败的事件暂存内存并重试。正常关闭先取消在途请求，等待配置和日志落盘。

网络记录覆盖本软件实际收发的 HTTP 层数据，不抓取其他应用流量或 TLS 密文。请求被超时、并发或正文大小限制中止时，保留已收到的全部分块和中止信息。

## 开发

验证环境：Flutter 3.47.9、Dart 3.13.7、MSVC 19.50、Windows SDK 10.0.26100。

```powershell
flutter pub get
dart analyze lib test tool
flutter test
flutter build windows --release
```

当前机器存在中文构建路径兼容问题和 Visual Studio 工作负载登记问题。`tool/build-windows.ps1` 提供临时英文路径与现有 CMake/MSVC 的构建回退，不修改系统设置。

OCS 上游管线验证需要 Node 24 与 OCS 源码：

```powershell
dart run tool/export_wrapper.dart
node tool/ocs_contract_test.mjs path/to/ocsjs
```

真实接口验证使用进程环境变量 `OCS_TEST_API_KEY`、`OCS_TEST_BASE_URL`、`OCS_TEST_MODEL`，运行 `dart run tool/live_check.dart`。`OCS_TEST_MODE` 支持 `responses`、`chat`、`search`，`OCS_TEST_EFFORT` 指定深度。工具通过本机 OCS 接口调用生产请求链路，不打印密钥或上游错误正文。

原生自检：`ocs_bridge.exe --smoke-test`，验证配置读取、Windows 凭据读写删除、保存对话框初始化和首帧光栅化后退出；仅使用临时占位凭据。`--smoke-test-close` 还会走正常窗口关闭及日志落盘流程。`--diagnostics-crash-test` 在独立测试进程中产生受控原生异常以检查转储。显卡兼容启动：`ocs_bridge.exe --compat-renderer`。

`tool/test-windows-startup.ps1 -Executable path/to/ocs_bridge.exe` 使用没有控制台的独立进程模拟资源管理器启动，分别验证隐藏自检和可见窗口自检。`--smoke-test-visible` 会显示真实窗口，确认首帧与窗口可见状态后正常关闭。

## 验证状态

- 36 项 Flutter 测试通过，覆盖协议参数、答案解析、供应商/模型 CRUD、弹窗生命周期、本机 HTTP、鉴权、缓存、搜索、七个页面、窗口宽度、明文点击/按键/密码/中文组合输入、网络头/长正文/分块/错误/关联 ID、24 小时清理、写入失败恢复、205 条记录重启恢复、四种导出格式及保存流程。
- 0.2.2 增加 8 项自动重连回归测试：TLS / Socket / HTTP 中断后使用新连接恢复、三次重连上限、等待及连接期间取消、取消后新请求正常执行、共享总超时、鉴权及响应格式错误不重试。使用本机模拟供应商及注入的网络异常验证。
- 0.2.2 Windows x64 Release 编译及隐藏启动、正常关闭自检通过。
- 直接运行 OCS 上游 `AnswerWrapperParser` 与 `defaultAnswerWrapperHandler`，导出配置验证通过。
- Windows x64 Release 编译完成。
- Windows 原生自检通过：配置读取、凭据读写删除、保存对话框初始化、首帧光栅化、正常窗口关闭和日志落盘；受控异常生成有效 MDMP 转储。桌面人工交互验收尚未完成。
- 0.2.1 增加无控制台启动回归：旧版复现 `0xC0000409`，修复后隐藏启动和真实可见窗口启动均通过，检查正常关闭及日志落盘。
- 已使用用户提供的兼容供应商和 `gpt-6.1-terra` 真实联调：模型列表、Chat、Responses、本机 OCS 接口、`low` / `high` 思考深度均通过；强制搜索返回 1 次已完成搜索调用，供应商未返回引用链接。
- DeepSeek 官方服务真实联调通过：`deepseek-flash` Chat / Responses 答题、`deepseek-v4-pro` 强制搜索（确认 1 次已完成调用）。
- 真实供应商联调在 0.1.1 完成；0.2.0 的新增日志测试使用本机模拟供应商及占位密钥。交付包不含用户 Key。实际课程页面尚未联调。
- 发布包未签名。

## 依据

- [OCS](https://github.com/ocsjs/ocsjs)，分支 `5.0`，版本 `9a9da0439dbd1fba4b61dae062d61feb2110897f`。
- [OCS 题库接口](https://github.com/ocsjs/ocsjs/blob/9a9da0439dbd1fba4b61dae062d61feb2110897f/packages/core/src/core/answer-wrapper/interface.ts)。
- [OpenAI 官方联网搜索](https://developers.openai.com/api/docs/guides/tools-web-search)。
- [DeepSeek 思考模式](https://api-docs.deepseek.com/guides/thinking_mode/)、[Responses](https://api-docs.deepseek.com/guides/responses_api/)。
- [Windows 凭据接口](https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credwritew)。
