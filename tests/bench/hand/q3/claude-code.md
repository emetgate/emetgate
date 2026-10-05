# Question 3: WebSocket gateway messages: Claude Code (built-in tools)

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:15:05.900Z to 2026-10-05T09:15:39.871Z
- Model calls: 5; tool calls: 4
- Tokens: 240,674 (input 10, cache written 21,768, cache read 215,546, output 3,350)
- Cost from the token counts at 2 USD per million base tokens: $0.164
- Answer-key items named in the answer: 6 of 6

## Question

In NestJS a WebSocket gateway on the socket.io adapter has a method marked @SubscribeMessage('chat'). (1) How does Nest find that method and attach it to a connected client's socket, and which code does it? (2) When the client emits 'chat' with a payload and an acknowledgement callback, how are the data and the callback separated? (3) The handler returns a Promise of a plain object in one case and an object with event and data fields in another: how is each result sent back to the client? (4) What does the client receive when the handler throws a WsException, and what when it throws an ordinary Error?

## Tool calls, in order

1. `Bash` `{"command": "cd /c/benchmark/plain-claude/nest/packages && ls websockets/*.ts | head -50; ls platform-socket.io/adapters; grep -n \"\" websockets/socket-module.ts | sed -n 1,200p | grep -n \"WsExceptionsHandler\\|ExceptionFilter\\|subscribeEvents\\|connectGatewayToServer\\|SocketServerProvider\" "}`
   - reply: 815 characters
2. `Bash` `{"command": "cd /c/benchmark/plain-claude/nest/packages/websockets && cat web-sockets-controller.ts | sed -n 1,400p; cat gateway-metadata-explorer.ts"}`
   - reply: 15,848 characters
3. `Bash` `{"command": "cd /c/benchmark/plain-claude/nest/packages && cat platform-socket.io/adapters/io-adapter.ts | sed -n 1,200p; cat websockets/context/ws-context-creator.ts | sed -n 40,200p; cat websockets/context/ws-proxy.ts websockets/exceptions/base-ws-exception-filter.ts; grep -n \"ack\\|Ack\" -i websockets/context/ws-context-creator.ts websockets/factories/*.ts websockets/utils/*.ts | head -30"}`
   - reply: 17,276 characters
4. `Bash` `{"command": "cd /c/benchmark/plain-claude/nest/packages/websockets && cat factories/ws-params-factory.ts exceptions/ws-exceptions-handler.ts | head -120; grep -n \"SubscribeMessage\" -A22 decorators/subscribe-message.decorator.ts | head -50; grep -n \"getData\\|getClient\\|getPattern\" -A4 ../common/../websockets/context/ws-arguments-host.ts 2>/dev/null | head; grep -rn \"getData()\" ../core/helpers/execution-context-host.ts ../common/ -l | head -3"}`
   - reply: 2,306 characters

## Answer

All paths below are relative to `packages/`.

## 1. Finding the `@SubscribeMessage('chat')` method and attaching it to a socket

**Marking.** `SubscribeMessage` (`websockets/decorators/subscribe-message.decorator.ts:8`) only writes metadata onto the method function. It sets `MESSAGE_MAPPING_METADATA = true` and `MESSAGE_METADATA = 'chat'`.

**Discovery.**
- `SocketModule` (`websockets/socket-module.ts`) runs `connectGatewayToServer` for each gateway provider. It calls `WebSocketsController.connectGatewayToServer` and then `subscribeToServerEvents` (`websockets/web-sockets-controller.ts`).
- `subscribeToServerEvents` calls `GatewayMetadataExplorer.explore(instance)` (`websockets/gateway-metadata-explorer.ts`).
- `explore` walks the prototype's method names and keeps those with `MESSAGE_MAPPING_METADATA`. Each gets `{message: 'chat', callback, methodName, isAckHandledManually}`.
- `isAckHandledManually` is true if the method has an `@Ack()` parameter.

**Wrapping.**
- Each callback is wrapped by `WsContextCreator.create` (`websockets/context/ws-context-creator.ts`). That adds guards, interceptors, pipes and the exception filter, all run through `WsProxy`.
- With a request-scoped gateway or global scoped enhancers, `createRequestScopedHandler` does the wrapping per request instead.

