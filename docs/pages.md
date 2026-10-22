# GitHub Pages 展示站点

`.github/workflows/pages.yml` 只把 `docs/site/index.html`、两张 Archify HTML、两份 JSON 图源和两张 GIF 复制到 `_site/`；完整报告、原始日志和实验归档不会进入部署包。页面使用相对资源路径，因此项目站点位于 `/CPU/` 时仍能找到 `architecture/` 下的资源。

Pull request 只运行 build、资源存在性、相对链接和本机绝对路径检查，并上传临时 Pages artifact；`main` 推送和手动 `workflow_dispatch` 才执行 deploy job。部署前后不修改 CPU 源码或评测输入。

## 首次启用需要在 GitHub 设置

1. 在仓库 `Settings → Pages → Build and deployment` 将 Source 设为 **GitHub Actions**，不要选择 branch/folder 构建。
2. 确认 Actions 未被仓库或组织策略禁用，并允许 workflow 使用 `actions/checkout`、`actions/upload-pages-artifact` 和 `actions/deploy-pages`。
3. 在 `Settings → Actions → General` 保留 workflow 的 `read` 内容权限；部署 job 需要 Pages write 和 OIDC ID token 权限，workflow 已按 job 声明。
4. 推送到 `main` 或手动运行 `Publish project showcase`，检查 `github-pages` environment 的部署记录和生成的 `/CPU/` 页面。
5. 若使用自定义域名，单独在 Pages 设置中配置域名和 DNS；本次 workflow 不写入 `CNAME`，也不发布自定义域名。
