# Question 2: guards, interceptors and pipes: emetgate

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:12:08.606Z to 2026-10-05T09:12:39.305Z
- Model calls: 5; tool calls: 10
- Tokens: 192,477 (input 10, cache written 37,681, cache read 150,976, output 3,810)
- Cost from the token counts at 2 USD per million base tokens: $0.219
- Answer-key items named in the answer: 6 of 6

## Question

In a NestJS HTTP app a route has a global guard, a controller-level guard and a method-level guard, plus an interceptor and a ValidationPipe on a @Body() parameter. (1) Which code builds the chain that runs for this route? (2) In which order are the global, controller and method guards collected and run, and which code decides that order? (3) What happens when the second guard returns false, do the remaining guards run, and what exactly does the client get? (4) In which order do guards, interceptors and pipes run relative to the handler, and where in the code is that order fixed?

## Tool calls, in order

1. `mcp__emetgate__emetgate_explore` `{"question": "How is the guards/interceptors/pipes chain built and executed for a route; guard collection order global controller method; guard returns false ForbiddenException", "names": ["RouterExecutionContext", "GuardsContextCreator", "GuardsConsumer"]}`
   - reply: 12,755 characters
2. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/core/router/router-execution-context.ts", "symbols": ["RouterExecutionContext.create", "RouterExecutionContext.createGuardsFn"], "detail": "full"}`
   - reply: 4,247 characters
3. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/core/guards/guards-context-creator.ts", "symbols": ["GuardsContextCreator.create", "GuardsContextCreator.createConcreteContext", "GuardsContextCreator.getGlobalMetadata"], "detail": "full"}`
   - reply: 1,805 characters
4. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/core/guards/guards-consumer.ts", "symbols": ["GuardsConsumer.tryActivate", "GuardsConsumer.pickResult"], "detail": "full"}`
   - reply: 996 characters
5. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/core/router/router-explorer.ts", "symbols": ["RouterExplorer.applyCallbackToRouter"], "detail": "full"}`
   - reply: 4,852 characters
6. `mcp__emetgate__emetgate_explore` `{"question": "ContextCreator createContext getGlobalMetadata reflectClassMetadata reflectMethodMetadata merge order", "names": ["ContextCreator"]}`
   - reply: 21,911 characters
7. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/core/router/router-explorer.ts", "symbol": "RouterExplorer.createCallbackProxy", "detail": "full"}`
   - reply: 699 characters
8. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/core/router/router-execution-context.ts", "symbols": ["RouterExecutionContext.createPipesFn"], "detail": "full"}`
   - reply: 1,196 characters
9. `mcp__emetgate__emetgate_read_file` `{"file": "packages/core/interceptors/interceptors-consumer.ts", "raw": true}`
   - reply: 3,503 characters
10. `mcp__emetgate__emetgate_explore` `{"question": "RouterProxy createProxy catch exception handler next; ExceptionsHandler next catch HttpException response body; FORBIDDEN_MESSAGE", "names": ["RouterProxy", "FORBIDDEN_MESSAGE"]}`
   - reply: 28,022 characters

## Answer

All paths below are relative to the repo root, and line numbers come from the symbols I read.

## (1) What builds the chain

- **Per-route wiring.** `RouterExplorer.applyCallbackToRouter` (`packages/core/router/router-explorer.ts:164`) calls `createCallbackProxy` (`:413`) for each route.
  - It builds the route function with `RouterExecutionContext.create` (`packages/core/router/router-execution-context.ts:96`).
  - It builds the exception handler with `exceptionsFilter.create`.
  - It wraps the two together with `routerProxy.createProxy`. That wrapper is a `try/catch` that sends any throw to `ExceptionsHandler.next` (`router-proxy.ts:15-27`).
  - Request-scoped controllers go through `createRequestScopedHandler` instead.
- **Chain assembly.** `RouterExecutionContext.create` collects pipes, guards and interceptors once, at route registration, through the `PipesContextCreator`, `GuardsContextCreator` and `InterceptorsContextCreator`. It then builds `fnCanActivate` (`createGuardsFn`) and `fnApplyPipes` (`createPipesFn`). Its inner `handler` closure runs the pipes and then the controller method. It returns the per-request function that executes the chain.

