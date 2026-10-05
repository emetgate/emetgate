# Question 3: WebSocket gateway messages

| Tool | Key items | Tokens | Cost | Model calls | Tool calls |
|---|---:|---:|---:|---:|---:|
| Claude Code (built-in tools) | 6/6 | 240,674 | $0.164 | 5 | 4 |
| Serena | 6/6 | 245,139 | $0.183 | 6 | 20 |
| codebase-memory-mcp | 6/6 | 390,350 | $0.296 | 9 | 15 |
| emetgate | 6/6 | 214,759 | $0.168 | 6 | 12 |

## Answer key, written before any tool answered

1. GatewayMetadataExplorer reads the @SubscribeMessage metadata of the gateway methods (counted when the answer contains one of: `GatewayMetadataExplorer`, `gateway-metadata-explorer`)
2. WebSocketsController.subscribeMessages hands the handlers to the adapter (counted when the answer contains one of: `subscribeMessages`)
3. IoAdapter.bindMessageHandlers subscribes each message name on the socket (counted when the answer contains one of: `bindMessageHandlers`)
4. mapPayload splits the payload into data and the acknowledgement callback (counted when the answer contains one of: `mapPayload`)
5. pickResult turns a promise or plain value into an observable; a response with an event is emitted, otherwise the ack is called (counted when the answer contains one of: `pickResult`)
6. BaseWsExceptionFilter emits an 'exception' event to the client; an unknown error gets the unknown exception message (counted when the answer contains one of: `BaseWsExceptionFilter`, `base-ws-exception-filter`)
