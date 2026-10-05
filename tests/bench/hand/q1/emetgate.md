# Question 1: API versioning: emetgate

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:01:23.172Z to 2026-10-05T09:04:43.305Z
- Model calls: 3; tool calls: 5
- Tokens: 86,413 (input 6, cache written 12,754, cache read 71,594, output 2,059)
- Cost from the token counts at 2 USD per million base tokens: $0.086
- Answer-key items named in the answer: 6 of 6

## Question

NestJS has app.enableVersioning({ type: VersioningType.HEADER, header: 'X-API-Version' }) on, with the Express adapter. A controller is declared as @Controller({ path: 'cats', version: '1' }) and one of its methods is marked @Version('2'). (1) When the method version and the controller version differ, which one wins and which code decides that? (2) Which code matches the version of an incoming request, and how does it read the header? (3) What happens when the request has no X-API-Version header at all, and in which case does the handler still run? (4) Where does the request go when the version does not match? (5) If the same app used URI versioning instead, where would the version be checked, how is the path built and what is the default prefix?

## Tool calls, in order

1. `mcp__emetgate__emetgate_explore` `{"question": "How is versioning handled: method vs controller version, header version matching, URI versioning path building, default prefix, and routing when version doesn't match", "names": ["RoutesResolver", "RouterExplorer", "ExpressAdapter", "applyVersionFilter", "getVersionMetadata", "resolveVersion"]}`
   - reply: 15,211 characters
2. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/core/router/route-path-factory.ts", "symbols": ["RoutePathFactory.create", "RoutePathFactory.getVersion", "RoutePathFactory.getVersionPrefix"]}`
   - reply: 2,726 characters
3. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/core/router/router-explorer.ts", "symbol": "RouterExplorer.applyCallbackToRouter"}`
   - reply: 4,838 characters
4. `mcp__emetgate__emetgate_read_symbol` `{"file": "packages/platform-express/adapters/express-adapter.ts", "symbol": "ExpressAdapter.setNotFoundHandler"}`
   - reply: 1,535 characters
5. `mcp__emetgate__emetgate_search` `{"pattern": "VERSION_METADATA", "dir": "packages/core/router"}`
   - reply: 950 characters

## Answer

**(1) The method version wins.** `RoutePathFactory.getVersion` (`packages/core/router/route-path-factory.ts:80`) returns `metadata.methodVersion || metadata.controllerVersion`. Its comment says the method version takes priority. So your `getCats` handler is version `'2'` and the controller's `'1'` only applies to methods without their own `@Version`. `RouterExplorer.applyCallbackToRouter` (`router-explorer.ts:164`) uses that value, and `applyVersionFilter` (`router-explorer.ts:400`) calls `getVersion` to get the version it hands to the adapter.

**(2) The Express adapter matches the version, in `ExpressAdapter.applyVersionFilter` (`express-adapter.ts:425`).**
- `applyCallbackToRouter` only wraps the handler when a version exists and the versioning type is not URI.
- The HEADER branch is at lines 535–564. It reads `req.headers?.[versioningOptions.header] || req.headers?.[versioningOptions.header.toLowerCase()]`, so it tries `X-API-Version` and then `x-api-version`.
- If the route version is a string, the handler runs only when `version === headerValue`. If the route version is an array, it runs when the array includes the header value.

**(3) With no `X-API-Version` header, the handler runs only if the route version is an array that includes `VERSION_NEUTRAL`.** That is lines 542–547. A plain `'2'` (or `'1'`) never matches a missing header. Routes declared as `VERSION_NEUTRAL` on their own are not filtered at all: line 439 returns the raw handler. `defaultVersion` from the versioning options is also applied as a fallback when there is no `@Version` metadata (`RoutesResolver.getVersionMetadata`, `routes-resolver.ts:205`). I did not check how it interacts with a missing header.

**(4) A mismatch calls `next()` and Express moves on to the next matching route.** `callNextHandler` (lines 430–437) does this, and it throws a 500 if the adapter gives it no `next`. So another handler with the right version for the same path can pick the request up. If none does, the request reaches the app's not-found handler. I did not read `RoutesResolver.registerNotFoundHandler` (`routes-resolver.ts:155`) or the 404 body it produces. `ExpressAdapter.setNotFoundHandler` (`express-adapter.ts:187`) mounts that handler. So a mismatch ends in a 404, not a 400.

**(5) With URI versioning, nothing is checked at request time.**
- `applyVersionFilter` returns the plain handler for `VersioningType.URI` (line 442), and `applyCallbackToRouter` skips the filter for URI. The version is baked into the registered route path, so Express's ordinary path matching does the work.
- `RoutePathFactory.create` (`route-path-factory.ts:21`) builds the path. It starts with the version segment `/${versionPrefix}${version}`, then appends the module path, controller path and method path, then the global prefix unless the route is excluded. Version-neutral routes get no version segment. Array versions register one path per version.
- The default prefix is `'v'`, from `getVersionPrefix` (line 86). `prefix: false` gives `''`, and any other prefix string replaces `'v'`. Your `cats` route at version `'2'` would be `/v2/cats`. With a global prefix `api` it would be `/api/v2/cats`, unless the route is excluded from the global prefix.
