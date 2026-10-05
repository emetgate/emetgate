# Question 3: WebSocket gateway messages: emetgate

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:15:05.188Z to 2026-10-05T09:15:39.097Z
- Model calls: 6; tool calls: 12
- Tokens: 214,759 (input 12, cache written 22,490, cache read 188,206, output 4,051)
- Cost from the token counts at 2 USD per million base tokens: $0.168
- Answer-key items named in the answer: 6 of 6

## Question

In NestJS a WebSocket gateway on the socket.io adapter has a method marked @SubscribeMessage('chat'). (1) How does Nest find that method and attach it to a connected client's socket, and which code does it? (2) When the client emits 'chat' with a payload and an acknowledgement callback, how are the data and the callback separated? (3) The handler returns a Promise of a plain object in one case and an object with event and data fields in another: how is each result sent back to the client? (4) What does the client receive when the handler throws a WsException, and what when it throws an ordinary Error?

## Tool calls, in order

1. `mcp__emetgate__emetgate_explore` `{"question": "How does the WebSocket gateway find @SubscribeMessage handlers, bind them to client sockets, split data and ack callback, send handler results back, and handle WsException vs Error?", "names": ["WebSocketsController", "SocketModule", "WsExceptionsHandler", "BaseWsExceptionFilter", "WsContextCreator", "IoAdapter", "AbstractWsAdapter"]}`
   - reply: 9,963 characters
2. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/platform-socket.io/adapters/io-adapter.ts", "symbols": ["IoAdapter.bindMessageHandlers", "IoAdapter.mapPayload"]}`
   - reply: 2,773 characters
3. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/websockets/web-sockets-controller.ts", "symbols": ["WebSocketsController.subscribeEvents", "WebSocketsController.getConnectionHandler", "WebSocketsController.subscribeConnectionEvent", "WebSocketsController.inspectEntrypointDefinitions", "WebSocketsController.pickResult"]}`
   - reply: 2,955 characters
4. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/websockets/exceptions/base-ws-exception-filter.ts", "symbols": ["BaseWsExceptionFilter.catch", "BaseWsExceptionFilter.handleError", "BaseWsExceptionFilter.handleUnknownError", "BaseWsExceptionFilter.emitMessage"]}`
   - reply: 2,225 characters
5. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/websockets/context/ws-proxy.ts", "symbols": ["WsProxy.create", "WsProxy.handleError"]}`
   - reply: 999 characters
6. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/websockets/context/ws-context-creator.ts", "symbol": "WsContextCreator.create"}`
   - reply: 2,550 characters
7. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/websockets/web-sockets-controller.ts", "symbols": ["WebSocketsController.connectGatewayToServer", "WebSocketsController.subscribeToServerEvents"]}`
   - reply: 4,855 characters
8. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/websockets/socket-module.ts", "symbol": "SocketModule.connectGatewayToServer"}`
   - reply: 862 characters
9. `mcp__emetgate__emetgate_explore` `{"question": "GatewayMetadataExplorer explore scanForServerHooks message mappings isAckHandledManually; and transform function in io-adapter", "names": ["GatewayMetadataExplorer", "MessageMappingProperties"]}`
   - reply: 11,640 characters
10. `mcp__emetgate__emetgate_skeleton` `{"file": "packages/platform-socket.io/adapters/io-adapter.ts"}`
   - reply: 1,964 characters
11. `mcp__emetgate__emetgate_search` `{"pattern": "UNKNOWN_EXCEPTION_MESSAGE ="}`
   - reply: 263 characters
12. `mcp__emetgate__emetgate_search` `{"pattern": "UNKNOWN_EXCEPTION_MESSAGE", "dir": "packages/core/constants.ts"}`
   - reply: 395 characters

## Answer

All four answers below come from reading the code in `packages/`. I didn't run anything.

## 1. How the `'chat'` method is found and attached to a socket

Discovery happens once per gateway at startup. Binding to each socket happens on every connection.

