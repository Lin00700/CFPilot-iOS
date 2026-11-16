# CFPilot-iOS

[CFPilot](https://github.com/xmwengxing/CFPilot) 的独立 iOS 客户端（iOS 17+，SwiftUI）。
水墨视觉，深色模式完整支持；凭据只落在本机钥匙串。

> 本仓库只包含 Swift 源码与工程配置，不包含上游内核产物。
> 内核（控制面 / 数据面）在部署时从上游 Release 通道 `kernel-latest` 拉取，直连失败会自动走下载镜像。

## 功能

### 1. 一键双面部署

与官方 CLI 的 `deploy --pages-split` 对齐的完整流程，全部在 App 内完成：

1. **校验凭据** —— `GET /accounts` 确认账号，`/user/tokens/verify`（失败回退 `/accounts/{id}/tokens/verify`）读 Token 元信息。
2. **准备独立 KV** —— 有部署清单则沿用（更新模式）；没有就新建 `cfp-xxxxxx`，并连续读取 `CFP_DEPLOY_MANIFEST` / `config` / `CONFIG` 三个键确认命名空间是干净的。
3. **归属校验** —— 写入任何键之前判定 `empty / owned / occupied / foreign / stale`。
   `foreign`（他人项目的 `config` 键）与 `stale`（有 `CONFIG` 无清单）一律阻断；读不到也按「不可放行」处理。
4. **建项目 → 配变量 → 再部署** —— Pages 的绑定与变量只对**之后**的部署生效，所以顺序固定：控制面/数据面项目 → `deployment_configs`（KV 绑定 `KV` + `K`，环境变量）→ 写 KV 的 `CONFIG`。
5. **部署数据面**（Pages 或 Workers），再同步控制面的 `DATA_HOST`，最后部署控制面。
6. **回写部署清单** `CFP_DEPLOY_MANIFEST`（v1，与官方 CLI 同结构），返回面板 URL 与密码。

环境变量与官方 CLI 完全一致：

| 面 | 变量 |
| --- | --- |
| 控制面 | `PANEL_PATH` `PANEL_PASSWORD` `DATA_HOST` |
| 数据面 | `UUID` `TROJAN_PASSWORD` `WS_PATH` `PATH` `ENABLE_TROJAN` `ENABLE_XHTTP` `RESOLVE_PREFERRED` |

平台行为也按官方结论处理：Pages 对含代理内容的数据面二次部署会返回 `8000119 blocked`，
**一次失败就停**，不换名重建、不连续重试（连续重试会累积账号风控画像）。

### 2. 真连接优选器

- 候选：Cloudflare 官方 15 个 IPv4 网段随机采样，或自己填 IP / CIDR。
- 探测：`Network.framework` 真实 **TCP 建连 + TLS 握手**，SNI 用你自己的数据面域名；握手成功后再发一次 `HTTP/1.1` 请求，读状态码与 `cf-ray` 机房。
- 排序：按 **TLS 握手耗时**（客户端实际等待的时间），同时列出 TCP 耗时，避免「TCP 快 TLS 慢」的假优选。
- 一键复制 IP 列表；或直接写入实例 KV 的 `LOCAL_PREFERRED_IPS`（同时清空 `CONFIG.add`，与面板扫描回填语义一致）。

### 3. 内置控制面板

`WKWebView` 直接打开 `https://<控制面域名><面板路径>`，密码可显示 / 复制。

## 构建

需要 Xcode 15+ 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate
open CFPilot.xcodeproj
```

命令行构建未签名 IPA：

```bash
xcodebuild -project CFPilot.xcodeproj -scheme CFPilot \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGNING_IDENTITY="" build

mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/CFPilot.app Payload/
zip -qry CFPilot-unsigned.ipa Payload
```

或用仓库里的 `.github/workflows/build-ipa.yml`，在 GitHub Actions 的 macOS runner 上自动出包（未签名 IPA 走 Artifact 与 Release）。

## 目录

```
project.yml                  XcodeGen 工程定义
Config/Info.plist            Info.plist（SceneManifest / ATS / 权限说明）
Sources/App                  入口
Sources/Design               水墨主题、组件
Sources/Models               数据模型、随机值
Sources/Services             Keychain / Cloudflare API / 部署流程 / 内核下载 / 真连接探测 / 面板同步
Sources/Views                部署向导、优选器、面板、设置
Sources/Resources/Assets.xcassets  AppIcon（水墨纸鸢）与主题色
```

## Cloudflare Token 权限

Pages 数据面（默认）：

- Account / Account Settings / Read
- Account / Pages / Edit
- Account / Workers KV Storage / Edit

Workers 数据面另需：

- Account / Workers Scripts / Edit

自定义域名不由本 App 托管：Workers 形态需要你到 Cloudflare 控制台 → Workers 和 Pages → 你的脚本 → 「域」标签页自行绑定，
再在面板「设置 → 数据面域名」填一次。

## 许可

本仓库的 Swift 源码由 Lin00700 维护。上游 CFPilot 采用 AGPL-3.0，内核产物不随本仓库分发，运行时从上游发布获取。
