# frozen_string_literal: true

module Bfocus
  # URL de produção da API (padrão do {Client}). Em dev: `http://localhost:8000`.
  DEFAULT_BASE_URL = "https://api.bfocus.com.br"
  # Prefixo das rotas da API pública.
  API_PREFIX = "/api/v1/integration"
  # Vai em `X-Bfocus-Client` e `User-Agent`. É por ele que a API sabe qual versão da SDK a
  # conta roda — e avisa quando uma correção exigir atualizar.
  CLIENT_ID = "bfocus-ruby/#{VERSION}".freeze
  # Segundos por tentativa.
  DEFAULT_TIMEOUT = 30
  # Novas tentativas além da primeira.
  DEFAULT_MAX_RETRIES = 2

  # Faz UMA chamada lógica: 1 tentativa + até `max_retries` novas tentativas, com os mesmos
  # `X-Request-Id` e `Idempotency-Key`. Sem estado mutável entre chamadas (uma conexão por
  # tentativa), então um {Client} pode ser compartilhado entre threads.
  # @api private
  class Transport
    RETRY_STATUSES = [429, 502, 503, 504].freeze
    WRITE_METHODS = %w[POST PUT PATCH DELETE].freeze
    MAX_RETRY_AFTER = 60.0
    MAX_BACKOFF = 8.0

    # Métodos que "esperam" corpo: sem corpo, vão com `Content-Length: 0` (e sem Content-Type).
    BODY_METHODS = %w[POST PUT PATCH].freeze

    # Falhas de transporte que viram {NetworkError} (e são repetidas). `Net::OpenTimeout` e
    # `Net::ReadTimeout` são `Timeout::Error`; `ECONNREFUSED`/`ECONNRESET` são `SystemCallError`.
    NETWORK_ERRORS = [
      SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError
    ].tap { |list| list << Zlib::Error if defined?(Zlib::Error) }.freeze

    attr_reader :base_url, :timeout, :max_retries
    # Espera entre tentativas (`#call(segundos)`). Substituível: os testes não dormem.
    attr_accessor :sleeper

    def initialize(api_key, base_url:, timeout:, max_retries:, sleeper: nil)
      @api_key = api_key
      @base_url = base_url.sub(%r{/+\z}, "")
      begin
        @uri = URI.parse(@base_url)
      rescue URI::InvalidURIError
        @uri = nil
      end
      unless @uri.is_a?(URI::HTTP) && @uri.hostname && !@uri.hostname.empty?
        raise ArgumentError, "Bfocus::Client: base_url inválida #{base_url.inspect} (use http:// ou https://)."
      end

      @base_path = @uri.path.to_s
      @timeout = timeout
      @max_retries = max_retries
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    # `Retry-After` em segundos (número ou data HTTP); `nil` se ausente/inválido.
    # @return [Integer, Float, nil]
    def self.parse_retry_after(raw)
      return nil if raw.nil?

      text = raw.to_s.strip
      return nil if text.empty?

      seconds =
        if text.match?(/\A\d+(?:\.\d+)?\z/)
          text.to_f
        else
          begin
            Time.httpdate(text) - Time.now
          rescue ArgumentError
            return nil
          end
        end
      return nil if seconds.nan? || seconds.infinite?

      seconds = 0.0 if seconds.negative?
      seconds == seconds.floor ? seconds.to_i : seconds
    end

    # `min(8, 0.5 × 2^tentativa)` s + jitter de até 25%.
    def self.backoff(attempt)
      base = [MAX_BACKOFF, 0.5 * (2**attempt)].min
      base + (Random.rand * base * 0.25)
    end

    # Espera antes da próxima tentativa: `Retry-After` (teto 60 s) ou backoff exponencial.
    def retry_delay(attempt, retry_after)
      seconds = self.class.parse_retry_after(retry_after)
      return [seconds.to_f, MAX_RETRY_AFTER].min unless seconds.nil?

      self.class.backoff(attempt)
    end

    # Executa a chamada e devolve `[data, pagination]` do envelope.
    #
    # `body: nil` significa SEM corpo (o JSON `null` nunca é um corpo válido aqui).
    # @raise [Bfocus::Error]
    def request(method, path, query: nil, body: nil, idempotency_key: nil, timeout: nil)
      method = method.to_s.upcase
      per_try = timeout.nil? ? @timeout : timeout
      unless per_try.is_a?(Numeric) && per_try.positive?
        raise ArgumentError, "timeout precisa ser > 0 (segundos)."
      end

      target = @base_path + API_PREFIX + path + Codec.query_string(query)
      request_id = SecureRandom.uuid.delete("-")
      headers = {
        "Authorization" => "Bearer #{@api_key}",
        "Accept" => "application/json",
        "X-Bfocus-Client" => CLIENT_ID,
        "User-Agent" => CLIENT_ID,
        # Mesmo id em todas as tentativas desta chamada: é como o suporte correlaciona.
        "X-Request-Id" => request_id
      }
      if WRITE_METHODS.include?(method)
        # Mesma chave em todas as tentativas: a API devolve a resposta original
        # (Idempotent-Replayed: true) em vez de executar de novo.
        key = idempotency_key.to_s
        headers["Idempotency-Key"] = key.empty? ? SecureRandom.uuid : key
      end
      payload = nil
      unless body.nil?
        payload = JSON.generate(Codec.jsonable(body))
        headers["Content-Type"] = "application/json"
      end

      attempt = 0
      while true # rubocop:disable Style/InfiniteLoop -- `loop` engoliria um StopIteration do sleeper
        begin
          status, resp_headers, raw = perform(method, target, headers, payload, per_try)
        rescue *NETWORK_ERRORS => e
          if attempt < @max_retries
            @sleeper.call(self.class.backoff(attempt))
            attempt += 1
            next
          end
          raise NetworkError.new(
            "NETWORK_ERROR: falha ao falar com #{@base_url} (#{e.class}: #{e.message})",
            request_id: request_id
          )
        end

        return unwrap(status, resp_headers, raw, request_id) if status.between?(200, 299)

        if RETRY_STATUSES.include?(status) && attempt < @max_retries
          @sleeper.call(retry_delay(attempt, resp_headers["retry-after"]))
          attempt += 1
          next
        end
        raise build_error(status, resp_headers, raw, request_id)
      end
    end

    def inspect
      "#<Bfocus::Transport base_url=#{@base_url.inspect}>"
    end

    private

    def perform(method, target, headers, payload, timeout)
      http = Net::HTTP.new(@uri.hostname, @uri.port)
      http.use_ssl = @uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout
      # O Net::HTTP repete sozinho GET/PUT/DELETE uma vez em certas falhas; quem decide
      # novas tentativas (e conta) é esta classe.
      http.max_retries = 0
      # Requisição genérica, e não Net::HTTP::Post/Put: sem corpo, aquelas viram `body = ""` +
      # `Content-Type: application/x-www-form-urlencoded` por conta própria.
      req = Net::HTTPGenericRequest.new(method, !payload.nil?, true, target, headers)
      if payload.nil?
        req["Content-Length"] = "0" if BODY_METHODS.include?(method)
      else
        req.body = payload
      end
      response = http.start { |conn| conn.request(req) }
      resp_headers = {}
      response.each_header { |name, value| resp_headers[name] = value }
      [response.code.to_i, resp_headers, response.body.to_s]
    end

    # 2xx → `[data, pagination]`. Sem envelope JSON válido → `INVALID_RESPONSE`.
    #
    # Nunca devolve `nil` calado: um proxy que responde 200 com HTML (ou um corpo vazio) vira
    # erro, não "sucesso sem dados".
    def unwrap(status, headers, raw, sent_request_id)
      payload, text = Codec.decode_json(raw)
      if payload.is_a?(Hash) && payload.key?("data")
        pagination = payload["pagination"]
        return [payload["data"], pagination.is_a?(Hash) ? pagination : nil]
      end

      shown = text.strip[0, 200]
      detail = shown.empty? ? " (corpo vazio)" : ": #{shown.inspect}"
      raise Error.new(
        "INVALID_RESPONSE (HTTP #{status}): resposta sem o envelope JSON da API#{detail}",
        code: "INVALID_RESPONSE",
        status: status,
        request_id: present(headers["x-request-id"]) || sent_request_id,
        body: payload.nil? ? present(text) : payload
      )
    end

    # Resposta fora de 2xx → erro. `request_id`: corpo → header → o id que a SDK enviou.
    def build_error(status, headers, raw, sent_request_id)
      payload, text = Codec.decode_json(raw)
      code = nil
      human = nil
      request_id = nil
      validation = {}

      if payload.is_a?(Hash)
        err = payload["error"]
        msg = payload["message"]
        if err.is_a?(String) && !err.empty?
          code = err
        elsif msg.is_a?(String) && !msg.empty?
          code = msg
        end
        human = msg if msg.is_a?(String) && !msg.empty? && msg != code
        validation = payload["validation"] if payload["validation"].is_a?(Hash)
        rid = payload["request_id"]
        request_id = rid if rid.is_a?(String) && !rid.empty?
      elsif !text.strip.empty?
        human = text.strip[0, 200]
      end

      code ||= "HTTP_#{status}"
      request_id ||= present(headers["x-request-id"]) || sent_request_id
      retry_after = status == 429 ? self.class.parse_retry_after(headers["retry-after"]) : nil
      required_scope = status == 403 ? present(headers["x-required-scope"]) : nil
      required_module = status == 403 ? present(headers["x-required-module"]) : nil

      message = "#{code} (HTTP #{status})"
      message += ": #{human}" if human
      message += " — escopo exigido: #{required_scope}" if required_scope
      message += " — módulo exigido: #{required_module}" if required_module
      message += " — #{validation.map { |field, why| "#{field}: #{why}" }.join('; ')}" unless validation.empty?
      message += " — tente de novo em #{retry_after}s" unless retry_after.nil?

      Error.class_for(status).new(
        message,
        code: code,
        status: status,
        request_id: request_id,
        validation: validation,
        retry_after: retry_after,
        required_scope: required_scope,
        body: payload.nil? ? present(text) : payload
      )
    end

    def present(value)
      text = value.to_s
      text.empty? ? nil : text
    end
  end
end
