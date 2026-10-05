# Question 2: guards, interceptors and pipes: Claude Code (built-in tools)

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:12:10.270Z to 2026-10-05T09:12:41.145Z
- Model calls: 6; tool calls: 5
- Tokens: 274,575 (input 12, cache written 18,295, cache read 253,169, output 3,099)
- Cost from the token counts at 2 USD per million base tokens: $0.155
- Answer-key items named in the answer: 6 of 6

## Question

In a NestJS HTTP app a route has a global guard, a controller-level guard and a method-level guard, plus an interceptor and a ValidationPipe on a @Body() parameter. (1) Which code builds the chain that runs for this route? (2) In which order are the global, controller and method guards collected and run, and which code decides that order? (3) What happens when the second guard returns false, do the remaining guards run, and what exactly does the client get? (4) In which order do guards, interceptors and pipes run relative to the handler, and where in the code is that order fixed?

## Tool calls, in order

1. `Grep` `{"pattern": "createContext\\(|getGlobalMetadata|getAllMetadata|class GuardsContextCreator|class GuardsConsumer|class InterceptorsConsumer|class PipesConsumer", "path": "C:\\benchmark\\plain-claude\\nest\\packages\\core", "glob": "{guards,interceptors,pipes,router}/*.ts", "output_mode": "content", "head_limit": 60}`
   - reply: 16 characters
2. `Bash` `{"command": "ls && ls packages/core/guards packages/core/router packages/core/helpers 2>&1 | head -80"}`
   - reply: 1,170 characters
3. `Bash` `{"command": "cd /c/benchmark/plain-claude/nest/packages/core && cat guards/guards-context-creator.ts guards/guards-consumer.ts helpers/context-creator.ts && grep -n \"\" router/router-execution-context.ts | sed -n 60,330p"}`
   - reply: 16,195 characters
4. `Bash` `{"command": "grep -n \"createGuardsFn\" -A 22 router/router-execution-context.ts | sed -n 28,80p; grep -n \"createPipesFn\" -A 25 router/router-execution-context.ts | tail -35; grep -n \"ForbiddenException\\|FORBIDDEN\" -r router/*.ts guards/*.ts ../common/exceptions/forbidden.exception.ts ../common/constants.ts ../common/internal/*.ts 2>/dev/null | head; grep -n \"intercept\" -A 30 interceptors/interceptors-consumer.ts | head -50; grep -n \"createProxy\\|routerProxy\\|createRequestScopedHandler\\|createCallbackProxy\\|applyCallbackToRouter\" router/router-explorer.ts | head -20; cat router/router-proxy.ts | head -50; grep -n \"catch\\|handle(\" -B2 -A12 router/router-proxy.ts | head -5"}`
   - reply: 6,335 characters
5. `Bash` `{"command": "sed -n 413,440p router/router-explorer.ts; sed -n 164,200p router/router-explorer.ts; sed -n 445,475p router/router-execution-context.ts; grep -n \"ValidationPipe\\|getGlobalPipes\\|GlobalPipes\" pipes/pipes-context-creator.ts | head"}`
   - reply: 2,854 characters

## Answer

All paths below are relative to `packages/core/`.

## (1) What builds the chain for the route

- **Registration:** `router/router-explorer.ts` `applyCallbackToRouter` (~l.164) registers the route. For a singleton controller it calls `createCallbackProxy` (l.413). For a request-scoped one it calls `createRequestScopedHandler`, which calls `createCallbackProxy` per request.
- **Context creation:** `createCallbackProxy` calls `executionContextCreator.create(...)`, which is `RouterExecutionContext.create` in `router/router-execution-context.ts:96`.
- **Chain assembly:** `create()` does the following:
  - It asks `pipesContextCreator.create`, `guardsContextCreator.create` and `interceptorsContextCreator.create` for the instance lists (l.128–148).
  - It builds `fnCanActivate` with `createGuardsFn` and `fnApplyPipes` with `createPipesFn` (l.150–156).
  - It builds the inner `handler` closure and returns the final `(req, res, next)` function (l.158–215).
