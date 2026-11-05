# frozen_string_literal: true

module EntraAuth
  # In-process token cache. Fine for one replica; for several replicas back
  # it with Redis (Azure Cache for Redis) so each replica doesn't hammer the
  # token endpoint. Keys must include the user (oid) for delegated tokens:
  # never share an OBO token between users.
  class TokenCache
    def initialize(skew: 300, clock: -> { Time.now })
      @skew = skew
      @clock = clock
      @store = {}
      @mutex = Mutex.new
    end

    def fetch(key)
      @mutex.synchronize do
        cached = @store[key]
        return cached if cached && !cached.expired?(skew: @skew, now: @clock.call)
      end
      token = yield
      @mutex.synchronize { @store[key] = token }
      token
    end

    def delete(key)
      @mutex.synchronize { @store.delete(key) }
    end

    def size
      @mutex.synchronize { @store.size }
    end
  end
end
