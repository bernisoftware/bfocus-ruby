# frozen_string_literal: true

module Bfocus
  module Resources
    # Catálogo de produtos — `client.products`.
    #
    # Produto: `"id"`, `"slug"`, `"name"`, `"description"`, `"color"`, `"icon"`, `"is_active"`,
    # `"sort_order"`, `"current_version"`, `"ai_level"`, `"created_at"`, `"updated_at"`.
    class Products < Base
      # Produtos do catálogo. `GET /products`
      # @param include_inactive [Boolean, nil] `true` inclui os arquivados.
      # @return [Array<Hash>]
      def list(include_inactive: nil, timeout: nil)
        call("GET", "/products", query: { "include_inactive" => include_inactive }, timeout: timeout)
      end

      # Um produto. `GET /products/{slug}`
      # @return [Hash]
      def get(slug, timeout: nil)
        call("GET", "/products/#{segment(slug, 'slug')}", timeout: timeout)
      end

      # Cria ou atualiza um produto pelo `slug`. Só o que vier muda. `PUT /products/{slug}`
      # @return [Hash] o produto.
      def upsert(slug, name: UNSET, description: UNSET, color: UNSET, icon: UNSET,
                 is_active: UNSET, sort_order: UNSET, idempotency_key: nil, timeout: nil)
        body = compact(
          "name" => name, "description" => description, "color" => color, "icon" => icon,
          "is_active" => is_active, "sort_order" => sort_order
        )
        call("PUT", "/products/#{segment(slug, 'slug')}",
             body: body, idempotency_key: idempotency_key, timeout: timeout)
      end

      # Arquiva um produto (não apaga). `DELETE /products/{slug}`
      # @return [Hash] o produto, com `"is_active" => false`.
      def archive(slug, idempotency_key: nil, timeout: nil)
        call("DELETE", "/products/#{segment(slug, 'slug')}",
             idempotency_key: idempotency_key, timeout: timeout)
      end
    end
  end
end
