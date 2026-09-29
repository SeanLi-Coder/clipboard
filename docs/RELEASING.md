# 发布 ClipShelf 更新

ClipShelf 1.1.0 起使用固定版本 Sparkle 2.10.0，发布 Apple Silicon DMG 和备用 ZIP。默认 `CFBundleVersion` 与 `CFBundleShortVersionString` 相同，例如 `1.1.0`；正式发布必须递增版本号，同一版本的安装包发布后不覆盖。

## 一次性配置

- `Resources/Info.plist` 中的 `SUPublicEDKey` 是 App 信任的 Ed25519 公钥；`SUFeedURL` 指向 `https://raw.githubusercontent.com/SeanLi-Coder/clipboard/updates/appcast.xml`。
- 发布私钥保存在维护者 macOS Keychain 的 `com.seanli.clipshelf.updates` account，以及仓库的 GitHub Actions secret **`SPARKLE_PRIVATE_KEY`**。私钥不写入仓库、发布资产、工作流输出或日志。
- 工作流需要仓库 `contents: write` 权限，用于上传 Release 文件和推送 `updates` 分支。请保留该分支；它是 App 的长期更新地址。
- 私钥必须妥善备份。当前 App 没有 Developer ID 签名，丢失旧私钥后无法直接依靠 Apple 身份轮换到新密钥；不要随意替换已经发布的公钥。

自动更新会验证更新信息和安装包的 EdDSA 签名。这不能替代 Apple Developer ID 签名或公证，首次安装仍可能需要用户按系统提示确认。依据：[Sparkle 官方集成文档](https://sparkle-project.org/documentation/) 与 [发布指南](https://sparkle-project.org/documentation/publishing/)。

## 常规发布

1. 更新源码和用户说明，确定新的 `x.y.z` 版本。
2. 在 Apple Silicon Mac 上运行测试、打包和隔离更新验收。
3. 将改动提交到 `main`，推送对应的 `vX.Y.Z` tag；`Publish macOS update` workflow 会完成正式发布。

```bash
./scripts/test.sh --parallel
CLIPSHELF_VERSION=1.1.1 ./scripts/package.sh --arch arm64
./scripts/verify-dmg.sh dist/ClipShelf-1.1.1-macOS-arm64.dmg
./scripts/verify-update.sh dist/ClipShelf.app
git tag v1.1.1
git push origin v1.1.1
```

也可以先在 GitHub 发布使用该 tag 的稳定版 Release，工作流同样会补齐安装包和更新信息；预发布版不会更新稳定 feed。手动重试可在 Actions 选择 `Publish macOS update → Run workflow`，填写已经存在的 tag。

流程依次执行测试、打包、DMG / 启动 / 真实更新验证，然后从 secret 写入权限为 `0600` 的临时密钥文件，通过官方 `generate_appcast` 和 `sign_update` 签名与验证。安装包及 Appcast 上传并公开后，才将 Appcast 原始签名字节推送到 `updates` 分支，避免客户端提前读到不可下载的更新。

不同版本的 feed 发布串行执行，并比较数字版本：旧版本不会覆盖新版本；相同版本、相同 feed 可安全重试，相同版本但内容不同会失败；Git push 不使用 `--force`。完整 Release 会复用已经发布的文件，重新验证签名、版本、下载 URL、长度和校验和。只有部分发布资产存在时流程停止，维护者应先核实这些文件，不能用新构建静默覆盖它们。

## 本地签名与验证

普通构建、运行 App 和剪贴板功能不需要私钥。只有生成正式 Appcast 才需要签名权限。

```bash
# Use the existing maintenance account in Keychain.
./scripts/sign-feed.sh dist/ClipShelf-1.1.0-macOS-arm64.dmg

# Override the Keychain account explicitly.
./scripts/sign-feed.sh dist/ClipShelf-1.1.0-macOS-arm64.dmg --account com.seanli.clipshelf.updates

# CI can supply a private key through a protected temporary file.
./scripts/sign-feed.sh dist/ClipShelf-1.1.0-macOS-arm64.dmg --key-file /secure/path/private-key

# Verify existing release files without changing them.
./scripts/verify-feed.sh dist/appcast.xml dist/ClipShelf-1.1.0-macOS-arm64.dmg
```

默认输出 `dist/appcast.xml` 与 `dist/appcast.xml.sha256`；`--output` 可改变输出路径。`SPARKLE_KEY_ACCOUNT` 可设置默认 Keychain account。工作流始终显式传入 `--key-file`，不会回退读取 CI Keychain。

`scripts/download-sparkle-tools.sh` 从官方 GitHub 下载 Sparkle **2.10.0** 工具，并验证固定 SHA-256：

```text
c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
```

工具仅缓存在 `.build/sparkle-tools/`。App 使用 SwiftPM 下载并校验的 Sparkle framework；打包脚本保留 framework 的符号链接，薄化为 arm64，再按 helper、framework、App 的顺序签名。

## 发布后检查

- 在 Release 页面确认 DMG、ZIP、各自 `.sha256` 和 `appcast.xml` 均可下载。
- 检查 `updates` 分支的 Appcast 版本、下载链接与 Release 对应，签名文件发布后不要手工修改。
- 从安装在「应用程序」中的上一版 ClipShelf 选择「检查更新…」，确认可下载、安装、重新启动，历史与设置保留。
- 1.0.0 尚无更新框架，需手动安装一次 1.1.0 或更新版本。
- `verify-update.sh` 使用临时 App、临时密钥和合成历史，验证升级、重启与损坏签名拒绝；它不会操作真实剪贴板、用户历史或维护者密钥。