**Attaching to the socket.**
- `subscribeEvents` calls `adapter.bindClientConnect(server, handler)`. The handler comes from `getConnectionHandler`.
- On each connection, that handler runs `subscribeMessages(subscribersMap, client, instance)`. This binds each callback with `callback.bind(instance, client)`.
- It then calls `adapter.bindMessageHandlers(client, handlers, transform)`.
- The socket.io implementation is `IoAdapter.bindMessageHandlers` in `platform-socket.io/adapters/io-adapter.ts`. It does `fromEvent(socket, 'chat')`, an RxJS stream over `socket.on('chat', …)`.
- The stream is cut off on `disconnect` with `takeUntil(disconnect$)`.

## 2. Separating the data from the acknowledgement callback

`socket.io` passes the event arguments to the listener, and the stream emits them as `payload`. `IoAdapter.mapPayload` splits them (`io-adapter.ts`):
- If `payload` is not an array, it is either a bare function or plain data.
  - A bare function means `data: undefined, ack: fn`.
  - Anything else means `data: payload`.
- If `payload` is an array and its last element is a function, that element is `ack`.
  - The rest is the data. One remaining element is unwrapped, and several stay an array.
- Otherwise the array is all data and there is no ack.

The adapter then calls `callback(data, ack)`. The `client` was already bound as the first argument, and `WsProxy` appends the pattern `'chat'` as the last. So the handler's args are `[client, data, ack, 'chat']`.

`WsParamsFactory` (`websockets/factories/ws-params-factory.ts`) maps decorators to those args:
- `@ConnectedSocket()` is `args[0]`.
- `@MessageBody()` is `args[1]`.
- `@Ack()` is the first function found in the args.

## 3. Sending the handler's result back

**Result handling.**
- `subscribeMessages` passes `bindMessageHandlers` a `transform` function.
- It runs `fromPromise(pickResult(data)).pipe(mergeAll())`. `pickResult` awaits the result and normalises it to an Observable (`web-sockets-controller.ts`).
- Promises, plain values and Observables therefore all flow through one path.
- `IoAdapter` drops `null` and `undefined` results with `filter(!isNil)`. It then handles each emitted `response` in the subscriber (`io-adapter.ts`).

**Plain object, for example `{ ok: true }`.**
- It has no `event` field.
- If `ack` is a function and the handler didn't take `@Ack()`, the adapter calls `ack(response)`.
- The client's acknowledgement callback receives the object.
- If the client sent no ack, nothing is sent.
- With `@Ack()`, `isAckHandledManually` is true, so the adapter never calls `ack` and the handler must call it.

**`{ event: 'x', data: … }`.**
- `response.event` is truthy, so the adapter calls `socket.emit('x', response.data)`.
- The client gets a separate `'x'` event, and the ack is not called.
- This applies to any result with a truthy `event` field, even when an ack was supplied.

**Observables.** An Observable handler emits each value through the same code, so each value is acked or emitted. A socket.io ack callback only fires once, so extra values are lost on that path.

## 4. `WsException` versus an ordinary `Error`

A throw inside the handler or its guards, pipes or interceptors goes to `WsProxy.handleError`. That calls `WsExceptionsHandler.handle`. A custom `@UseFilters` filter that matches is used if there is one. Otherwise `BaseWsExceptionFilter` (`websockets/exceptions/base-ws-exception-filter.ts`) runs. In both cases the client receives an `'exception'` event via `client.emit('exception', payload)`, not an ack. The `ack` callback is never called for errors.

**`WsException`.** The payload depends on what you passed in `getError()`:
- A string, for example `new WsException('Nope')`, gives `{ status: 'error', message: 'Nope', cause: { pattern: 'chat', data: <the payload> } }`.
- An object, for example `new WsException({ code: 1 })`, is sent as is, with no `status` and no `cause`.
- `cause` is included by default and can be turned off with `includeCause: false`. It can be reshaped with `causeFactory`.

**Ordinary `Error`.**
- The client gets `{ status: 'error', message: 'Internal server error', cause: { pattern: 'chat', data } }`. The message is `MESSAGES.UNKNOWN_EXCEPTION_MESSAGE`, so the real error text is not leaked.
- The error is logged server-side with the `WsExceptionsHandler` logger.
- A guard that denies access throws `WsException('Forbidden resource')`, so it takes the first path.

**If a custom filter rethrows.** `IoAdapter`'s `catchError` logs it and the client gets nothing. That keeps the event's stream alive, so later `'chat'` messages still work.

I read all of this in the repo source rather than running a live socket test, so the exact client-side payloads are as the code says.