1. `@SubscribeMessage('chat')` (`websockets/decorators/subscribe-message.decorator.ts:8`) only sets metadata on the method. It sets `MESSAGE_MAPPING_METADATA = true` and `MESSAGE_METADATA = 'chat'`.
2. `SocketModule.connectGatewayToServer` (`websockets/socket-module.ts:107`) skips any provider that lacks `GATEWAY_METADATA`. It initializes the adapter, then calls `WebSocketsController.connectGatewayToServer`.
3. `WebSocketsController.subscribeToServerEvents` (`web-sockets-controller.ts:134`) calls `GatewayMetadataExplorer.explore(instance)` (`gateway-metadata-explorer.ts:25`).
   - `explore` walks the prototype's methods. `exploreMethodMetadata` keeps those with the mapping metadata and returns `{callback, message, methodName, isAckHandledManually}`.
   - Each callback is wrapped by `WsContextCreator.create(...)` (`context/ws-context-creator.ts:58`). That adds guards, interceptors, pipes, the exception filter and `WsProxy`. Request-scoped gateways get `createRequestScopedHandler` instead.
4. `subscribeEvents` (`web-sockets-controller.ts:220`) calls `adapter.bindClientConnect(server, handler)`. The handler comes from `getConnectionHandler` (`:246`), so it runs for each new connection.
5. On each connection, `subscribeMessages` (`:318`) binds the wrapped callback to the client with `callback.bind(instance, client)`. It then calls `adapter.bindMessageHandlers(...)`.
6. `IoAdapter.bindMessageHandlers` (`platform-socket.io/adapters/io-adapter.ts:49`) runs `fromEvent(socket, 'chat')` for each handler, so it is a plain `socket.on('chat', ...)` wrapped in an RxJS stream. It stops on `disconnect`.

## 2. Separating data from the ack callback

`fromEvent` emits the single argument as-is, or an array when there are several arguments. `IoAdapter.mapPayload` (`io-adapter.ts:98`) then splits them:

- If the payload is not an array, it is a function, or it is anything else.
  - A function becomes `{data: undefined, ack: fn}`.
  - Anything else becomes `{data: payload}`.
- If the payload is an array and its last element is a function, that function is the `ack`.
  - The remaining elements are `data`. One remaining element is unwrapped to `payload[0]`. Several stay as an array.
- If the payload is an array without a trailing function, the whole array is `data`.

The adapter then calls `callback(data, ack)`. The client socket is already bound as the first argument, so the `@MessageBody()` and `@ConnectedSocket()` parameter decorators resolve from it.

## 3. Sending the result back

The adapter calls `transform(callback(data, ack))`. `pickResult` (`web-sockets-controller.ts`) turns a Promise, Observable or plain value into an Observable. Each emitted value goes through this logic:

- `null` or `undefined` is dropped. Nothing is sent.
- If the value has an `event` property (`{event, data}`), the adapter calls `socket.emit(response.event, response.data)`. This is a separate server-to-client event, and the ack is not called.
- Otherwise, a plain object calls `ack(response)`, but only if the client passed an ack function and you didn't use `@Ack()` for manual acknowledgement (`isAckHandledManually`). If the client sent no ack, the plain result is silently discarded.

An Observable can emit several values, and each is processed this way.

## 4. Exceptions

`WsProxy.create` (`context/ws-proxy.ts:7`) catches synchronous or async throws. It also catches Observable errors, then returns `EMPTY` for the Observable case. It hands the error to `WsExceptionsHandler.handle`. Custom `@UseFilters` run first. If none handle it, `BaseWsExceptionFilter` runs (`exceptions/base-ws-exception-filter.ts`).

Either way, the filter calls `client.emit('exception', payload)`. The error is not sent through the ack. The ack callback is never invoked, so a client waiting on it won't get a response. The client must listen for the `'exception'` event.

- **`WsException`:**
  - A string error gives `{status: 'error', message: '<your string>'}`.
  - An object error is emitted as the object itself, with no `status` wrapper.
  - If `includeCause` is set in the filter options, a `cause` field is added to the string form. The object form is emitted unchanged.
- **Ordinary `Error`:**
  - The client gets `{status: 'error', message: 'Internal server error'}`. The real message is hidden.
  - The server logs the error, unless it is an `IntrinsicException`.
