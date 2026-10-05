# Question 3: WebSocket gateway messages: Serena

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:15:04.267Z to 2026-10-05T09:15:50.617Z
- Model calls: 6; tool calls: 20
- Tokens: 245,139 (input 12, cache written 22,208, cache read 217,892, output 5,027)
- Cost from the token counts at 2 USD per million base tokens: $0.183
- Answer-key items named in the answer: 6 of 6

## Question

In NestJS a WebSocket gateway on the socket.io adapter has a method marked @SubscribeMessage('chat'). (1) How does Nest find that method and attach it to a connected client's socket, and which code does it? (2) When the client emits 'chat' with a payload and an acknowledgement callback, how are the data and the callback separated? (3) The handler returns a Promise of a plain object in one case and an object with event and data fields in another: how is each result sent back to the client? (4) What does the client receive when the handler throws a WsException, and what when it throws an ordinary Error?

## Tool calls, in order

1. `mcp__serena__initial_instructions` `{}`
   - reply: 9,181 characters
2. `mcp__serena__search_for_pattern` `{"substring_pattern": "class (WebSocketsController|GatewayMetadataExplorer|WsContextCreator|BaseWsExceptionFilter|IoAdapter|WsParamsFactory|WsExceptionsHandler)\\b", "restrict_search_to_code_files": true, "paths_exclude_glob": "**/test/**"}`
   - reply: 783 characters
3. `mcp__serena__get_symbols_overview` `{"relative_path": "packages/websockets/web-sockets-controller.ts", "depth": 1}`
4. `mcp__serena__find_symbol` `{"name_path_pattern": "GatewayMetadataExplorer", "relative_path": "packages/websockets/gateway-metadata-explorer.ts", "include_body": true}`
   - reply: 658 characters
   - reply: 2,354 characters
5. `mcp__serena__find_symbol` `{"name_path_pattern": "WsContextCreator", "relative_path": "packages/websockets/context/ws-context-creator.ts", "include_body": true}`
   - reply: 8,063 characters
6. `mcp__serena__find_symbol` `{"name_path_pattern": "BaseWsExceptionFilter", "relative_path": "packages/websockets/exceptions/base-ws-exception-filter.ts", "include_body": true}`
   - reply: 3,854 characters
7. `mcp__serena__find_symbol` `{"name_path_pattern": "WsParamsFactory", "relative_path": "packages/websockets/factories/ws-params-factory.ts", "include_body": true}`
   - reply: 691 characters
8. `mcp__serena__find_symbol` `{"name_path_pattern": "WebSocketsController/subscribeToServerEvents", "relative_path": "packages/websockets/web-sockets-controller.ts", "include_body": true}`
   - reply: 3,883 characters
9. `mcp__serena__find_symbol` `{"name_path_pattern": "WebSocketsController/subscribeEvents", "relative_path": "packages/websockets/web-sockets-controller.ts", "include_body": true}`
   - reply: 1,065 characters
10. `mcp__serena__find_symbol` `{"name_path_pattern": "WebSocketsController/subscribeMessages", "relative_path": "packages/websockets/web-sockets-controller.ts", "include_body": true}`
   - reply: 744 characters
11. `mcp__serena__find_symbol` `{"name_path_pattern": "WebSocketsController/pickResult", "relative_path": "packages/websockets/web-sockets-controller.ts", "include_body": true}`
   - reply: 506 characters
12. `mcp__serena__find_symbol` `{"name_path_pattern": "WebSocketsController/getConnectionHandler", "relative_path": "packages/websockets/web-sockets-controller.ts", "include_body": true}`
   - reply: 863 characters
13. `mcp__serena__find_symbol` `{"name_path_pattern": "WebSocketsController/inspectEntrypointDefinitions", "relative_path": "packages/websockets/web-sockets-controller.ts", "include_body": true}`
   - reply: 888 characters
14. `mcp__serena__find_symbol` `{"name_path_pattern": "IoAdapter", "relative_path": "packages/platform-socket.io/adapters/io-adapter.ts", "include_body": true}`
15. `mcp__serena__search_for_pattern` `{"substring_pattern": "class (WsProxy|AbstractWsAdapter)\\b", "restrict_search_to_code_files": true}`
   - reply: 3,961 characters
   - reply: 185 characters
16. `mcp__serena__read_file` `{"relative_path": "packages/websockets/context/ws-proxy.ts"}`
   - reply: 1,187 characters
17. `mcp__serena__search_for_pattern` `{"substring_pattern": "subscribeToServerEvents|connectGatewayToServer", "relative_path": "packages/websockets", "paths_exclude_glob": "**/*.spec.ts", "context_lines_before": 3, "context_lines_after": 3}`
18. `mcp__serena__read_file` `{"relative_path": "packages/websockets/errors/ws-exception.ts"}`
   - reply: 2,740 characters
   - reply: 689 characters
19. `mcp__serena__read_file` `{"relative_path": "packages/websockets/exceptions/ws-exceptions-handler.ts"}`
   - reply: 1,245 characters
20. `mcp__serena__search_for_pattern` `{"substring_pattern": "switchToWs\\(\\)[^}]*?\\}", "relative_path": "packages/core/helpers/execution-context-host.ts"}`
   - reply: 345 characters

## Answer

All paths below are relative to the repo root, and I read the code in `packages/websockets` and `packages/platform-socket.io`. Line numbers are 1-based.

