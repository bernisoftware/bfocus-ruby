# frozen_string_literal: true

module Bfocus
  # Cliente da API pública do bFocus.
  #
  # Nada é chamado na rede ao construir. Pode ser compartilhado entre threads (cada tentativa
  # abre a própria conexão).
  #
  # @example
  #   client = Bfocus::Client.new(ENV.fetch("BFOCUS_API_KEY"))
  #   client.customers.upsert("ERP 1042", name: "Padaria Estrela")
  class Client
    # @return [Resources::Customers] clientes (empresas), com `.contacts`, `.products` e
    #   `.interactions` e `.identifiers`.
    attr_reader :customers
    # @return [Resources::People] pessoas (usuários) dos clientes, com `.identifiers`.
    attr_reader :people
    # @return [Resources::Products] catálogo de produtos.
    attr_reader :products
    # @return [Resources::ReleaseNotes] release notes por produto.
    attr_reader :release_notes
    # @return [Resources::KnowledgeBase] base de conhecimento: `.articles` e `.search(...)`.
    attr_reader :kb
    # @return [Resources::AIAgents] agentes de IA.
    attr_reader :ai_agents

    # @param api_key [String] chave de API (Integrações → Chaves de API). Único argumento
    #   posicional e obrigatório.
    # @param base_url [String] URL da API, sem barra final. Padrão: produção
    #   (`https://api.bfocus.com.br`). Em dev: `http://localhost:8000`.
    # @param timeout [Numeric] segundos por tentativa (padrão 30).
    # @param max_retries [Integer] novas tentativas além da primeira em erro de rede/timeout,
    #   429, 502, 503 e 504 (padrão 2; `0` desliga).
    # @param sleeper [#call, nil] espera entre tentativas, chamada com os segundos (padrão
    #   `Kernel#sleep`). Serve para testes não dormirem de verdade.
    # @raise [ArgumentError] chave vazia ou opção inválida.
    # @raise [TypeError] chave que não é String.
    def initialize(api_key, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT,
                   max_retries: DEFAULT_MAX_RETRIES, sleeper: nil)
      raise TypeError, "Bfocus::Client: api_key precisa ser String (ex.: \"bf_live_...\")." unless api_key.is_a?(String)
      raise ArgumentError, "Bfocus::Client: api_key é obrigatória (ex.: \"bf_live_...\")." if api_key.strip.empty?
      unless max_retries.is_a?(Integer) && max_retries >= 0
        raise ArgumentError, "Bfocus::Client: max_retries precisa ser um inteiro >= 0."
      end
      unless timeout.is_a?(Numeric) && timeout.positive?
        raise ArgumentError, "Bfocus::Client: timeout precisa ser > 0 (segundos)."
      end
      if !sleeper.nil? && !sleeper.respond_to?(:call)
        raise ArgumentError, "Bfocus::Client: sleeper precisa responder a #call(segundos)."
      end

      url = base_url.to_s.strip
      url = DEFAULT_BASE_URL if url.empty?
      @transport = Transport.new(api_key, base_url: url, timeout: timeout,
                                          max_retries: max_retries, sleeper: sleeper)
      @customers = Resources::Customers.new(@transport)
      @people = Resources::People.new(@transport)
      @products = Resources::Products.new(@transport)
      @release_notes = Resources::ReleaseNotes.new(@transport)
      @kb = Resources::KnowledgeBase.new(@transport)
      @ai_agents = Resources::AIAgents.new(@transport)
      @masked_key = api_key.length > 8 ? "#{api_key[0, 8]}…" : "…"
    end

    # @return [String] URL da API (sem barra final).
    def base_url
      @transport.base_url
    end

    # @return [Numeric] segundos por tentativa.
    def timeout
      @transport.timeout
    end

    # @return [Integer] novas tentativas além da primeira.
    def max_retries
      @transport.max_retries
    end

    def inspect
      "#<Bfocus::Client api_key=#{@masked_key.inspect} base_url=#{base_url.inspect}>"
    end
    alias to_s inspect
  end
end
