# Question 3: WebSocket gateway messages: codebase-memory-mcp

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:15:06.424Z to 2026-10-05T09:15:56.858Z
- Model calls: 9; tool calls: 15
- Tokens: 390,350 (input 18, cache written 43,333, cache read 341,601, output 5,398)
- Cost from the token counts at 2 USD per million base tokens: $0.296
- Answer-key items named in the answer: 6 of 6

## Question

In NestJS a WebSocket gateway on the socket.io adapter has a method marked @SubscribeMessage('chat'). (1) How does Nest find that method and attach it to a connected client's socket, and which code does it? (2) When the client emits 'chat' with a payload and an acknowledgement callback, how are the data and the callback separated? (3) The handler returns a Promise of a plain object in one case and an object with event and data fields in another: how is each result sent back to the client? (4) What does the client receive when the handler throws a WsException, and what when it throws an ordinary Error?

## Tool calls, in order

1. `mcp__codebase-memory-mcp__list_projects` `{}`
2. `mcp__codebase-memory-mcp__search_code` `{"pattern": "SubscribeMessage|MESSAGE_MAPPING_METADATA", "project": "C-benchmark-codebase-memory-nest", "path_filter": "packages/websockets|packages/platform-socket.io", "regex": true, "limit": 30}`
   - reply: 3,335 characters
   - reply: 4,707 characters
3. `mcp__codebase-memory-mcp__get_code_snippet` `{"qualified_name": "C-benchmark-codebase-memory-nest.packages.websockets.web-sockets-controller.WebSocketsController.subscribeMessages", "project": "C-benchmark-codebase-memory-nest"}`
   - reply: 2,183 characters
4. `mcp__codebase-memory-mcp__get_code_snippet` `{"qualified_name": "C-benchmark-codebase-memory-nest.packages.websockets.web-sockets-controller.WebSocketsController.getConnectionHandler", "project": "C-benchmark-codebase-memory-nest"}`
   - reply: 2,408 characters
5. `mcp__codebase-memory-mcp__get_code_snippet` `{"qualified_name": "C-benchmark-codebase-memory-nest.packages.websockets.gateway-metadata-explorer.GatewayMetadataExplorer.exploreMethodMetadata", "project": "C-benchmark-codebase-memory-nest"}`
   - reply: 2,351 characters
6. `mcp__codebase-memory-mcp__search_graph` `{"project": "C-benchmark-codebase-memory-nest", "file_pattern": "packages/websockets/**", "label": "Method", "name_pattern": "^(pickResult|mergeAckAndResponse|assignToResponse|transformToObservable|subscribeToResponse|handleError|bindMessageHandlers|create|bindEvents|assignChannelsToServer|subscribeConnectionEvent|subscribeInitEvent|subscribeDisconnectEvent|connectGatewayToServer|applyConfigurationToServer|getAckParamIndex|isAckFn|forEachBinding|bindClientConnectEvent|bindMessageHandler|bindEvent|getHandler|createHandler|bindEventHandlers|bind)$", "limit": 40}`
   - reply: 19,856 characters
7. `mcp__codebase-memory-mcp__search_code` `{"pattern": "bindMessageHandlers|mergeMap|isAckHandledManually|bindMessageHandler", "project": "C-benchmark-codebase-memory-nest", "path_filter": "^packages/(platform-socket\\.io|websockets)/[^t]", "mode": "files"}`
   - reply: 261 characters
8. `mcp__codebase-memory-mcp__get_code_snippet` `{"qualified_name": "C-benchmark-codebase-memory-nest.packages.websockets.web-sockets-controller.WebSocketsController.pickResult", "project": "C-benchmark-codebase-memory-nest"}`
   - reply: 1,181 characters
9. `mcp__claude-in-chrome__get_page_text` `{"tabId": 0}`
   - reply: 90 characters
10. `mcp__codebase-memory-mcp__search_graph` `{"project": "C-benchmark-codebase-memory-nest", "file_pattern": "packages/(platform-socket.io|websockets|platform-ws)/**/*.ts", "qn_pattern": ".*(IoAdapter|AbstractWsAdapter|WsExceptionsHandler|WsException|BaseWsExceptionFilter|WsProxy)\\..*", "limit": 40}`
   - reply: 41 characters
11. `mcp__codebase-memory-mcp__search_code` `{"pattern": "bindMessageHandlers", "project": "C-benchmark-codebase-memory-nest", "mode": "full", "path_filter": "^packages/(platform-socket\\.io/adapters|websockets/adapters)/"}`
   - reply: 4,353 characters
12. `mcp__codebase-memory-mcp__get_code_snippet` `{"qualified_name": "C-benchmark-codebase-memory-nest.packages.websockets.context.ws-proxy.WsProxy.create", "project": "C-benchmark-codebase-memory-nest"}`
   - reply: 2,354 characters
13. `mcp__codebase-memory-mcp__get_code_snippet` `{"qualified_name": "C-benchmark-codebase-memory-nest.packages.websockets.exceptions.base-ws-exception-filter.BaseWsExceptionFilter.handleError", "project": "C-benchmark-codebase-memory-nest"}`
   - reply: 2,417 characters
14. `mcp__codebase-memory-mcp__search_code` `{"pattern": "mapPayload|handleUnknownError|emitMessage|subscribeToServerEvents|public explore\\(|scanForServerHooks|hasAckDecorator|private reflectMessagesMetadata|reflectMessagesMetadata", "project": "C-benchmark-codebase-memory-nest", "regex": true, "mode": "full", "path_filter": "^packages/(platform-socket\\.io/adapters|websockets/(exceptions|web-sockets-controller|gateway-metadata-explorer))", "limit": 15}`
   - reply: 34,199 characters