## 1. Finding `@SubscribeMessage('chat')` and attaching it to a socket

**Discovery (once, at bootstrap)**
- `SocketModule.connectGatewayToServer` (`socket-module.ts:106`) runs for each provider and calls `WebSocketsController.connectGatewayToServer`. That calls `subscribeToServerEvents` (`web-sockets-controller.ts:133`).
- `subscribeToServerEvents` calls `GatewayMetadataExplorer.explore(instance)` (`gateway-metadata-explorer.ts:24`).
- `explore` walks the gateway prototype's method names. For each one, `exploreMethodMetadata` reads `MESSAGE_MAPPING_METADATA` from the method function, which `@SubscribeMessage` set. Methods without it are dropped.
- For the rest it returns `{ callback, message: 'chat', methodName, isAckHandledManually }`. `isAckHandledManually` is true if the method has an `@Ack()` parameter.
- Each callback is then wrapped by `WsContextCreator.create(...)` (`ws-context-creator.ts`). The wrapper runs guards, interceptors and pipes, then the method, with errors going to `WsProxy` and the exception filters. If the gateway is request-scoped or there are global scoped enhancers, `createRequestScopedHandler` builds the wrapper instead.

**Attachment (per connection)**
- `subscribeEvents` (`web-sockets-controller.ts:219`) builds a connection handler with `getConnectionHandler` and registers it with `adapter.bindClientConnect(server, handler)`. For socket.io that is the server's `connection` event.
- When a client connects, the handler (`:245`) calls `subscribeMessages` (`:317`). That binds each handler to the client with `callback.bind(instance, client)`.
- It then calls `adapter.bindMessageHandlers(client, handlers, transform)`. In `IoAdapter` (`io-adapter.ts:~42`), each handler becomes `fromEvent(socket, 'chat')`, which is an rxjs listener on that socket.

## 2. Separating data from the ack callback

`IoAdapter.mapPayload` (`io-adapter.ts:~88`) does it. socket.io hands the listener `(...args)`, and `fromEvent` collects them into an array.

- **Not an array:** a bare function becomes `{ data: undefined, ack: fn }`. Anything else becomes `{ data: payload }`.
- **Array whose last element is a function:** that element is the `ack`. `data` is `payload[0]` when exactly one item remains, and the array of the remaining items otherwise.
- **Array with no trailing function:** `data` is the whole array and there is no `ack`.

One quirk in the code: `size === 1 ? payload[0] : payload.slice(0, size)`. If the client sends only an ack, `size` is 0 and `data` is `[]`, not `undefined`.

The adapter then calls `callback(data, ack)`. Because the callback was bound with the client, the wrapper receives `[client, data, ack]`, and `WsProxy` appends the pattern (`'chat'`) as the last element.

`WsParamsFactory.exchangeKeyForValue` maps decorators onto those arguments:
- `@ConnectedSocket()` gets `args[0]`.
- `@MessageBody()` gets `args[1]`, or `args[1][key]` if a key is given.
- `@Ack()` gets the first function in `args`.

## 3. Sending results back

Results go through `WebSocketsController.pickResult` (`:335`) into the transform. It awaits the result, passes an Observable through, wraps a nested Promise, and wraps anything else with `of(result)`. The rxjs stream then drops `null` and `undefined` responses. For each remaining response, the subscriber in `IoAdapter.bindMessageHandlers` does this:

- **Object with `event`** (e.g. `{ event: 'chat-reply', data: ... }`): `socket.emit(response.event, response.data)`. This is a separate server-to-client event, not an ack. The check is only `if (response.event)`, so any returned object with a truthy `event` field is treated this way.
- **Anything else, including a plain object:** if the client supplied an ack and the handler doesn't use `@Ack()`, `ack(response)` is called. If the client sent no ack, the value is silently discarded.
- **`@Ack()` used:** nothing is sent automatically. The handler is expected to call the ack itself.

An Observable handler can emit several values. Each one goes through the same logic, though a socket.io ack can only meaningfully fire once.

## 4. `WsException` versus an ordinary `Error`

Both end up in `WsProxy.handleError`, then `WsExceptionsHandler.handle`. Custom `@UseFilters` filters run first, and if one matches, the default filter doesn't run. Otherwise `BaseWsExceptionFilter.handleError` (`base-ws-exception-filter.ts`) emits an `'exception'` event to the client with `client.emit('exception', payload)`. Native `ws` clients get `send(JSON.stringify({event, data}))` instead. The ack callback is not called in either case.

**`WsException`:**
- **`new WsException('msg')`:** the client gets `{ status: 'error', message: 'msg', cause: { pattern: 'chat', data: <payload> } }`. `cause` is included by default (`includeCause: true`). You can change it with the `causeFactory` option, or turn it off with `includeCause: false`.
- **`new WsException({ ... })`:** the object is emitted as-is, with no `status` or `cause` added.

**Ordinary `Error`:** the message is not leaked. The client gets `{ status: 'error', message: 'Internal server error', cause: { pattern, data } }`, with `cause` governed by the same options. The error is logged server-side through the `WsExceptionsHandler` logger, unless it is an `IntrinsicException`.

One related detail: if the filter itself throws, `IoAdapter` catches the error and logs it so the socket stays alive. In that case the client gets neither a response nor an exception event.
