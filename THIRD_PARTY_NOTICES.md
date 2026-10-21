# 第三方组件与原项目声明

HmDoMiSo 自有代码采用 [MIT License](LICENSE)。第三方组件仍保留各自版权和许可，分发时请一并保留以下声明与完整协议。

| 项目 | 作者/组织 | 许可 | 用途 |
| --- | --- | --- | --- |
| [DoMiSo-Universal](https://github.com/Nigh/DoMiSo-Universal) | Nigh，Copyright 2021 | MIT | 文本简谱格式、时值、DMS 文件格式与解码算法、MIDI 试听行为的原项目参考 |
| [hmdriver2](https://github.com/codematrixer/hmdriver2) | matrixer，Copyright 2024 | MIT | 内置 UITest agent 资源与 RPC 接口参考 |
| [developtools_hdc](https://gitee.com/openharmony/developtools_hdc) | OpenHarmony / Huawei Device Co., Ltd. | Apache-2.0 | HDC daemon 认证、消息帧与 shell 协议参考 |

完整协议随应用保存在 `entry/src/main/resources/rawfile/`：

- `hmdomiso_LICENSE.txt`：本项目 MIT 协议。
- `domiso_LICENSE.txt`：DoMiSo-Universal MIT 协议。
- `hmdriver2_LICENSE.txt`：hmdriver2 MIT 协议。
- `hdc_LICENSE.txt`：OpenHarmony HDC Apache-2.0 协议。

内置的 `uitest_agent.so` 来自 hmdriver2 1.4.4 的 `uitest_agent_v1.1.0.so`，SHA-256：

`950df1c67e0e611808c05a6f85589e93488278a5e4e20b6573665b247fe2da27`

HDC 客户端以 ArkTS 实现必要的 daemon 直连协议，没有复制电脑的 HDC 私钥，也没有把完整桌面 HDC 可执行文件打包进 App。

DoMiSo 原版通过 Windows MIDI 输出设备试听；本项目在鸿蒙端实现本地多声部 PCM 合成，音色与 Windows MIDI 音源可能不同。

本项目不包含原神游戏素材，不代表原神或其开发者的官方产品。相关名称与商标归各自权利人所有。
