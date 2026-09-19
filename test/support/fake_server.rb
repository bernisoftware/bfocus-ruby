# frozen_string_literal: true

require "json"
require "socket"
require "uri"

# Servidor HTTP/1.1 mínimo (TCPServer da stdlib — o WEBrick saiu da stdlib no Ruby 3) que
# responde, em ordem, as respostas enfileiradas e grava cada requisição com o caminho CRU
# (exatamente como a SDK codificou), a query, os headers e o corpo.
#
# Requisição a mais (fila vazia) recebe 418 `UNEXPECTED_REQUEST` — status que a SDK não
# repete — e fica gravada para o teste acusar. Uma conexão por requisição (`Connection: close`).
class FakeServer
  REASONS = {
    200 => "OK", 201 => "Created", 400 => "Bad Request", 401 => "Unauthorized",
    403 => "Forbidden", 404 => "Not Found", 409 => "Conflict", 418 => "I'm a teapot",
    422 => "Unprocessable Entity", 429 => "Too Many Requests", 500 => "Internal Server Error",
    502 => "Bad Gateway", 503 => "Service Unavailable", 504 => "Gateway Timeout"
  }.freeze

  UNEXPECTED = {
    "status" => 418,
    "headers" => {},
    "body" => { "code" => 418, "data" => nil, "message" => "UNEXPECTED_REQUEST", "error" => "UNEXPECTED_REQUEST" }
  }.freeze

  attr_reader :errors

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @lock = Mutex.new
    @responses = []
    @requests = []
    @errors = []
    @thread = Thread.new { serve }
    @thread.report_on_exception = false
  end

  def base_url
    "http://127.0.0.1:#{@port}"
  end

  def reset(responses)
    @lock.synchronize do
      @responses = responses.dup
      @requests = []
      @errors = []
    end
  end

  # @return [Array<Hash>] `{method:, path:, raw_query:, query:, headers:, body:}` de cada requisição.
  def requests
    @lock.synchronize { @requests.dup }
  end

  def stop
    @server.close
  rescue IOError
    nil
  ensure
    @thread.join(2)
  end

  private

  def serve
    loop do
      socket = begin
        @server.accept
      rescue IOError, SystemCallError
        break
      end
      begin
        handle(socket)
      rescue StandardError => e
        @lock.synchronize { @errors << e }
      ensure
        socket.close unless socket.closed?
      end
    end
  end

  def handle(socket)
    request_line = socket.gets("\r\n") or return
    method, target, = request_line.strip.split(" ", 3)
    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    body = length.positive? ? socket.read(length) : +""
    path, raw_query = target.split("?", 2)
    record = {
      method: method,
      path: path,
      raw_query: raw_query,
      query: raw_query ? URI.decode_www_form(raw_query) : [],
      headers: headers,
      body: body.b
    }

    response = @lock.synchronize do
      @requests << record
      @responses.shift
    end
    write_response(socket, response || UNEXPECTED)
  end

  def write_response(socket, response)
    status = Integer(response["status"])
    body = response["body"]
    if body.nil?
      payload = "".b
      content_type = nil
    elsif body.is_a?(String)
      payload = body.b
      content_type = "text/plain; charset=utf-8"
    else
      payload = JSON.generate(body).b
      content_type = "application/json"
    end

    head = +"HTTP/1.1 #{status} #{REASONS.fetch(status, 'Status')}\r\n"
    head << "Content-Type: #{content_type}\r\n" if content_type
    head << "Content-Length: #{payload.bytesize}\r\n"
    (response["headers"] || {}).each { |name, value| head << "#{name}: #{value}\r\n" }
    head << "Connection: close\r\n\r\n"
    socket.write(head.b + payload)
    socket.flush
  end
end
