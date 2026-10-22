# 自托管版本清单

客户端只需要静态HTTPS文件，不需要数据库或API密钥。高级设置“版本与更新→更新来源”输入清单地址后点“验证并使用”；验证失败不覆盖当前来源。只在macOS13+完整版提供此功能。

## 部署

1. 下载Release的六包、updates.json、SHA256SUMS.txt与源码包，验证SHA256。
2. 若只托管清单，保留每个asset.url为GitHub地址，下载仍依赖GitHub。若同时镜像安装包，先上传原字节至版本目录，再将asset.url改为自己的HTTPS地址，不能改变size/sha256/edition/minOS。
3. 先验证所有资源可下载，最后原子替换updates.json。使用有效TLS证书，清单短缓存并提供ETag。示例Caddy配置（域名和目录由实际环境替换）：

```caddyfile
updates.example.com {
    root * /srv/zsir
    @manifest path /updates.json
    header @manifest Cache-Control "public, max-age=300"
    file_server
}
```

客户端地址为 `https://updates.example.com/updates.json`。本轮只交付配置说明，不部署或修改用户服务器。首次客户端获取HTTPS清单失败时显示错误，不会暗中改用GitHub。

## 原子更新与回滚

先上传版本目录所有包并校验，再把新清单写为updates.json.new；同一文件系统内将其重命名为updates.json。保留上一份清单和旧包。回滚时还原旧清单，不覆盖已有版本包。客户端不会强制降级。

## 协议

schemaVersion=1，releases数组按SemVer选择稳定版本，预览版/withdrawn=true跳过。assets必须包含os、arch、edition、minOS、url、size、sha256。macOS完整版edition=standard，12兼容版edition=monterey，禁止跨版别推荐。Windows条目只用于发布索引，本轮Windows未加入自动检测。

按最后可用系统代际保留历史release条目。使用 `script/generate-updates.py --previous 上次updates.json` 合并历史记录；避免未来提高最低系统后只保留latest使旧机器失去最后兼容版。单个清单不得超过256KiB。
