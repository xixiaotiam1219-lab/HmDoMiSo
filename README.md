# HmDoMiSo

运行在 HarmonyOS 手机上的 DoMiSo 曲谱与原神琴演奏工具。App 内置 HDC 无线调试客户端，连接手机自身的调试服务，完成曲谱解析、琴键校准与演奏；正常配置后，运行时不需要电脑。

**项目地址：[xixiaotiam1219-lab/HmDoMiSo](https://github.com/xixiaotiam1219-lab/HmDoMiSo)**  
**原项目：[Nigh/DoMiSo-Universal](https://github.com/Nigh/DoMiSo-Universal)**  
**开源协议：[MIT](LICENSE)** · [第三方组件与许可](THIRD_PARTY_NOTICES.md)

## 功能

- 使用系统 PasteButton 安全控件粘贴 DoMiSo 文本简谱，或通过系统文件选择器导入 UTF-8 TXT。仅在用户点击并获得临时授权后读取剪贴板。
- 解析音高、时值、休止、BPM、调号、和弦、连音组、多声部和 `rollback`，按绝对时间合并起音。
- 检查曲谱错误、21 键音域和同时起音数量，显示时长、速度及音符数量。
- 支持从文件管理器、聊天应用的 TXT“打开方式”导入，兼容首次启动和应用已打开的场景。
- 本地曲库保存；歌曲支持可见删除按钮和长按菜单，删除前确认。
- 导入本机完整横屏截图，以四角和逐键/逐行微调校准 3×7 琴键。坐标按原图像素保存。
- 手机内 HDC 身份生成、正常系统授权、daemon 认证与 shell 探测；经授权的 UITest 后端执行多指触摸。
- 播放、暂停、继续、停止及 0.5–1.5 倍速度；播放前打开原神并核对横屏尺寸，起播延迟可在设置中调为 0–30 秒并保存。
- 本地多声部琴音试听与单键试音；音频在 Worker 中预生成临时 WAV，再交给系统 AVPlayer 播放，播放期间不进行逐样本 ArkTS 计算。
- HdsTabs 与 MiniBar、系统 Symbol 图标、沉浸式窗口及深色模式。
- 系统悬浮球：设置页和播放器面板提供显示/关闭入口，点击悬浮球切换播放/暂停，显示偏好会保存并在下次进入应用时恢复。
- 连续后台任务、系统任务实况通知、AVSession 媒体控制与通知操作入口。

## 环境

- 当前工程使用 Stage 模型、ArkTS，`targetSdkVersion` 为 `26.0.0`，`compatibleSdkVersion` 为 `6.1.1(24)`。
- 使用匹配 SDK 的 DevEco Studio。当前开发环境为 API 26 Beta SDK。
- 设备需提供无线调试服务，并允许本安装生成的调试身份。系统调试能力、UITest 与后台任务限制会随系统和设备变化。
- 已有端到端演奏验证来自 CMM-AL10，屏幕横屏尺寸为 2848×1320。其他分辨率需重新校准。

编译成功只说明工程能够生成 HAP；跨应用触摸、后台持续演奏和系统卡片仍须在目标设备单独验证。

## 首次使用

1. 在手机开发者选项中打开无线调试，记下当前 IP 和端口。
2. 在 App「设置」中连接本机地址与端口。可尝试 `127.0.0.1`，也可使用无线调试页面显示的本机 IP。
3. 首次连接时，按系统提示允许本 App 的调试身份。连接成功后自动准备演奏服务。
4. 在原神中打开风物之诗琴，截取本机完整横屏截图。在「校准」中从相册导入。
5. 将四角对齐高音 do、高音 ti、低音 do、低音 ti 的琴键中心，按需移动、缩放、微调，确认完整原图后保存。
6. 在「曲谱」中导入或粘贴简谱，检查后保存。选择「琴音试听」可直接听谱；选择「游戏演奏」后点击播放，会打开原神并预留切换时间。
7. 使用 MiniBar 或系统控制入口暂停、继续、停止。点击倍率打开速度调节弹窗。点开 MiniBar 可查看完整曲名与播放器，进度条支持拖动跳转。

App 会打开原神的 `com.miHoYo.Yuanshen / UnityPlayerAbility`。请提前进入琴界面；打开游戏本身不会自动完成游戏内菜单操作。

### 校准须知

- 四角指的是最外侧四个琴键的中心，不能对齐截图四角。
- 截图必须完整、未裁剪且未缩放；截图尺寸需与设备横屏分辨率一致。
- 显示缩放和留白会映射回原始截图像素。保存的数据包含原图尺寸、方向、四角、21 键坐标及微调值。
- App 处于竖屏时，先比较物理分辨率；切入原神后再验证横屏方向。真正的分辨率变化需要重新校准。
- 本机坐标样本只用于此前验证过的布局；游戏 UI 尺寸或琴键位置改变后请重新校准。

## 曲谱格式

沿用 DoMiSo 文本格式，音符与括号之间使用空格。标准中音 `1` 对应 MIDI 60；低、中、高三个八度使用 `-1…-7`、`1…7`、`+1…+7`。

```text
1=C
bpm=88
1 2 3 5 | ( 1 3 5 ) 0 |
rollback=6
-1- -5- -1- |
```

- `0` 为休止；`/` 缩短时值，`-` 延长，`.` 为附点。
- `( 1 3 5 )` 表示和弦；`{ 1 2 3 }` 表示按成员时值比例分配的连音组。
- `rollback=N` 按当前 BPM 回退 N 拍，开始后续声部。
- 支持 `1=C` 等调号；超出原神 21 个自然音的音高会报错，不会静默丢弃。
- 加密 DMS、原生 `~` 琶音、嵌套组和跨行组不支持。

游戏琴使用短触摸脉冲触发固定拨弦音色，保留音符起音；本地试听按谱面时值合成，两者的发声方式不同。

## 后台与系统控制

- 游戏演奏通过真实 HDC/UITest 网络通信申请 `dataTransfer` 连续任务；连接保留期间按设置保持任务。
- 本地试听使用系统 AVPlayer 音频输出及 `audioPlayback` 任务。
- 需要正常通知授权。系统可能暂停或取消任务；App 收到取消/暂停事件后暂停演奏，避免失去后台保护后继续排队发送触摸。
- 任务通知沿用系统实况模板；媒体控制使用 AVSession，通知操作作为补充入口。
- 关闭后台演奏或释放连接时停止对应任务。系统卡片的具体布局、可用按钮和后台限制由设备系统决定。

## 构建与安装

在 DevEco Studio 打开本仓库，完成工程同步，再在 `Project Structure → Signing Configs` 中配置本工程的正常调试签名。仓库中的构建配置不包含签名材料；请使用自己的开发者账号配置签名。不要提交私人签名材料或复制其他安装的调试身份。

可通过 DevEco Studio 构建，也可在工程根目录使用对应安装的 Hvigor：

```powershell
$devecoPath = '你的 DevEco Studio 安装目录'
$env:DEVECO_SDK_HOME = Join-Path $devecoPath 'sdk'
$env:JAVA_HOME = Join-Path $devecoPath 'jbr'
& (Join-Path $devecoPath 'tools/node/node.exe') `
  (Join-Path $devecoPath 'tools/hvigor/bin/hvigorw.js') `
  assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
```

默认签名产物：`entry/build/default/outputs/default/entry-default-signed.hap`。使用 DevEco Studio 部署，或执行 `hdc install -r <HAP路径>`。

电脑用于开发、签名和初次安装。手机端运行时的调试客户端、认证和调度都在 App 内执行。

## 工程结构

```text
entry/src/main/ets/
  core/           曲谱、HDC、触摸、校准、演奏、系统控制与试听
  components/     速度和许可弹窗
  workers/        试听音频预生成线程
  entryability/   沉浸窗口、系统操作与生命周期
  pages/          曲谱、校准与设置界面
entry/src/main/resources/rawfile/  触摸资源与完整许可
```

## 数据与权限

曲库、截图校准和调试身份保存在本机应用沙箱。导入截图走系统图片选择器，无需上传服务器。每次安装生成自己的调试身份，不读取电脑 HDC 私钥；无线调试关闭或重启后，地址/端口可能改变，需要重新连接。App 已关闭备份恢复，避免调试身份随备份复制。

应用使用网络权限连接本机调试服务，并声明连续后台任务与系统悬浮球权限。剪贴板仅在用户点击系统 PasteButton 并获得临时授权后读取。外部 TXT 使用来源应用授予的单文件 URI 读取权限。跨应用触摸依赖用户正常启用并授权的调试链路。

## Contributors

| 贡献者 | 角色与贡献 |
| --- | --- |
| [@xixiaotiam1219-lab](https://github.com/xixiaotiam1219-lab) | 项目维护者；需求、设计取舍、真机反馈、验收与发布。 |
| [Codex（OpenAI）](https://github.com/codex) | **AI co-builder**；协助代码实现、问题定位、文档编写及应用图标创作。 |

完整贡献说明见 [CONTRIBUTORS.md](CONTRIBUTORS.md)。功能取舍与发布由维护者决定；应用图标使用内置图像生成工具创作。

## 致谢与许可

感谢 [Nigh](https://github.com/Nigh) 的 [DoMiSo-Universal](https://github.com/Nigh/DoMiSo-Universal)。本项目的曲谱语义与试听交互参考该原项目。

感谢 [hmdriver2](https://github.com/codematrixer/hmdriver2) 和 [OpenHarmony developtools_hdc](https://gitee.com/openharmony/developtools_hdc)。组件用途、版权、版本和完整许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

HmDoMiSo 自有代码按 [MIT License](LICENSE) 发布。项目与原神及其开发者无官方关联。
