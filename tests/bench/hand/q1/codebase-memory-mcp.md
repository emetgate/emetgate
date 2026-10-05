# Question 1: API versioning: codebase-memory-mcp

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:01:22.557Z to 2026-10-05T09:04:49.206Z
- Model calls: 4; tool calls: 5
- Tokens: 124,775 (input 8, cache written 30,963, cache read 91,382, output 2,422)
- Cost from the token counts at 2 USD per million base tokens: $0.166
- Answer-key items named in the answer: 6 of 6

## Question

NestJS has app.enableVersioning({ type: VersioningType.HEADER, header: 'X-API-Version' }) on, with the Express adapter. A controller is declared as @Controller({ path: 'cats', version: '1' }) and one of its methods is marked @Version('2'). (1) When the method version and the controller version differ, which one wins and which code decides that? (2) Which code matches the version of an incoming request, and how does it read the header? (3) What happens when the request has no X-API-Version header at all, and in which case does the handler still run? (4) Where does the request go when the version does not match? (5) If the same app used URI versioning instead, where would the version be checked, how is the path built and what is the default prefix?

## Tool calls, in order

1. `mcp__codebase-memory-mcp__list_projects` `{}`
   - reply: 3,335 characters
2. `mcp__codebase-memory-mcp__search_code` `{"pattern": "VersioningType", "project": "C-benchmark-codebase-memory-nest", "path_filter": "^packages/(core|common)/.*(?<!spec)\\.ts$", "mode": "files", "limit": 30}`
3. `mcp__codebase-memory-mcp__search_code` `{"pattern": "VERSION_METADATA", "project": "C-benchmark-codebase-memory-nest", "mode": "files", "limit": 30}`
   - reply: 959 characters
   - reply: 538 characters
4. `mcp__codebase-memory-mcp__search_code` `{"pattern": "ersion", "project": "C-benchmark-codebase-memory-nest", "path_filter": "^packages/core/router/(router-explorer|route-path-factory)\\.ts$", "mode": "full", "limit": 30}`
   - reply: 38,703 characters
5. `mcp__codebase-memory-mcp__search_code` `{"pattern": "ersion", "project": "C-benchmark-codebase-memory-nest", "path_filter": "^packages/platform-express/adapters/express-adapter\\.ts$", "mode": "full", "limit": 30}`
   - reply: 26,071 characters

## Answer

All of this is in `packages/core/router/` and `packages/platform-express/adapters/express-adapter.ts`. I didn't open the code that fills `controllerVersion` from `@Controller({ version })`, or the 404 handler registration, so those two points come from what the code I read implies.

**1. Method version vs. controller version**

The method version wins. `RoutePathFactory.getVersion()` (`route-path-factory.ts:80`) returns `metadata.methodVersion || metadata.controllerVersion`, and its comment says the method version takes priority. In your example `@Version('2')` overrides the controller's `'1'`, so the route is only reachable with `X-API-Version: 2`.

`RouterExplorer.applyPathsToRouterProxy()` (`router-explorer.ts:139`) sets `routePathMetadata.methodVersion` from each route definition before registering it.

**2. Matching the request version**

`RouterExplorer.applyVersionFilter()` (`router-explorer.ts:400`) calls `getVersion()` and passes the result to `router.applyVersionFilter(handler, version, versioningOptions)`. For Express that is `ExpressAdapter.applyVersionFilter()` (`express-adapter.ts:425`). Its `HEADER` branch (`handlerForHeaderVersioning`) reads the header like this:

```ts
req.headers?.[versioningOptions.header] ||
req.headers?.[versioningOptions.header.toLowerCase()]
```

It then compares that value to the route's version:
- If the route version is an array, the header value must be in it.
- If the route version is a string, it must equal the header value.
- A match calls `handler(req, res, next)`.

`applyCallbackToRouter` only applies this filter when the versioning type is not `URI`.

**3. No `X-API-Version` header**

The handler runs only if the route's version is an array that includes `VERSION_NEUTRAL`. Otherwise the request falls through. In your case the version is the string `'2'`, so the handler does not run.

A route whose version is exactly `VERSION_NEUTRAL` (not in an array) skips the filter, and the handler always runs.

**4. Where a non-matching request goes**

The filter calls `callNextHandler`, which calls `next()` and passes the request to the next matching route or middleware in Express. If `next` is missing, it throws `InternalServerErrorException('HTTP adapter does not support filtering on version')`. If no other route matches, the request should end up in Nest's not-found handling (a 404), but I didn't open that code.

**5. URI versioning instead**

- **Where the version is checked:** it isn't checked per request. In `ExpressAdapter.applyVersionFilter`, `URI` just forwards to the handler. `RouterExplorer.applyCallbackToRouter` skips the version filter entirely for `URI`. The version is part of the registered route path, so Express's own path matching does the check.
- **How the path is built:** `RoutePathFactory.create()` (`route-path-factory.ts:21`) puts the version first as `/${versionPrefix}${version}`. It then appends the module path, controller path and method path, and finally the global prefix. For a version array it builds one path per version, and `VERSION_NEUTRAL` adds no version segment. Your example becomes `/v2/cats`.
- **Default prefix:** `'v'`, from `getVersionPrefix()` (`route-path-factory.ts:86`). `prefix: false` gives `''`, and a custom string replaces it.
