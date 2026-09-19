# frozen_string_literal: true

module Bfocus
  # Erro devolvido pela API do bFocus (ou de rede, em {NetworkError}).
  #
  # Toda resposta fora de 2xx vira um `Bfocus::Error` — ou a subclasse do status. **Use
  # {#code} na sua lógica**: ele é estável (`CUSTOMER_NOT_FOUND`, `INTEGRATION_SCOPE_MISSING`…).
  # O {#message} é texto para humanos e pode mudar.
  #
  # Argumento inválido no seu código (chave vazia, parâmetro de caminho vazio/"."/"..", `/`
  # no `external_id` de artigo) NÃO é `Bfocus::Error`: é `ArgumentError`/`TypeError`, na hora.
  class Error < StandardError
    # @return [String] código estável: `body.error`, senão `body.message`, senão
    #   `HTTP_<status>` (corpo não-JSON); `INVALID_RESPONSE` quando um 2xx chega sem o
    #   envelope JSON da API; `NETWORK_ERROR` em falha de rede.
    attr_reader :code
    # @return [Integer] status HTTP (`0` em erro de rede).
    attr_reader :status
    # @return [String, nil] `request_id` do corpo, senão o header `X-Request-Id`, senão o
    #   `X-Request-Id` que a SDK enviou (a API ecoa o do cliente). Informe-o ao suporte.
    attr_reader :request_id
    # @return [Hash{String=>String}] motivos por campo (erros de validação); `{}` quando não há.
    attr_reader :validation
    # @return [Integer, Float, nil] segundos do header `Retry-After` (só em 429).
    attr_reader :retry_after
    # @return [String, nil] escopo que faltou na chave (header `X-Required-Scope`, só em 403).
    attr_reader :required_scope
    # @return [Hash, String, nil] corpo da resposta decodificado, ou o texto cru se não é JSON.
    attr_reader :body

    def initialize(message = nil, code: nil, status: 0, request_id: nil, validation: nil,
                   retry_after: nil, required_scope: nil, body: nil)
      @code = code
      @status = status
      @request_id = request_id
      @validation = validation.is_a?(Hash) ? validation.dup : {}
      @retry_after = retry_after
      @required_scope = required_scope
      @body = body
      text = message || code || self.class.name
      text = "#{text} [request_id=#{request_id}]" if request_id && !text.include?(request_id)
      super(text)
    end

    def inspect
      "#<#{self.class.name} code=#{code.inspect} status=#{status.inspect} " \
        "request_id=#{request_id.inspect}>"
    end

    STATUS_CLASSES = {} # preenchido abaixo, depois das subclasses
    private_constant :STATUS_CLASSES

    # Classe de erro para um status HTTP (5xx → {ServerError}; sem classe própria → a base).
    # @param status [Integer]
    # @return [Class]
    def self.class_for(status)
      return STATUS_CLASSES[status] if STATUS_CLASSES.key?(status)
      return ServerError if status >= 500 && status <= 599

      Error
    end
  end

  # 401 — chave ausente, inválida ou revogada.
  class AuthenticationError < Error; end

  # 403 — chave desligada, IP não liberado, escopo faltando ({#required_scope}) ou módulo não
  # contratado (`MODULE_NOT_CONTRACTED`: base de conhecimento e agentes de IA exigem o módulo
  # de Atendimento).
  class PermissionDeniedError < Error; end

  # 404 — o recurso (ou a conta) não existe.
  class NotFoundError < Error; end

  # 409 — o estado atual impede a operação (ex.: `KB_ARTICLE_EMPTY`, `AI_DISABLED`).
  class ConflictError < Error; end

  # 422 — corpo ou parâmetro inválido; os motivos por campo estão em {#validation}.
  class ValidationError < Error; end

  # 429 — limite de requisições da chave; {#retry_after} diz quanto esperar.
  class RateLimitError < Error; end

  # 5xx — erro do lado da API. Informe o {#request_id}.
  class ServerError < Error; end

  # Falha de conexão ou timeout (`status == 0`, `code == "NETWORK_ERROR"`).
  class NetworkError < Error
    def initialize(message = nil, request_id: nil, **_ignored)
      super(message || "NETWORK_ERROR", code: "NETWORK_ERROR", status: 0, request_id: request_id)
    end
  end

  class Error
    STATUS_CLASSES.merge!(
      401 => AuthenticationError,
      403 => PermissionDeniedError,
      404 => NotFoundError,
      409 => ConflictError,
      422 => ValidationError,
      429 => RateLimitError
    ).freeze
  end
end
