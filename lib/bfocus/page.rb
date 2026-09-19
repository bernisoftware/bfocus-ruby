# frozen_string_literal: true

module Bfocus
  # Uma página de resultados das listas paginadas (`customers.list`, `interactions.list`,
  # `release_notes.list`, `kb.articles.list`). É `Enumerable` sobre {#items}.
  #
  # Para percorrer tudo sem controlar páginas, use o `list_all(...)` do recurso.
  #
  # @example
  #   page = client.customers.list(q: "padaria", page_size: 50)
  #   page.total          # => 123
  #   page.map { |c| c["name"] }
  #   page.next_page?     # => true
  class Page
    include Enumerable

    # @return [Array<Hash{String=>Object}>] itens da página (Hash com chaves string).
    attr_reader :items
    # @return [Integer] número desta página (1-based).
    attr_reader :page
    # @return [Integer] tamanho de página usado pela API.
    attr_reader :page_size
    # @return [Integer] total de itens (todas as páginas).
    attr_reader :total
    # @return [Integer] total de páginas.
    attr_reader :pages

    def initialize(items:, page:, page_size:, total:, pages:)
      @items = items
      @page = page
      @page_size = page_size
      @total = total
      @pages = pages
    end

    # Monta a página a partir do `data` + `pagination` do envelope da API.
    # @api private
    def self.from_response(data, pagination)
      items = data.is_a?(Array) ? data : []
      unless pagination.is_a?(Hash) # a API sempre manda; defensivo para não quebrar a iteração
        return new(items: items, page: 1, page_size: items.size, total: items.size, pages: 1)
      end

      new(
        items: items,
        page: (pagination["page"] || 1).to_i,
        page_size: (pagination["page_size"] || items.size).to_i,
        total: (pagination["total"] || items.size).to_i,
        pages: (pagination["pages"] || 1).to_i
      )
    end

    def each(&block)
      return enum_for(:each) { size } unless block

      items.each(&block)
      self
    end

    # @return [Integer] quantidade de itens NESTA página.
    def size
      items.size
    end
    alias length size

    def empty?
      items.empty?
    end

    # @return [Boolean] `true` se existe página depois desta.
    def next_page?
      page < pages
    end

    # @return [Hash{Symbol=>Object}] `{items:, page:, page_size:, total:, pages:}`
    def to_h
      { items: items, page: page, page_size: page_size, total: total, pages: pages }
    end

    def ==(other)
      other.is_a?(Page) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    def inspect
      "#<Bfocus::Page page=#{page}/#{pages} page_size=#{page_size} total=#{total} " \
        "items=#{items.size}>"
    end
  end
end
