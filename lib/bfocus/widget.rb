# frozen_string_literal: true

module Bfocus
  # Assina a identidade do usuário logado para abrir o widget de atendimento do bFocus.
  #
  # Roda no **seu backend** (o segredo nunca vai para o navegador) e não exige chave de API
  # nem faz rede. Devolve o HMAC-SHA256, em hexadecimal minúsculo, de
  # `"v1:" + user_external_id + ":" + customer_external_id` (UTF-8).
  #
  # @param secret [String] segredo de identidade do widget (painel do bFocus).
  # @param user_external_id [String] `external_id` do usuário no seu sistema.
  # @param customer_external_id [String] `external_id` do cliente (empresa) desse usuário.
  # @return [String] 64 caracteres hexadecimais minúsculos.
  # @raise [ArgumentError] segredo vazio ou id `nil`.
  #
  # @example
  #   Bfocus.sign_widget_identity(ENV.fetch("BFOCUS_WIDGET_SECRET"), "USR-1", "ERP 1042")
  def self.sign_widget_identity(secret, user_external_id, customer_external_id)
    raise ArgumentError, "sign_widget_identity: secret é obrigatório." if secret.nil? || secret.to_s.empty?
    raise ArgumentError, "sign_widget_identity: user_external_id é obrigatório." if user_external_id.nil?
    raise ArgumentError, "sign_widget_identity: customer_external_id é obrigatório." if customer_external_id.nil?

    utf8 = lambda do |value|
      text = value.to_s
      (text.encoding == ::Encoding::BINARY ? text : text.encode(::Encoding::UTF_8)).b
    end
    message = "v1:".b + utf8.call(user_external_id) + ":".b + utf8.call(customer_external_id)
    OpenSSL::HMAC.hexdigest("SHA256", utf8.call(secret), message)
  end

  # Identidade do widget **v2 (com validade)**: como {sign_widget_identity}, mas carimbada com o
  # instante. Roda no seu backend, sem rede e sem chave de API.
  #
  # Devolve `"v2.<ts>.<hex>"`: `ts` = segundos unix inteiros do instante (padrão: agora) e `hex`
  # = HMAC-SHA256, em hexadecimal minúsculo, de
  # `"v2:" + ts + ":" + user_external_id + ":" + customer_external_id` (UTF-8). A API aceita de
  # 7 dias atrás até 5 minutos à frente — gere a cada renderização da página, nunca guarde. Vai
  # no mesmo lugar da v1 (`userHash` do widget); a v1 continua aceita.
  #
  # @param secret [String] segredo de identidade do widget (painel do bFocus).
  # @param user_external_id [String] `external_id` do usuário (a pessoa) no seu sistema — sem
  #   `:` (é o separador; a API recusa).
  # @param customer_external_id [String] `external_id` do cliente (empresa). Prefira `-` a `:` nos
  #   seus ids (ex.: `"erp-1042"`).
  # @param now [Integer, Time, nil] instante da assinatura: segundos unix (não ms) ou `Time`.
  #   Padrão: agora.
  # @return [String] `"v2.<ts>.<64 hex>"`.
  # @raise [ArgumentError] segredo vazio, id `nil`, `:` no id do usuário, instante negativo ou de
  #   tipo inválido.
  #
  # @example
  #   Bfocus.sign_widget_identity_v2(ENV.fetch("BFOCUS_WIDGET_SECRET"), "app-77", "erp-1042")
  #   # => "v2.<ts>.<hex>"
  def self.sign_widget_identity_v2(secret, user_external_id, customer_external_id, now: nil)
    raise ArgumentError, "sign_widget_identity_v2: secret é obrigatório." if secret.nil? || secret.to_s.empty?
    raise ArgumentError, "sign_widget_identity_v2: user_external_id é obrigatório." if user_external_id.nil?
    raise ArgumentError, "sign_widget_identity_v2: customer_external_id é obrigatório." if customer_external_id.nil?
    if user_external_id.to_s.include?(":")
      raise ArgumentError, "sign_widget_identity_v2: user_external_id não pode ter ':' (é o separador; " \
                           "a API recusa) — use outro, ex.: \"app-77\": #{user_external_id.to_s.inspect}"
    end

    ts = case now
         when nil then Time.now.to_i
         when Time then now.to_i
         when Integer then now
         else
           raise ArgumentError, "sign_widget_identity_v2: now precisa ser Integer (segundos unix) ou Time."
         end
    raise ArgumentError, "sign_widget_identity_v2: now não pode ser negativo (#{ts})." if ts.negative?

    utf8 = lambda do |value|
      text = value.to_s
      (text.encoding == ::Encoding::BINARY ? text : text.encode(::Encoding::UTF_8)).b
    end
    message = "v2:#{ts}:".b + utf8.call(user_external_id) + ":".b + utf8.call(customer_external_id)
    "v2.#{ts}.#{OpenSSL::HMAC.hexdigest('SHA256', utf8.call(secret), message)}"
  end
end
