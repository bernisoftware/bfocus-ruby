# frozen_string_literal: true

module Bfocus
  module Resources
    # Contatos (pessoas) de um cliente — `client.customers.contacts`.
    #
    # Contato: `"id"`, `"external_id"`, `"name"`, `"role"`, `"email"`, `"phone"`, `"notes"`,
    # `"is_primary"`, `"created_at"`, `"updated_at"`.
    class CustomerContacts < Base
      # Contatos do cliente. `GET /customers/{external_id}/contacts`
      # @return [Array<Hash>]
      def list(external_id, timeout: nil)
        call("GET", "/customers/#{segment(external_id, 'external_id')}/contacts", timeout: timeout)
      end

      # Cria ou atualiza um contato pelo `external_id` dele. Só o que vier muda; `nil` limpa.
      # `PUT /customers/{external_id}/contacts/{contact_external_id}`
      # @return [Hash] o contato.
      def upsert(external_id, contact_external_id, name: UNSET, role: UNSET, email: UNSET,
                 phone: UNSET, notes: UNSET, is_primary: UNSET, idempotency_key: nil, timeout: nil)
        ext = segment(external_id, "external_id")
        cext = segment(contact_external_id, "contact_external_id")
        body = compact(
          "name" => name, "role" => role, "email" => email, "phone" => phone,
          "notes" => notes, "is_primary" => is_primary
        )
        call("PUT", "/customers/#{ext}/contacts/#{cext}",
             body: body, idempotency_key: idempotency_key, timeout: timeout)
      end

      # Remove um contato. `DELETE /customers/{external_id}/contacts/{contact_external_id}`
      # @return [Hash] `{"deleted" => true}`
      def delete(external_id, contact_external_id, idempotency_key: nil, timeout: nil)
        ext = segment(external_id, "external_id")
        cext = segment(contact_external_id, "contact_external_id")
        call("DELETE", "/customers/#{ext}/contacts/#{cext}",
             idempotency_key: idempotency_key, timeout: timeout)
      end
    end

    # Produtos vinculados a um cliente — `client.customers.products`.
    #
    # Produto vinculado: `"id"`, `"slug"`, `"name"`, `"is_active"`.
    class CustomerProducts < Base
      # Produtos do cliente. `GET /customers/{external_id}/products`
      # @return [Array<Hash>]
      def list(external_id, timeout: nil)
        call("GET", "/customers/#{segment(external_id, 'external_id')}/products", timeout: timeout)
      end

      # Vincula um produto ao cliente (idempotente). `PUT /customers/{external_id}/products/{slug}`
      # @return [Hash] o produto vinculado.
      def attach(external_id, product_slug, idempotency_key: nil, timeout: nil)
        ext = segment(external_id, "external_id")
        slug = segment(product_slug, "product_slug")
        call("PUT", "/customers/#{ext}/products/#{slug}",
             idempotency_key: idempotency_key, timeout: timeout)
      end

      # Desvincula um produto. `DELETE /customers/{external_id}/products/{slug}`
      # @return [Hash] `{"deleted" => true}`
      def detach(external_id, product_slug, idempotency_key: nil, timeout: nil)
        ext = segment(external_id, "external_id")
        slug = segment(product_slug, "product_slug")
        call("DELETE", "/customers/#{ext}/products/#{slug}",
             idempotency_key: idempotency_key, timeout: timeout)
      end
    end

    # Histórico de interações de um cliente — `client.customers.interactions`.
    #
    # Interação: `"id"`, `"content"`, `"is_internal"`, `"author_kind"`, `"author_name"`,
    # `"created_at"`.
    class CustomerInteractions < Base
      # Uma página de interações. `GET /customers/{external_id}/interactions`
      # @return [Bfocus::Page]
      def list(external_id, page: nil, page_size: nil, timeout: nil)
        ext = segment(external_id, "external_id")
        paged("/customers/#{ext}/interactions", { "page" => page, "page_size" => page_size }, timeout)
      end

      # Todas as interações, página a página (`page_size` padrão 100).
      # @return [Enumerator::Lazy<Hash>]
      def list_all(external_id, page_size: 100, timeout: nil)
        segment(external_id, "external_id") # valida já, não na 1ª iteração
        iterate { |number| list(external_id, page: number, page_size: page_size, timeout: timeout) }
      end

      # Registra uma interação (nota) no cliente. `POST /customers/{external_id}/interactions`
      #
      # @param content [String] texto/HTML da interação.
      # @param is_internal [Boolean] nota interna (padrão da API: `true`).
      # @param author_email [String, nil] e-mail de um usuário do bFocus para constar como autor.
      # @return [Hash] a interação.
      def create(external_id, content, is_internal: UNSET, author_email: UNSET,
                 idempotency_key: nil, timeout: nil)
        ext = segment(external_id, "external_id")
        body = compact("content" => content, "is_internal" => is_internal, "author_email" => author_email)
        call("POST", "/customers/#{ext}/interactions",
             body: body, idempotency_key: idempotency_key, timeout: timeout)
      end
    end

    # Identificadores extras de um cliente — `client.customers.identifiers`: liga o id de OUTRO
    # sistema seu (CRM, loja…) ao mesmo cadastro, que passa a ser encontrado por qualquer um deles.
    #
    # Retorno: o cliente + `"identifiers"` (lista de `{"external_id", "label", "source"}`).
    # Id que já pertence a outro cadastro: `ConflictError` com `code == "IDENTIFIER_IN_USE"`.
    class CustomerIdentifiers < Base
      # Liga `extra_id` ao cliente (idempotente).
      # `PUT /customers/{external_id}/identifiers/{extra_id}`
      #
      # @param label [String, nil] rótulo livre (ex.: `"CRM"`). Não informado = sem corpo.
      # @return [Hash] o cliente com `"identifiers"`.
      def add(external_id, extra_id, label: UNSET, idempotency_key: nil, timeout: nil)
        ext = segment(external_id, "external_id")
        extra = segment(extra_id, "extra_id")
        body = label.equal?(UNSET) ? nil : { "label" => label }
        call("PUT", "/customers/#{ext}/identifiers/#{extra}",
             body: body, idempotency_key: idempotency_key, timeout: timeout)
      end

      # Desliga `extra_id` do cliente. `DELETE /customers/{external_id}/identifiers/{extra_id}`
      # @return [Hash] o cliente com `"identifiers"`.
      def remove(external_id, extra_id, idempotency_key: nil, timeout: nil)
        ext = segment(external_id, "external_id")
        extra = segment(extra_id, "extra_id")
        call("DELETE", "/customers/#{ext}/identifiers/#{extra}",
             idempotency_key: idempotency_key, timeout: timeout)
      end
    end

    # Clientes (empresas) — `client.customers`. Sub-recursos: {#contacts}, {#products},
    # {#interactions}, {#identifiers}.
    #
    # Cliente: `"id"`, `"external_id"`, `"name"`, `"document"`, `"email"`, `"phone"`,
    # `"website"`, `"notes"`, `"custom_fields"` (lista de `{"key", "label", "type", "value",
    # "visibility"}`), `"is_active"`, `"created_at"`, `"updated_at"`.
    class Customers < Base
      # @return [CustomerContacts]
      attr_reader :contacts
      # @return [CustomerProducts]
      attr_reader :products
      # @return [CustomerInteractions]
      attr_reader :interactions
      # @return [CustomerIdentifiers]
      attr_reader :identifiers

      def initialize(transport)
        super
        @contacts = CustomerContacts.new(transport)
        @products = CustomerProducts.new(transport)
        @interactions = CustomerInteractions.new(transport)
        @identifiers = CustomerIdentifiers.new(transport)
      end

      # Cria ou atualiza um cliente pelo `external_id` do seu sistema. `PUT /customers/{external_id}`
      #
      # Só os campos informados mudam; `nil` limpa. `custom_fields` (lista de
      # `{key:, label:, type:, value:, options:}`), quando enviado, **substitui** a lista inteira.
      # @return [Hash] o cliente.
      def upsert(external_id, name: UNSET, document: UNSET, email: UNSET, phone: UNSET,
                 website: UNSET, notes: UNSET, custom_fields: UNSET, idempotency_key: nil, timeout: nil)
        ext = segment(external_id, "external_id")
        body = compact(
          "name" => name, "document" => document, "email" => email, "phone" => phone,
          "website" => website, "notes" => notes, "custom_fields" => custom_fields
        )
        call("PUT", "/customers/#{ext}", body: body, idempotency_key: idempotency_key, timeout: timeout)
      end

      # Cria/atualiza até {Bfocus::BATCH_MAX} (500) clientes numa chamada. `POST /customers/batch`
      #
      # Cada item (Hash, chaves string ou símbolo) tem `external_id` (obrigatório) e os mesmos
      # campos do {#upsert}, com a mesma regra: ausente = não muda; `nil` limpa.
      #
      # A SDK **não divide** o lote: mais de 500 itens lança `ArgumentError` antes de qualquer
      # requisição (use `items.each_slice(Bfocus::BATCH_MAX)`); o `"index"` de cada resultado é
      # a posição no lote enviado. Um item com erro não desfaz os outros. Lista vazia devolve o
      # resultado zerado sem chamar a API.
      #
      # @return [Hash] `{"results" => [{"index", "status", "external_id", "merged_into", "error",
      #   "code"}, …], "summary" => {"created", "updated", "unchanged", "error"}}` —
      #   `"status"` ∈ `created`/`updated`/`unchanged`/`error`; `"error"` é o código estável e
      #   `"code"` o status HTTP do item.
      # @raise [ArgumentError] mais de 500 itens ou item sem `external_id`.
      # @raise [TypeError] `items` não é lista de Hash.
      def batch(items, idempotency_key: nil, timeout: nil)
        list = batch_items(items, "customers.batch")
        return empty_batch_result if list.empty?

        list.each_with_index { |item, index| batch_id!(item, "external_id", "customers.batch", index) }
        call("POST", "/customers/batch",
             body: { "items" => list }, idempotency_key: idempotency_key, timeout: timeout)
      end

      # Um cliente. `GET /customers/{external_id}`
      # @return [Hash]
      def get(external_id, timeout: nil)
        call("GET", "/customers/#{segment(external_id, 'external_id')}", timeout: timeout)
      end

      # Uma página de clientes. `GET /customers`
      #
      # @param q [String, nil] busca por nome/documento/e-mail.
      # @param updated_since [Time, DateTime, Date, String, nil] só os alterados a partir deste
      #   instante (`Time` vira ISO 8601 UTC com `Z`; string passa como veio).
      # @return [Bfocus::Page]
      def list(q: nil, updated_since: nil, page: nil, page_size: nil, timeout: nil)
        query = { "q" => q, "updated_since" => updated_since, "page" => page, "page_size" => page_size }
        paged("/customers", query, timeout)
      end

      # Todos os clientes, página a página (`page_size` padrão 100). Ideal para sincronização
      # incremental: guarde o instante da última rodada e passe em `updated_since`.
      # @return [Enumerator::Lazy<Hash>]
      def list_all(q: nil, updated_since: nil, page_size: 100, timeout: nil)
        iterate do |number|
          list(q: q, updated_since: updated_since, page: number, page_size: page_size, timeout: timeout)
        end
      end

      # Exclui um cliente. `DELETE /customers/{external_id}`
      # @return [Hash] `{"deleted" => true}`
      def delete(external_id, idempotency_key: nil, timeout: nil)
        call("DELETE", "/customers/#{segment(external_id, 'external_id')}",
             idempotency_key: idempotency_key, timeout: timeout)
      end
    end
  end
end
