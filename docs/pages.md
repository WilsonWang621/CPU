# 网站部署

网站地址为 **https://wilsonwang621.github.io/CPU/**，首页和 README 都提供两套 CPU 架构图的链接。离线浏览时，可以下载 [HTML 页面](site/index.html)及其引用的架构图。

[pages.yml](../.github/workflows/pages.yml) 将首页、两张交互架构图、JSON 图源和 GIF 放入 `_site/`，共 7 个文件。完整报告和实验日志留在 GitHub 仓库。站点内的资源使用相对路径，在 `/CPU/` 下访问时不需要额外配置。

首页默认链接到 `WilsonWang621/CPU`。构建时会根据 `GITHUB_REPOSITORY` 设置实际仓库地址，并检查源码、报告和本地资源是否存在；链接指向错误仓库或缺少文件时，构建会失败。架构图保留生成时记录的源码版本。

PR 会构建并检查网站，上传预览文件；推送到 `main` 或手动运行 workflow 时会部署。手动部署指定分支，可以更新网站而不合并代码；部署前需要在 `github-pages` 环境中允许该分支。

## 仓库设置

1. 在 `Settings → Pages → Build and deployment` 中将 Source 设为 **GitHub Actions**。
2. 允许仓库运行 `actions/checkout`、`actions/upload-pages-artifact` 和 `actions/deploy-pages`。
3. Workflow 默认只读仓库内容；部署任务另有 `pages: write` 和 `id-token: write` 权限。
4. 在 Actions 中打开 **Publish project showcase** 查看构建与部署结果，也可以点击 **Run workflow** 选择分支手动部署。

如需自定义域名，在 Pages 设置中填写域名并配置 DNS。默认使用上面的 GitHub Pages 地址。
