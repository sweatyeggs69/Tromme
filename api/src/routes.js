// One entry per proxied endpoint. Add a service by adding an entry here and its secret in wrangler.
// Only the listed query params are forwarded; everything else the client sends is dropped.
const MAX_PARAM_LENGTH = 200

export const routes = {
  "/lastfm/top-tracks": {
    upstream: "https://ws.audioscrobbler.com/2.0/",
    secret: "LASTFM_API_KEY",
    keyParam: "api_key",
    params: { artist: { required: true } },
    fixed: { method: "artist.gettoptracks", format: "json", limit: "10", autocorrect: "1" },
    ttl: 21600
  },
  "/ticketmaster/events": {
    upstream: "https://app.ticketmaster.com/discovery/v2/events.json",
    secret: "TICKETMASTER_API_KEY",
    keyParam: "apikey",
    params: { keyword: { required: true } },
    fixed: { classificationName: "music", sort: "date,asc", size: "50", locale: "*" },
    ttl: 3600
  }
}

export { MAX_PARAM_LENGTH }
