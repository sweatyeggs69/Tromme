# Tromme API

Cloudflare Worker at `api.tromme.app`. Holds third-party API keys as Worker secrets so they never ship in the app.

| Route | Upstream | Params |
| --- | --- | --- |
| `GET /lastfm/top-tracks` | Last.fm `artist.gettoptracks` | `artist` |
| `GET /ticketmaster/events` | Ticketmaster Discovery events | `keyword` |

Only GET, only the listed params; everything else is fixed server-side. Responses are edge cached and rate limited per IP.

## Add a service

Add an entry to `src/routes.js`, then `npx wrangler secret put <SECRET_NAME>`.

## Deploy

```
cd api
npm install
npx wrangler secret put LASTFM_API_KEY
npx wrangler secret put TICKETMASTER_API_KEY
npx wrangler deploy
```
