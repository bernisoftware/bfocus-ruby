# frozen_string_literal: true

module Bfocus
  # Recursos da API pública: `customers`, `products`, `release_notes`, `kb`, `ai_agents`.
  #
  # Convenções (iguais em todos os métodos):
  #
  # * Obrigatórios são posicionais; opcionais são keyword args.
  # * Campos de corpo opcionais têm padrão {Bfocus::UNSET} — não informado = não enviado.
  #   `nil` explícito vai como `null` e **limpa** o campo na API.
  # * Filtros de query com `nil` são omitidos.
  # * Toda chamada aceita `timeout:` (segundos, por tentativa); as escritas aceitam
  #   `idempotency_key:` (senão a SDK gera uma e a repete nas novas tentativas).
  # * O retorno é o `data` da resposta: `Hash`/`Array` com chaves **string**, exatamente como a
  #   API devolve (campos novos aparecem sem quebrar nada). Listas paginadas devolvem {Page}.
  module Resources
    # @api private
    class Base
      def initialize(transport)
        @transport = transport
      end

      def inspect
        "#<#{self.class.name}>"
      end

      private

      def call(method, path, query: nil, body: nil, idempotency_key: nil, timeout: nil)
        data, _pagination = @transport.request(
          method, path,
          query: query, body: body, idempotency_key: idempotency_key, timeout: timeout
        )
        data
      end

      def paged(path, query, timeout)
        data, pagination = @transport.request("GET", path, query: query, timeout: timeout)
        Page.from_response(data, pagination)
      end

      # Enumerator::Lazy que busca página por página (cada uma é uma chamada lógica nova) e
      # para quando `page >= pages` ou a página vem vazia.
      def iterate(&fetch)
        Enumerator.new do |yielder|
          number = 1
          while true # rubocop:disable Style/InfiniteLoop
            current = fetch.call(number)
            current.items.each { |item| yielder << item }
            break if current.items.empty? || current.page >= current.pages

            number += 1
          end
        end.lazy
      end

      def segment(value, name)
        Codec.path_segment(value, name)
      end

      def compact(fields)
        Codec.compact(fields)
      end
    end
  end
end