## (2) Order of the guards

`ContextCreator.createContext` (`packages/core/helpers/context-creator.ts:16-41`) fixes the order. It returns `[...global, ...class, ...method]`:

- `getGlobalMetadata` supplies the global guards. `GuardsContextCreator.getGlobalMetadata` (`guards-context-creator.ts:99`) reads `config.getGlobalGuards()`. For request-scoped contexts it appends the scoped global guards.
- `reflectClassMetadata` reads `GUARDS_METADATA` from the controller class.
- `reflectMethodMetadata` reads `GUARDS_METADATA` from the handler function.

`createConcreteContext` (`guards-context-creator.ts:43`) resolves each entry to an instance. It drops anything without a `canActivate` function. Within one decorator, for example `@UseGuards(A, B)`, the guards keep the order you passed them.

So your three guards run global, then controller, then method.

## (3) When the second guard returns false

`GuardsConsumer.tryActivate` (`guards-consumer.ts:8`) loops over the guards in order:

- A sync `boolean` `false` returns `false` immediately.
- A Promise or Observable result goes through `pickResult`, which uses `lastValueFrom` for observables. A falsy result also returns `false` immediately.

**The third guard does not run.** The pipes, the interceptors and the handler do not run either.

`canActivateFn` (`router-execution-context.ts:406-417`) then throws `new ForbiddenException('Forbidden resource')` (`FORBIDDEN_MESSAGE` is in `guards/constants.ts`). `RouterProxy.createProxy` catches it and passes it to `ExceptionsHandler.next`. Custom `@UseFilters` filters get the first chance to handle it. Otherwise the default `BaseExceptionFilter` replies.

The client gets HTTP 403. The body comes from `ForbiddenException`'s constructor, which calls `HttpException.createBody`, and should be:

```json
{ "message": "Forbidden resource", "error": "Forbidden", "statusCode": 403 }
```

I did not read `createBody` or `BaseExceptionFilter.catch`, so I'm inferring that body from the constructor arguments. A custom exception filter would change it.

If a guard throws its own exception, such as `UnauthorizedException`, that exception propagates the same way. The 403 conversion only applies to a falsy return.

## (4) Order relative to the handler

Per request, the returned function in `RouterExecutionContext.create` (`router-execution-context.ts:~171-210`) runs these steps in order:

1. **Guards.** `fnCanActivate && await fnCanActivate([req, res, next])`.
2. **Status and headers** are set.
3. **Interceptors, before-part.** `interceptorsConsumer.intercept(interceptors, …, handler(...))`. The interceptors nest in the order global, controller, method (`interceptors-consumer.ts:23-32`). Each `intercept` runs until it calls `next.handle()`, which calls the next interceptor.
4. **Pipes.** The innermost `next` is the `handler` closure from `create`. It runs `await fnApplyPipes(...)`. In `createPipesFn` (`:421`) each `@Body()` and other parameter goes through `pipes.concat(paramPipes)`. That is the global, controller and method pipes, then the parameter's own pipes. Your `ValidationPipe` runs here.
5. **The controller method** runs: `callback.apply(instance, args)`.
6. **Interceptors, after-part** run in reverse as the Observable result flows back out, then `fnHandleResponse` writes the response.

The full order is guards, interceptors (before), pipes, handler, interceptors (after).

**Where it is fixed.** Two places do it:

- The sequence of `await fnCanActivate`, then `intercept(...)`, then the pipes call inside `handler`, is hard-coded in `RouterExecutionContext.create`.
- The within-stage ordering is set by `ContextCreator.createContext` and `InterceptorsConsumer.intercept`.

A pipe failure, such as `ValidationPipe` rejecting the body, happens after the guards and inside the interceptor chain. It throws a `BadRequestException`, which interceptors can see through `catchError`. It reaches the same exception-handler path as in (3).

Middleware runs before all of this, since it is registered in the HTTP adapter's stack ahead of the route. I did not trace that path.
