# frozen_string_literal: true

module EntraAuth
  # Fetches and caches Entra's token-signing keys. Refreshes daily, and early
  # when a token arrives with an unknown key id (Entra rolls keys), but no more
  # than once every few minutes so bad tokens can't force a fetch storm.
  class JwksProvider
    def initialize(config, http: Http, ttl: 24 * 3600, min_refresh_interval: 300, clock: -> { Time.now })
      @uri = URI(config.jwks_url)
      @http = http
      @ttl = ttl
      @min_refresh_interval = min_refresh_interval
      @clock = clock
      @mutex = Mutex.new
      @keys = nil
      @fetched_at = nil
    end

    def keys(force: false)
      @mutex.synchronize do
        now = @clock.call
        age = @fetched_at ? now - @fetched_at : Float::INFINITY
        fetch!(now) if age > @ttl || (force && age > @min_refresh_interval)
        @keys
      end
    end

    private

    def fetch!(now)
      status, body = @http.get_json(@uri)
      raise Error, "Could not fetch signing keys (HTTP #{status})" unless status == 200 && body["keys"]

      @keys = { keys: body["keys"] }
      @fetched_at = now
    end
  end
end
