# frozen_string_literal: true

module Bfocus
  module Resources
    # Artigos da base de conhecimento — `client.kb.articles`. Exige o módulo de Atendimento
    # (sem ele: `PermissionDeniedError` com `code == "MODULE_NOT_CONTRACTED"`).
    #
    # Artigo (resumo — `list`, `list_all`, `batch_upsert`): `"id"`, `"external_id"`,
    # `"product"`, `"title"`, `"excerpt"`, `"status"`, `"origin"`, `"published_at"`,
    # `"created_at"`, `"updated_at"`. Artigo completo (`get`, `upsert`, `publish`,
    # `unpublish`): o resumo + `"body_html"`.
    class KBArticles < Base
      # Limite da API por requisição de {#batch_upsert}; a SDK divide acima disso.
      BATCH_SIZE = 100

      # Uma página de artigos (resumo, sem `body_html`). `GET /kb/articles`
      #
      # @param product [String, nil] slug do produto.
      # @param status [String, nil] `"draft"` ou `"published"`.
      # @param q [String, nil] busca no título e no texto.
      # @param updated_since [Time, DateTime, Date, String, nil]
      # @return [Bfocus::Page]
      def list(product: nil, status: nil, q: nil, updated_since: nil, page: nil, page_size: nil, timeout: nil)
        query = {
          "product" => product, "status" => status, "q" => q, "updated_since" => updated_since,
          "page" => page, "page_size" => page_size
        }
        paged("/kb/articles", query, timeout)
      end

      # Todos os artigos (com os filtros), página a página (`page_size` padrão 100).
      # @return [Enumerator::Lazy<Hash>]
      def list_all(product: nil, status: nil, q: nil, updated_since: nil, page_size: 100, timeout: nil)
        iterate do |number|
          list(product: product, status: status, q: q, updated_since: updated_since,
               page: number, page_size: page_size, timeout: timeout)
        end
      end

      # Um artigo (com `body_html`). `GET /kb/articles/{external_id}`
      # @return [Hash]
      def get(external_id, timeout: nil)
        call("GET", "/kb/articles/#{article_id(external_id)}", timeout: timeout)
      end

      # Cria ou atualiza um artigo pelo `external_id` (sem `/`; use `:`).
      # `PUT /kb/articles/{external_id}`. `product: nil` (explícito) torna o artigo global;
      # `status: "published"` publica.
      # @return [Hash] o artigo completo.
      def upsert(external_id, title: UNSET, body_html: UNSET, body_markdown: UNSET,
                 product: UNSET, status: UNSET, idempotency_key: nil, timeout: nil)
        body = compact(
          "title" => title, "body_html" => body_html, "body_markdown" => body_markdown,
          "product" => product, "status" => status
        )
        call("PUT", "/kb/articles/#{article_id(external_id)}",
             body: body, idempotency_key: idempotency_key, timeout: timeout)
      end

      # Cria/atualiza **qualquer quantidade** de artigos. `POST /kb/articles/batch`
      #
      # A SDK divide em lotes de 100 (limite da API), envia em sequência e devolve UM
      # resultado: `"results"` na ordem enviada e contadores somados. Falha de um item não
      # derruba os outros (`"ok" => false` + `"error"` no resultado dele). Lista vazia devolve
      # o resultado zerado sem chamar a API.
      #
      # Cada item (Hash, chaves string ou símbolo) precisa de `external_id`; os demais campos
      # seguem a regra do {#upsert} (ausente = não muda; `product: nil` = global).
      #
      # Se um lote falhar por inteiro (rede, 429 esgotado…), o erro sobe e os lotes anteriores
      # já foram aplicados — rodar de novo é seguro (é upsert).
      #
      # @param idempotency_key [String, nil] o 1º lote usa a chave como veio; os seguintes,
      #   `"<chave>:<n>"` (n = 2, 3, …). Sem chave, cada lote gera a sua.
      # @return [Hash] `{"results" => [{"external_id", "ok", "action", "error", "article"}, …],
      #   "created", "updated", "unchanged", "failed"}`
      def batch_upsert(articles, idempotency_key: nil, timeout: nil)
        if articles.is_a?(Hash) || !articles.respond_to?(:each_with_index)
          raise TypeError, "articles precisa ser uma lista de Hash."
        end

        items = articles.each_with_index.map { |article, index| batch_item(article, index) }
        outcome = { "results" => [], "created" => 0, "updated" => 0, "unchanged" => 0, "failed" => 0 }
        user_key = idempotency_key.to_s
        items.each_slice(BATCH_SIZE).with_index(1) do |chunk, number|
          key = user_key.empty? ? nil : user_key
          key = "#{key}:#{number}" if key && number > 1
          data = call("POST", "/kb/articles/batch",
                      body: { "articles" => chunk }, idempotency_key: key, timeout: timeout)
          merge_outcome(outcome, data)
        end
        outcome
      end

      # Publica um artigo. `POST /kb/articles/{external_id}/publish`
      # @return [Hash] o artigo completo.
      def publish(external_id, idempotency_key: nil, timeout: nil)
        call("POST", "/kb/articles/#{article_id(external_id)}/publish",
             idempotency_key: idempotency_key, timeout: timeout)
      end

      # Volta um artigo para rascunho. `POST /kb/articles/{external_id}/unpublish`
      # @return [Hash] o artigo completo.
      def unpublish(external_id, idempotency_key: nil, timeout: nil)
        call("POST", "/kb/articles/#{article_id(external_id)}/unpublish",
             idempotency_key: idempotency_key, timeout: timeout)
      end

      # Exclui um artigo. `DELETE /kb/articles/{external_id}`
      # @return [Hash] `{"deleted" => true}`
      def delete(external_id, idempotency_key: nil, timeout: nil)
        call("DELETE", "/kb/articles/#{article_id(external_id)}",
             idempotency_key: idempotency_key, timeout: timeout)
      end

      private

      def article_id(external_id)
        Codec.path_segment(external_id, "external_id", allow_slash: false)
      end

      def batch_item(article, index)
        raise TypeError, "articles[#{index}] precisa ser um Hash." unless article.is_a?(Hash)

        item = article.each_with_object({}) do |(key, value), out|
          out[key.to_s] = value unless value.equal?(UNSET)
        end
        ext = item["external_id"]
        unless ext.is_a?(String) && !ext.empty?
          raise ArgumentError, "articles[#{index}]: external_id é obrigatório."
        end
        if ext.include?("/")
          raise ArgumentError, "articles[#{index}]: external_id não aceita '/' — use ':' (#{ext.inspect})"
        end

        item
      end

      def merge_outcome(outcome, data)
        return unless data.is_a?(Hash)

        data.each do |field, value|
          if field == "results"
            outcome["results"].concat(value) if value.is_a?(Array)
          elsif value.is_a?(Integer)
            outcome[field] = outcome[field].to_i + value
          else # campo novo não numérico: preservado (o último lote vence)
            outcome[field] = value
          end
        end
      end
    end

    # Base de conhecimento — `client.kb` (artigos em {#articles}). Exige o módulo de
    # Atendimento.
    class KnowledgeBase < Base
      # @return [KBArticles]
      attr_reader :articles

      def initialize(transport)
        super
        @articles = KBArticles.new(transport)
      end

      # Busca semântica/textual nos artigos publicados. `GET /kb/search`
      #
      # @param q [String] pergunta ou termos.
      # @param product [String, nil] slug do produto para restringir.
      # @param limit [Integer, nil] máximo de resultados (padrão da API: 5; máximo 20).
      # @return [Array<Hash>] `{"id", "external_id", "title", "excerpt"}`
      def search(q, product: nil, limit: nil, timeout: nil)
        call("GET", "/kb/search", query: { "q" => q, "product" => product, "limit" => limit }, timeout: timeout)
      end
    end
  end
end
