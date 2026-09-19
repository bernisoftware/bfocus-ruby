# frozen_string_literal: true

module Bfocus
  # Máximo de itens por chamada de `customers.batch` e `people.batch`. Acima disso a SDK lança
  # `ArgumentError` antes de qualquer requisição — ela NÃO divide sozinha, porque o `"index"` de
  # cada resultado é a posição no lote que você enviou. Divida com `each_slice(Bfocus::BATCH_MAX)`.
  BATCH_MAX = 500

  # Recursos da API pública: `customers`, `people`, `products`, `release_notes`, `kb`, `ai_agents`.
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

      # Resultado de um lote vazio (sem requisição).
      def empty_batch_result
        { "results" => [], "summary" => { "created" => 0, "updated" => 0, "unchanged" => 0, "error" => 0 } }
      end

      # Valida a lista de um lote (`customers.batch`/`people.batch`) antes de qualquer
      # requisição e devolve os itens como Hash de chaves string (sem {UNSET}).
      # @raise [TypeError] não é lista ou item não é Hash.
      # @raise [ArgumentError] mais de {Bfocus::BATCH_MAX} itens.
      def batch_items(items, op)
        if items.is_a?(Hash) || !items.respond_to?(:each_with_index) || !items.respond_to?(:size)
          raise TypeError, "#{op}: items precisa ser uma lista de Hash."
        end
        if items.size > BATCH_MAX
          raise ArgumentError, "#{op} aceita até #{BATCH_MAX} itens por chamada (recebeu #{items.size}); " \
                               "divida em lotes de #{BATCH_MAX}."
        end

        items.each_with_index.map do |item, index|
          raise TypeError, "#{op}: items[#{index}] precisa ser um Hash." unless item.is_a?(Hash)

          item.each_with_object({}) do |(key, value), out|
            out[key.to_s] = value unless value.equal?(UNSET)
          end
        end
      end

      # Campo de id obrigatório num item de lote: String (ou número) não vazia.
      # @raise [ArgumentError]
      def batch_id!(item, field, op, index)
        value = item[field]
        return value unless value.nil? || value.to_s.empty?

        raise ArgumentError, "#{op}: items[#{index}].#{field} é obrigatório."
      end
    end
  end
end
