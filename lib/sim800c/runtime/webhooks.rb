# frozen_string_literal: true

require "net/http"
require "uri"

module Sim800c
  class Runtime
    # POSTs selected events as JSON to config.webhook.url. With a secret the body is signed:
    #   X-Webhook-Signature: sha256=<hex HMAC-SHA256 of the raw body>
    # Failed deliveries are retried after 2 s, 10 s and 30 s; a 4xx other than 429 is not retried.
    class Webhooks
      EVENTS = %w[sms.received sms.status call.incoming call.ended ussd.ended].freeze
      RETRY_DELAYS = [2, 10, 30].freeze
      WORKERS = 4

      Delivery = Struct.new(:event, :body, :headers, :attempt)
      private_constant :Delivery

      def initialize(config:, bus:, reactor:, logger:)
        @config = config
        @bus = bus
        @reactor = reactor
        @logger = logger
        @queue = Thread::Queue.new
        @workers = []
      end

      def enabled? = !@config.url.to_s.empty?

      def start
        return unless enabled?

        @uri = URI.parse(@config.url)
        names = EVENTS.select { |name| @config.events.nil? || Array(@config.events).include?(name) }
        names.each { |name| @bus.on(name) { |data| deliver(name, data) } }
        @workers = Array.new(WORKERS) { |i| start_worker(i) }
        @logger.info("[sim800c] Webhooks enabled: #{@config.url} (#{names.join(', ')})")
      end

      # Lets deliveries in progress finish (up to `timeout` seconds); queued ones are dropped.
      def stop(timeout: 5)
        @queue.close
        deadline = Reactor.now + timeout
        @workers.each { |t| t.join([deadline - Reactor.now, 0].max) }
        @workers.each { |t| t.kill if t.alive? }
        @workers = []
      end

      private

      def deliver(event, data)
        body = JSON.generate({ event: event, timestamp: Sim800c.iso(Sim800c.now), data: data })
        headers = { "content-type" => "application/json", "x-webhook-event" => event,
                    "user-agent" => "sim800c-rails/#{VERSION}" }
        if @config.secret.to_s != ""
          headers["x-webhook-signature"] = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @config.secret, body)}"
        end
        enqueue(Delivery.new(event, body, headers, 0))
      end

      def enqueue(delivery)
        @queue << delivery
      rescue ClosedQueueError
        nil
      end

      def start_worker(index)
        Thread.new do
          Thread.current.name = "sim800c-webhook-#{index}"
          Thread.current.report_on_exception = false
          while (delivery = @queue.pop)
            attempt(delivery)
          end
        end
      end

      def attempt(delivery)
        status = post(delivery)
        return if status.between?(200, 299)

        if status.between?(400, 499) && status != 429
          @logger.warn("[sim800c] Webhook #{delivery.event} rejected with HTTP #{status} (not retrying)")
          return
        end
        retry_later(delivery, "HTTP #{status}")
      rescue StandardError => e
        retry_later(delivery, "#{e.class}: #{e.message}")
      end

      def post(delivery)
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @config.timeout
        http.read_timeout = @config.timeout
        http.write_timeout = @config.timeout
        request = Net::HTTP::Post.new(@uri.request_uri, delivery.headers)
        request.body = delivery.body
        http.start { |h| h.request(request) }.code.to_i
      end

      def retry_later(delivery, reason)
        delay = RETRY_DELAYS[delivery.attempt]
        if delay.nil?
          @logger.error("[sim800c] Webhook #{delivery.event} delivery failed: #{reason}")
          return
        end
        delivery.attempt += 1
        @reactor.after(delay) { enqueue(delivery) }
      end
    end
  end
end