15. `mcp__codebase-memory-mcp__search_code` `{"pattern": "class WsExceptionsHandler|class WsProxy|wsProxy.create|getArgs|handlerFn|handle\\(exception", "project": "C-benchmark-codebase-memory-nest", "regex": true, "mode": "full", "path_filter": "^packages/websockets/(exceptions/ws-exceptions-handler|context/ws-(proxy|context-creator))\\.ts", "limit": 6}`
   - reply: 5,962 characters

## Answer

All paths are under `packages/` in this repo. I read the code through the code graph and didn't run anything. Two details I didn't open are marked below.

## 1. How `@SubscribeMessage('chat')` gets attached to a socket

**Decoration.** `SubscribeMessage` (`websockets/decorators/subscribe-message.decorator.ts:8`) only sets reflect-metadata on the method. It writes `MESSAGE_MAPPING_METADATA = true` and `MESSAGE_METADATA = 'chat'`.

**Discovery at bootstrap.**
- `SocketModule.connectGatewayToServer` calls `WebSocketsController.connectGatewayToServer` (`websockets/web-sockets-controller.ts:73`). That reads the gateway options and port, then calls `subscribeToServerEvents` (`:134`).
- `subscribeToServerEvents` calls `GatewayMetadataExplorer.explore(instance)` (`websockets/gateway-metadata-explorer.ts:25`). This scans every method on the prototype.
- `exploreMethodMetadata` (`:33`) keeps a method only if `MESSAGE_MAPPING_METADATA` is defined. It returns `{callback, message, methodName, isAckHandledManually}`.
- `isAckHandledManually` is true if the method has an `@Ack()` parameter (`hasAckDecorator`, `:59`).
- Each callback is wrapped by `WsContextCreator.create` (`websockets/context/ws-context-creator.ts:58`). The wrapper applies guards, pipes, interceptors and filters, and the whole thing runs inside `WsProxy`. Request-scoped gateways get `createRequestScopedHandler` instead.

**Attaching to a client.**
- `subscribeEvents` (`:~220`) builds `getConnectionHandler` (`:246`) and registers it with `adapter.bindClientConnect(server, handler)`. For socket.io this is `server.on('connection', …)`, defined in `AbstractWsAdapter`.
- On each connection, the handler calls `subscribeMessages(subscribersMap, client, instance)` (`:318`). That binds each callback to `(instance, client)` and calls `adapter.bindMessageHandlers(client, handlers, transform)`.
- `IoAdapter.bindMessageHandlers` (`platform-socket.io/adapters/io-adapter.ts:49`) does the actual hookup. For each handler it runs `fromEvent(socket, 'chat')` and subscribes, with `takeUntil(disconnect$)` to clean up.

## 2. Separating data from the ack callback

`IoAdapter.mapPayload` (`io-adapter.ts:98`) does this. socket.io hands `fromEvent` an array of the emitted args.
- A non-array payload that is a function means no data, so `{data: undefined, ack: fn}`.
- If the last element is a function, it is the ack. The rest is the data: a single argument is unwrapped to `payload[0]`, otherwise the remaining args are kept as an array.
- Otherwise there is no ack and `data` is the payload unchanged.

Then `callback(data, ack)` is called. The bound callback already has `client` as its first argument, and `WsProxy` appends the pattern as a final arg. Parameter decorators (`@MessageBody()`, `@ConnectedSocket()`, `@Ack()`) pick from those args.

## 3. Sending the handler's result back

The handler's return value goes through `transform`, which is `fromPromise(this.pickResult(data)).pipe(mergeAll())` (`:318`). `pickResult` (`:336`) awaits the result and turns it into an Observable. Observables pass through, promises are wrapped, and plain values go through `of()`.

In `bindMessageHandlers`, `null` and `undefined` results are dropped (`filter(!isNil)`). Each remaining value is emitted like this:
- **Object with `event`** (`{event: 'x', data}`): `socket.emit(response.event, response.data)`. It is a separate server-to-client event, and the ack is not called.
- **Plain object** (no `event`): if `!isAckHandledManually` and the client supplied an ack function, `ack(response)` is called, so the client's callback receives the object. If the client sent no ack, nothing is sent. If you use `@Ack()`, Nest doesn't auto-ack and you call it yourself.

A thrown or rejected emit is caught and logged, so it can't crash the process.

## 4. `WsException` versus an ordinary `Error`

Both are caught in `WsProxy.create` (`ws-proxy.ts:7`) for sync or async throws and for Observable errors. They go to `WsExceptionsHandler.handle`. Custom `@UseFilters` run first. If none matches, `BaseWsExceptionFilter` handles it.

The result is emitted with `emitMessage` (`base-ws-exception-filter.ts:130`) as `client.emit('exception', payload)`. It is a separate `'exception'` event, **not** the ack. The ack never fires on an error, because the proxy returns nothing and `filter(!isNil)` drops it.

- **`WsException`** (`handleError`, `:67`):
  - If `getError()` returns an object, that object is the payload as is.
  - If it returns a string, the payload is `{status: 'error', message: <string>}`.
  - If `includeCause` is set, `cause` is added from `causeFactory(pattern, data)`.
- **Ordinary `Error`** (`handleUnknownError`, `:95`): the client gets only `{status: 'error', message: MESSAGES.UNKNOWN_EXCEPTION_MESSAGE}`, plus `cause` if enabled. I didn't open the constant, but I believe it is "Internal server error". The real message and stack are logged server-side with `logger.error`, unless the error is an `IntrinsicException`.

I also didn't open `BaseWsExceptionFilter.catch`. I assumed it passes `(client, exception, cause)` to `handleError`, based on the call graph.
