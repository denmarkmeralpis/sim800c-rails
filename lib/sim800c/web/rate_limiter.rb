# frozen_string_literal: true

module Sim800c
  module Web
    # Fixed-window request counter in a cache store shared by all web processes (Rails.cache), or
    # in this process when the app's cache does not keep data.
    class RateLimiter
      Result = Data.define(:allowed, :limit, :remaining, :reset)

      def self.store
        configured = Sim800c.config.auth.rate_limit_store
        return configured if configured

        cache = ::Rails.cache if defined?(::Rails) && ::Rails.respond_to?(:cache)
        return cache if cache && !cache.is_a?(ActiveSupport::Cache::NullStore)

        @fallback ||= ActiveSupport::Cache::MemoryStore.new(size: 8 * 1024 * 1024)
      end

      attr_reader :name, :limit, :period

      def initialize(name, limit:, period:)
        @name = name
        @limit = limit.to_i
        @period = period.to_i
      end

      # Counts one request for `key`.
      def hit(key)
        cache_key, reset = window(key)
        count = self.class.store.increment(cache_key, 1, expires_in: period + 1).to_i
        Result.new(allowed: count <= limit, limit: limit, remaining: [limit - count, 0].max, reset: reset)
      end

      def exceeded?(key)
        cache_key, = window(key)
        self.class.store.read(cache_key).to_i >= limit
      end

      # RateLimit headers (IETF draft 8), like express-rate-limit's standardHeaders: "draft-8".
      def headers(result)
        { "ratelimit-policy" => %("#{name}";q=#{limit};w=#{period}),
          "ratelimit" => %("#{name}";r=#{result.remaining};t=#{result.reset}) }
      end

      private

      def window(key)
        now = Time.now.to_i
        index = now / period
        ["sim800c:ratelimit:#{name}:#{key}:#{index}", ((index + 1) * period) - now]
      end
    end
  end
end
