# 接口规范（从运行中的 kap-server 抓的）

两份都是 2026-09-18 从 `kimi-code/2.0.0` 的本地服务经隧道下载的，**免鉴权**即可拉取：

```bash
curl -H "Authorization: Bearer $REFRESH_TOKEN" \
  https://code-rc.kimi.com/devices/<device_id>/openapi.json  -o reference/openapi.json
curl -H "Authorization: Bearer $REFRESH_TOKEN" \
  https://code-rc.kimi.com/devices/<device_id>/asyncapi.json -o reference/asyncapi.json
```

- `openapi.json` — REST，106 条路径，OpenAPI 3.0.3。生成 Swift 模型的来源。
- `asyncapi.json` — WebSocket，28 种消息。注意 `session_event` 的 payload 是个极大的联合体，
  **不要**整体映射成类型，见 CLAUDE.md 里的架构决定。

服务端升级后重新抓一次再比对。
