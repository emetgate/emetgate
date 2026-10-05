# Question 2: guards, interceptors and pipes: codebase-memory-mcp

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:12:09.305Z to 2026-10-05T09:12:51.500Z
- Model calls: 7; tool calls: 16
- Tokens: 248,493 (input 14, cache written 34,160, cache read 209,281, output 5,038)
- Cost from the token counts at 2 USD per million base tokens: $0.229
- Answer-key items named in the answer: 6 of 6

## Question

In a NestJS HTTP app a route has a global guard, a controller-level guard and a method-level guard, plus an interceptor and a ValidationPipe on a @Body() parameter. (1) Which code builds the chain that runs for this route? (2) In which order are the global, controller and method guards collected and run, and which code decides that order? (3) What happens when the second guard returns false, do the remaining guards run, and what exactly does the client get? (4) In which order do guards, interceptors and pipes run relative to the handler, and where in the code is that order fixed?

## Tool calls, in order

1. `mcp__codebase-memory-mcp__list_projects` `{}`
   - reply: 3,335 characters
2. `mcp__codebase-memory-mcp__search_graph` `{"project": "C-benchmark-codebase-memory-nest", "name_pattern": "^(createContext|create|createProxy|createRouterProxy|createRequestHandler|applyCallbackToRouter|createCallbackProxy|createGuardsFn|createPipesFn|getGlobalMetadata|getGlobalMetadata|createPipesContext|fnCanActivate|tryActivate|handleReturnValue|create)$", "file_pattern": "packages/core/(guards|interceptors|pipes|router|helpers)/.*", "limit": 40}`
   - reply: 118 characters
3. `mcp__codebase-memory-mcp__search_graph` `{"project": "C-benchmark-codebase-memory-nest", "file_pattern": "packages/core/**", "query": "guards context creator create execution context handler", "limit": 25}`
   - reply: 7,457 characters
4. `mcp__codebase-memory-mcp__search_code` `{"project": "C-benchmark-codebase-memory-nest", "pattern": "createGuardsFn|createPipesFn|createContext\\(", "regex": true, "path_filter": "^packages/core/(router|guards|interceptors|pipes)/", "file_pattern": "*.ts", "limit": 20}`
   - reply: 3,499 characters
5. `mcp__codebase-memory-mcp__get_code_snippet` `{"project": "C-benchmark-codebase-memory-nest", "qualified_name": "C-benchmark-codebase-memory-nest.packages.core.router.router-execution-context.RouterExecutionContext.create"}`
   - reply: 5,619 characters
6. `mcp__codebase-memory-mcp__get_code_snippet` `{"project": "C-benchmark-codebase-memory-nest", "qualified_name": "C-benchmark-codebase-memory-nest.packages.core.router.router-execution-context.RouterExecutionContext.createGuardsFn"}`
   - reply: 2,355 characters
7. `mcp__codebase-memory-mcp__get_code_snippet` `{"project": "C-benchmark-codebase-memory-nest", "qualified_name": "C-benchmark-codebase-memory-nest.packages.core.guards.guards-context-creator.GuardsContextCreator.create"}`
   - reply: 1,351 characters
8. `mcp__codebase-memory-mcp__get_code_snippet` `{"project": "C-benchmark-codebase-memory-nest", "qualified_name": "C-benchmark-codebase-memory-nest.packages.core.guards.guards-context-creator.GuardsContextCreator.getGlobalMetadata"}`
   - reply: 2,497 characters
9. `mcp__codebase-memory-mcp__get_code_snippet` `{"project": "C-benchmark-codebase-memory-nest", "qualified_name": "C-benchmark-codebase-memory-nest.packages.core.helpers.context-creator.ContextCreator.createContext"}`
   - reply: 2,622 characters
10. `mcp__codebase-memory-mcp__get_code_snippet` `{"project": "C-benchmark-codebase-memory-nest", "qualified_name": "C-benchmark-codebase-memory-nest.packages.core.guards.guards-consumer.GuardsConsumer.tryActivate"}`
   - reply: 2,413 characters
11. `mcp__codebase-memory-mcp__trace_path` `{"project": "C-benchmark-codebase-memory-nest", "function_name": "create", "direction": "inbound", "depth": 1, "mode": "calls"}`
   - reply: 18,963 characters
12. `mcp__codebase-memory-mcp__search_code` `{"project": "C-benchmark-codebase-memory-nest", "pattern": "executionContext.create|createCallbackProxy|routerProxy\\.createProxy|applyCallbackToRouter|FORBIDDEN_MESSAGE =", "regex": true, "path_filter": "^packages/(core|common)/(router|guards|constants)[^/]*(/[^/]+)?\\.ts$", "mode": "compact", "context": 3}`
   - reply: 3,732 characters
13. `mcp__codebase-memory-mcp__get_code_snippet` `{"project": "C-benchmark-codebase-memory-nest", "qualified_name": "C-benchmark-codebase-memory-nest.packages.core.router.router-execution-context.RouterExecutionContext.createPipesFn"}`
   - reply: 2,681 characters
14. `mcp__codebase-memory-mcp__get_code_snippet` `{"project": "C-benchmark-codebase-memory-nest", "qualified_name": "C-benchmark-codebase-memory-nest.packages.core.interceptors.interceptors-consumer.InterceptorsConsumer.intercept"}`
   - reply: 2,735 characters
