# TinaIDE Registry

[![爱发电](https://img.shields.io/badge/%E7%88%B1%E5%8F%91%E7%94%B5-%E6%94%AF%E6%8C%81%E5%BC%80%E6%BA%90-946ce6?style=flat-square)](https://ifdian.net/a/wuxianggujun)

## 插件 v2/v3 与依赖包 v2

当前 Registry 默认发布：

```text
plugins/index.v3.json
plugins/<plugin-id>/plugin.v3.json
plugins/index.v2.json
plugins/<plugin-id>/plugin.json
packages/index.v2.json
packages/<package-id>/package.json
```

`0.18.11+` Android 客户端读取插件 v3，并从完整历史中按 Plugin API 与
`min_app_version` 选择最高兼容版本。旧 IDE 读取插件 v2；该视图只包含
`0.17.11 + Plugin API v1` 可用版本。依赖包继续读取 v2。v2/v3 只改变索引视图，
引用的是同一套不可覆盖的 `.tinaplug`，不会为不同 IDE 构建两份插件。

Android 主干已经移除旧 `index.json` fallback；任何当前索引不存在、请求失败或解析
失败都会直接暴露 Registry 发布问题。确实需要服务更旧客户端时，
可以显式加 `-IncludeLegacyV1` 生成 `plugins/index.json` / `packages/index.json`。
`scripts/validate-registry.ps1` 默认要求旧 v1 索引不存在，并校验 v2 是 v3 的兼容
子集、包内 manifest 与版本元数据一致、历史同版本制品没有被覆盖。

## 协议生命周期

插件 v3 是当前主协议，插件 v2 是旧宿主兼容视图，依赖包保持 v2。旧 v1 全量索引
只适用于历史客户端，不再默认生成、校验或发布。

- `0.17.11`：Android 客户端引入 v2 优先读取，并把 v1 fallback 标记为废弃兼容层。
- `0.18.0`：Android 客户端删除 v1 fallback；Registry 默认停止生成 v1。
- `0.18.11`：插件客户端切换到 v3 兼容选择；v2 固定为旧宿主安全子集。

如需临时兼容旧客户端，可以使用 `build-registry.ps1 -IncludeLegacyV1` 与
`validate-registry.ps1 -AllowLegacyV1`。

## Android 包产物规则

Android 依赖包按“一个库一个逻辑包”发布，不拆成 `-arm64` / `-x86_64`
这类不同包 ID。包内容和设备兼容性通过元数据表达：

- `artifact_type` 可取 `source`、`header`、`static`、`shared`、`executable`、`mixed`。
- `source` 和 `header` 包不能声明 `abi`。
- `static`、`shared`、`executable` 包必须声明 `abi`。
- 单个包可以同时包含多个 ABI 目录，例如 `lib/arm64-v8a/` 和 `lib/x86_64/`。
- Android 客户端会在下载前拦截不匹配当前设备的 `abi`。

TinaIDE 插件市场和依赖包市场的公开 Registry。

客户端默认按顺序读取：

```text
https://raw.githubusercontent.com/wuxianggujun/TinaIDE-Registry/main
https://cdn.jsdelivr.net/gh/wuxianggujun/TinaIDE-Registry@main
```

## 目录结构

```text
plugins/index.v2.json                      # 插件市场 v2 轻量索引
plugins/<plugin-id>/plugin.json            # 旧宿主兼容版本历史
plugins/index.v3.json                      # 插件市场 v3 轻量索引
plugins/<plugin-id>/plugin.v3.json         # 完整版本历史与兼容元数据
plugins/<plugin-id>/<version>/*.tinaplug   # 插件发布包
packages/index.v2.json                     # 依赖包市场 v2 轻量索引
packages/<package-id>/package.json         # 单个依赖包详情、版本和下载信息
packages/<package-id>/<version>/*          # 依赖包发布文件
sources/plugins/**                         # 官方插件源码或完整打包目录
sources/plugin-starters/**                 # 插件脚手架源模板和校验/打包脚本
metadata/*.json                            # 生成索引用的元数据
scripts/*.ps1                              # Registry 构建脚本
.github/workflows/*.yml                    # Registry 校验和发布自动化
```

## 构建索引

```powershell
pwsh ./scripts/build-registry.ps1
```

该脚本会：

- 重新构建官方插件脚手架 zip。
- 将 `sources/plugins/**` 打包成 `.tinaplug`。
- 计算插件包和依赖包的 `sha256` 与文件大小。
- 重写插件 v2/v3、依赖包 v2 和对应详情文件。
- 为 native 依赖包生成按 ABI 标注的下载源，每个源保存独立的大小和 SHA-256。
- 拒绝用不同内容覆盖已存在的同版本 `.tinaplug`。
- 默认移除旧 `plugins/index.json` / `packages/index.json`；如需旧客户端兼容，
  显式加 `-IncludeLegacyV1`。

## 校验索引

```powershell
pwsh ./scripts/validate-registry.ps1
```

该脚本会重新构建 Registry，并校验：

- 插件 ID、包 ID、版本号不能重复。
- `.tinaplug` 根目录必须包含 `manifest.json`。
- 插件 v2/v3 与依赖包 v2 的 `detail_url` 必须指向真实详情文件。
- v2/v3 轻量索引不能混入下载地址、checksum、release notes 等重字段。
- 插件 v2 必须是 v3 中对 `0.17.11 + API v1` 兼容的版本子集。
- 包内 manifest 的 ID、版本、API 与最低宿主版本必须和详情一致。
- 详情文件中的插件包和依赖包大小、`sha256` 必须匹配实际文件。
- native 依赖包声明的 ABI 必须与独立下载源一一对应，且每个归档只包含自己的 `lib/<abi>/`。
- 默认禁止生成旧 `plugins/index.json` / `packages/index.json`。
- 构建后不能留下未提交的生成物差异。

## GitHub Actions

- `Validate Registry`：在 `main` push、PR 和手动触发时运行，重建并校验索引；如果生成物没有提交，会直接失败。
- `Publish Registry`：手动触发发布，重建并校验 Registry，必要时自动提交生成物，然后创建 `registry-yyyyMMdd-HHmmss` tag 和 GitHub Release。Release 会额外上传单个插件包、单个依赖包、插件 v2/v3、依赖包 v2 和详情文件；GitHub 自动生成的 Source code 压缩包仅用于源码快照，不用于市场下载。

## 发布规则

- 插件发布内容放在 `sources/plugins/<plugin-id>/`，根目录必须包含 `manifest.json`。
- 依赖包发布文件放在 `packages/<package-id>/<version>/`。
- native 依赖包保留 `<package-id>.tar.xz` 作为旧客户端通用包，同时发布
  `<package-id>-arm64-v8a.tar.xz` 与 `<package-id>-x86_64.tar.xz`；当前客户端只下载匹配 ABI 的归档。
- 大文件可以不放入本仓库，但必须在索引中填写可信 CDN、对象存储或自建代理的绝对 URL。
- 不要把 Android 客户端源码、后端、数据库或管理后台放入本仓库。

## 支持项目

这个项目长期免费开源，但持续开发、测试、文档维护和设备适配都需要时间与成本。

如果它帮你节省了时间，欢迎通过爱发电支持我继续维护：

[支持无相孤君继续开源](https://ifdian.net/a/wuxianggujun)

你的支持会优先用于：

- 修复问题和维护稳定版本。
- 补充中文文档、教程和示例。
- 维护构建环境、测试设备和相关服务。
- 推动更多实用工具长期更新。
