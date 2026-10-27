import { routes, MAX_PARAM_LENGTH } from "./routes.js"

const json = (body, status, headers = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers }
  })

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET") {
      return json({ error: "method not allowed" }, 405, { allow: "GET" })
    }

    const url = new URL(request.url)
    const route = routes[url.pathname]
    if (!route) return json({ error: "not found" }, 404)

    const apiKey = env[route.secret]
    if (!apiKey) return json({ error: "not configured" }, 503)

    // Build the upstream query from the whitelist only.
    const query = new URLSearchParams()
    for (const [name, rule] of Object.entries(route.params)) {
      const value = url.searchParams.get(name)?.trim()
      if (!value) {
        if (rule.required) return json({ error: `missing ${name}` }, 400)
        continue
      }
      if (value.length > MAX_PARAM_LENGTH) return json({ error: `${name} too long` }, 400)
      query.set(name, value)
    }
    for (const [name, value] of Object.entries(route.fixed)) query.set(name, value)
    query.sort()

    // The cache key never contains the secret.
    const cacheKey = new Request(`https://api.tromme.app${url.pathname}?${query}`)
    const cache = caches.default
    const cached = await cache.match(cacheKey)
    if (cached) return cached

    const ip = request.headers.get("cf-connecting-ip") ?? "unknown"
    if (env.LIMITER) {
      const { success } = await env.LIMITER.limit({ key: ip })
      if (!success) return json({ error: "rate limited" }, 429, { "retry-after": "60" })
    }

    const upstream = new URL(route.upstream)
    upstream.search = query.toString()
    upstream.searchParams.set(route.keyParam, apiKey)

    let upstreamResponse
    try {
      upstreamResponse = await fetch(upstream, { headers: { accept: "application/json" } })
    } catch {
      return json({ error: "upstream unreachable" }, 502)
    }

    // Pass the body through untouched so the app's decoders keep working. Only cache successes.
    const response = new Response(upstreamResponse.body, {
      status: upstreamResponse.status,
      headers: {
        "content-type": upstreamResponse.headers.get("content-type") ?? "application/json",
        "cache-control": upstreamResponse.ok ? `public, max-age=${route.ttl}` : "no-store"
      }
    })
    if (upstreamResponse.ok) ctx.waitUntil(cache.put(cacheKey, response.clone()))
    return response
  }
}