15. `mcp__codebase-memory-mcp__search_code` `{"project": "C-benchmark-codebase-memory-nest", "pattern": "createProxy\\(|public catch\\(|isHttpError|getResponse\\(\\)|unknown_exception|handleUnknownError", "regex": true, "path_filter": "^packages/core/(router/router-proxy|exceptions/(base-exception-filter|exceptions-handler))\\.ts$", "mode": "full", "limit": 10}`
16. `mcp__codebase-memory-mcp__get_code_snippet` `{"project": "C-benchmark-codebase-memory-nest", "qualified_name": "C-benchmark-codebase-memory-nest.packages.core.guards.guards-context-creator.GuardsContextCreator.createConcreteContext"}`
   - reply: 4,456 characters
   - reply: 2,204 characters

## Answer

Everything below comes from reading the code in `packages/core`. I didn't run an app.

## 1. What builds the chain for the route

- **Per-route builder:** `RouterExplorer.createCallbackProxy` (`router/router-explorer.ts:413`) is called from `applyCallbackToRouter` at startup. For request-scoped controllers it is called from `createRequestScopedHandler`.
- **Execution context:** it calls `RouterExecutionContext.create` (`router/router-execution-context.ts:96`). That method builds the pipes, guards and interceptors with `pipesContextCreator.create`, `guardsContextCreator.create` and `interceptorsContextCreator.create`. It then builds `fnCanActivate` and `fnApplyPipes`, and returns the per-request function.
- **Exception wrapper:** `createCallbackProxy` also builds the exception filter with `exceptionsFilter.create`. `RouterProxy.createProxy` (`router/router-proxy.ts:11`) wraps the execution context in a `try/catch` that sends any error to `exceptionsHandler.next`.

## 2. Guard collection order

`ContextCreator.createContext` (`helpers/context-creator.ts:16`) fixes the order. It builds one array from three sources, in this order:

1. **Global guards:** from `getGlobalMetadata`, which reads `config.getGlobalGuards()`. In `guards-context-creator.ts:99`, request-scoped global guards are appended after the plain global ones.
2. **Controller (class) guards:** from `reflectClassMetadata`.
3. **Method guards:** from `reflectMethodMetadata`.

Guards listed within one decorator keep their `@UseGuards(A, B)` order. `createConcreteContext` (`guards-context-creator.ts:43`) filters and maps them without reordering.

`GuardsConsumer.tryActivate` (`guards/guards-consumer.ts:8`) then runs them sequentially in that array order with a `for…of` loop. A promise or Observable result is awaited before the next guard starts.

The same `createContext` builds the pipes and interceptors, so they also run global, then controller, then method.

## 3. When the second guard returns false

- **Remaining guards:** they don't run. `tryActivate` does `return false` as soon as one guard returns false, whether it returned a boolean or an awaited promise or Observable result. The third guard is never called.
- **Where the failure is raised:** the `canActivateFn` built by `createGuardsFn` (`router-execution-context.ts:400`) throws `new ForbiddenException(FORBIDDEN_MESSAGE)`. `FORBIDDEN_MESSAGE` is `'Forbidden resource'` (`guards/constants.ts`).
- **What isn't reached:** that throw happens before the pipes, the interceptors and the handler.
- **Who handles it:** `RouterProxy` catches the error and `exceptionsHandler.next` passes it to the exception filters. If no custom filter handles it, `BaseExceptionFilter.catch` (`exceptions/base-exception-filter.ts:26`) replies with `exception.getResponse()` and `exception.getStatus()`.
- **What the client gets:** HTTP 403 with this body, assuming the default filter:
  ```json
  {"statusCode":403,"message":"Forbidden resource","error":"Forbidden"}
  ```
  I inferred the `"error":"Forbidden"` field from `ForbiddenException`'s standard response shape. I didn't open that class in this session.
- **Custom filters:** a global, controller or method `@Catch(ForbiddenException)` filter can change the response.

## 4. Order relative to the handler, and where it's fixed

Order: **guards → interceptors (before-logic) → pipes → handler → interceptors (after-logic) → response**.

The order is fixed by the code in the function returned from `RouterExecutionContext.create`, plus the `handler` closure above it:

1. **Guards:** `await fnCanActivate([req, res, next])` runs first, before anything else.
2. **Status and headers:** these are set, then the interceptors start. `interceptorsConsumer.intercept(interceptors, …, handler(...))` receives the handler closure as its `next`.
3. **Interceptor chain:** `InterceptorsConsumer.intercept` (`interceptors/interceptors-consumer.ts:10`) nests interceptors. Each one's `handle()` calls the next, and the last one calls `next`, which is the `handler` closure.
4. **Pipes:** the `handler` closure runs `await fnApplyPipes(args, …)` first and only then `callback.apply(instance, args)`. So pipes run inside the interceptor chain, after the interceptors' pre-handler code and just before the handler.
5. **Response:** `fnHandleResponse` writes the result after the interceptor chain returns.

Pipes run per parameter. `createPipesFn` (`router-execution-context.ts:421`) extracts the `@Body()` value and passes it through `pipes.concat(paramPipes)`. That means global, controller and method pipes run first, then the parameter's own pipes. A `ValidationPipe` failure throws `BadRequestException` inside the interceptor chain, so interceptors that use `catchError` can intercept it.