- **Error handling:** `createCallbackProxy` wraps that function in `RouterProxy.createProxy` (`router/router-proxy.ts`). The wrapper's `try/catch` sends any exception to the `ExceptionsHandler` built by `exceptionsFilter.create`.

## (2) Guard order and what decides it

The order is **global, then controller, then method**. It is fixed in `helpers/context-creator.ts`, `ContextCreator.createContext`:

```ts
return [
  ...createConcreteContext(globalMetadata),   // getGlobalMetadata -> config.getGlobalGuards()
  ...createConcreteContext(classMetadata),    // Reflect.getMetadata(GUARDS_METADATA, controller class)
  ...createConcreteContext(methodMetadata),   // Reflect.getMetadata(GUARDS_METADATA, handler)
]
```

- `GuardsContextCreator` (`guards/guards-context-creator.ts`) extends `ContextCreator` and supplies the pieces. `getGlobalMetadata` reads `ApplicationConfig`. It adds request-scoped global guards when a contextId is present.
- `createConcreteContext` turns each entry into an instance. Class entries are looked up in the module's `injectables`. Guards passed as objects are used as-is.
- `guards: CanActivate[]` is therefore a flat array in that order.
- Within a single `@UseGuards(A, B)`, the decorator's argument order is kept.
- `GuardsConsumer.tryActivate` (`guards/guards-consumer.ts`) runs them sequentially in a `for…of`. Each guard's result is awaited if it's a Promise or an Observable (`pickResult` uses `lastValueFrom`).

## (3) Second guard returns false

- **Remaining guards:** the loop returns `false` immediately (`guards-consumer.ts`: `if (!result) return false`). The third guard is never called, and nothing after the guards runs: no interceptors, no pipes, no handler.
- **Exception:** `createGuardsFn` (`router-execution-context.ts:406–417`) sees `false` and throws `new ForbiddenException(FORBIDDEN_MESSAGE)`. `FORBIDDEN_MESSAGE` is `'Forbidden resource'` (`guards/constants.ts`). The throw happens at l.180, before status and headers are set and before interceptors are called.
- **What the client gets:** `RouterProxy`'s `catch` passes the exception to the exception filters, and the default filter produces the response. Unless a custom filter changes it, that is HTTP **403** with `{"message":"Forbidden resource","error":"Forbidden","statusCode":403}`.
- **Errors thrown from a guard:** if a guard throws its own exception instead of returning `false`, that exception goes down the same path and the client gets it instead of the 403.

## (4) Order of guards, interceptors, pipes and handler

The order is **guards, then interceptors (pre-handler part), then pipes, then handler, then interceptors (post-handler part, via the Observable), then the response is written**.

It is fixed in the returned function in `RouterExecutionContext.create` (`router-execution-context.ts:174–215`):

1. `await fnCanActivate(...)` runs the guards (l.180).
2. `interceptorsConsumer.intercept(interceptors, ..., handler(...))` runs next (l.200). The `handler` closure is the `next` that sits innermost in the interceptor chain.
3. Inside `handler` (l.166–172), `await fnApplyPipes(...)` runs first and `callback.apply(instance, args)` second. That is how the `ValidationPipe` on `@Body()` runs after interceptors have started but before the handler body.
4. The result flows back through the interceptors' `.pipe()` operators, in reverse order.
5. `fnHandleResponse` writes the response (l.209).

Interceptors nest. `InterceptorsConsumer.intercept` (`interceptors/interceptors-consumer.ts:24–34`) calls `interceptors[i].intercept(context, handler)`. Each `handle()` defers to `nextFn(i+1)`. When `i >= length`, it calls `transformDeferred(next)`, which runs the pipes and handler. Interceptors run in array order (global, controller, method, built by the same `createContext`) on the way in, and in reverse order on the way out.

Pipe order within a parameter is global pipes, then controller, then method (`pipes/pipes-context-creator.ts`). Then param-level pipes are appended (`pipes.concat(paramPipes)` at l.448). The `ValidationPipe` throws a `BadRequestException` if validation fails. That exception goes up through the interceptor Observable, so interceptors can catch it, and it then reaches the exception filters.
