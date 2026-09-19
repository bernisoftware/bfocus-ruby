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
end
