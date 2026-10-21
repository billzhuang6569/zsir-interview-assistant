
## 国内服务器构建

`apt`/`npm` 官方源在国内很慢时，构建前在 `server/` 旁放 `.env` 或导出环境变量：

```sh
APT_MIRROR=mirrors.aliyun.com NPM_REGISTRY=https://registry.npmmirror.com docker compose -f server/docker-compose.yml up --build -d
```
