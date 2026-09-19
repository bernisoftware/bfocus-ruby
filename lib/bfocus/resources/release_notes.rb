# frozen_string_literal: true

module Bfocus
  module Resources
    # Release notes por produto — `client.release_notes`.
    #
    # Release note: `"id"`, `"product"`, `"version"`, `"title"`, `"description_html"`,
    # `"audience"`, `"is_published"`, `"require_ack_internal"`, `"require_ack_external"`,
    # `"published_at"`, `"created_at"`, `"updated_at"`.
    class ReleaseNotes < Base
      # Uma página de release notes. `GET /products/{slug}/release-notes`
      # @param published [Boolean, nil] `true` só publicadas, `false` só rascunhos, `nil` todas.
      # @return [Bfocus::Page]
      def list(product_slug, published: nil, page: nil, page_size: nil, timeout: nil)
        paged(base(product_slug), { "published" => published, "page" => page, "page_size" => page_size }, timeout)
      end

      # Todas as release notes do produto, página a página (`page_size` padrão 100).
      # @return [Enumerator::Lazy<Hash>]
      def list_all(product_slug, published: nil, page_size: 100, timeout: nil)
        base(product_slug) # valida já, não na 1ª iteração
        iterate do |number|
          list(product_slug, published: published, page: number, page_size: page_size, timeout: timeout)
        end
      end

      # Uma release note. `GET /products/{slug}/release-notes/{version}`
      # @return [Hash]
      def get(product_slug, version, timeout: nil)
        call("GET", "#{base(product_slug)}/#{segment(version, 'version')}", timeout: timeout)
      end

      # Cria ou atualiza a release note de uma versão (SemVer; aceita `v` na frente).
      # `PUT /products/{slug}/release-notes/{version}`. Com `publish: true` já publica — é o
      # caminho para publicar direto do CI.
      #
      # @param audience [String] `"internal"`, `"external"` ou `"both"`.
      # @param description_markdown [String] alternativa a `description_html` (a API converte).
      # @return [Hash] a release note.
      def upsert(product_slug, version, title: UNSET, description_html: UNSET,
                 description_markdown: UNSET, audience: UNSET, require_ack_internal: UNSET,
                 require_ack_external: UNSET, publish: UNSET, idempotency_key: nil, timeout: nil)
        body = compact(
          "title" => title,
          "description_html" => description_html,
          "description_markdown" => description_markdown,
          "audience" => audience,
          "require_ack_internal" => require_ack_internal,
          "require_ack_external" => require_ack_external,
          "publish" => publish
        )
        call("PUT", "#{base(product_slug)}/#{segment(version, 'version')}",
             body: body, idempotency_key: idempotency_key, timeout: timeout)
      end

      # Publica uma release note. `POST /products/{slug}/release-notes/{version}/publish`
      # @return [Hash] a release note.
      def publish(product_slug, version, idempotency_key: nil, timeout: nil)
        call("POST", "#{base(product_slug)}/#{segment(version, 'version')}/publish",
             idempotency_key: idempotency_key, timeout: timeout)
      end

      private

      def base(product_slug)
        "/products/#{segment(product_slug, 'product_slug')}/release-notes"
      end
    end
  end
end
