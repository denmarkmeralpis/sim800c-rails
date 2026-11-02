# frozen_string_literal: true

require "socket"

# A minimal HTTP server standing in for a webhook receiver. Records each request.
class HttpReceiver
  Request = Struct.new(:method, :path, :headers, :body)

  attr_reader :requests

  def initialize(status: 204)
    @status = status
    @requests = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def url = "http://127.0.0.1:#{@server.local_address.ip_port}/hook"

  def close
    @server.close
    @thread.join(1)
  end

  private

  def serve
    loop do
      client = @server.accept
      handle(client)
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(client)
    method, path = client.gets.to_s.split
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.strip
    end
    body = client.read(headers["content-length"].to_i)
    @requests << Request.new(method, path, headers, body)
    client.write("HTTP/1.1 #{@status} OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
  ensure
    client.close
  end
end
