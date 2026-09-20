# frozen_string_literal: true

# Conformidade: roda TODOS os casos de `test/fixtures/conformance/cases.json` (BRIEF §7).
#
# Para cada caso, o servidor HTTP local confere cada troca — método, caminho exatamente como
# codificado, query, corpo JSON, `Authorization`, `X-Bfocus-Client`, `X-Request-Id`,
# `Idempotency-Key` — e, entre novas tentativas da mesma chamada, que os ids se repetem.
# Depois compara o retorno (ou o erro) com `expect`.
#
# Endpoint novo sem método na SDK quebra este teste: todo `op` dos casos precisa estar em
# `OPS` (a menos que esteja em `sdk_excluded_ops`).

require "test_helper"

module Conformance
  CASES = TestSupport.cases
  API_KEY = CASES.fetch("api_key")
  EXCLUDED = CASES.fetch("sdk_excluded_ops", []).freeze
  HELPERS = CASES.fetch("sdk_helper_ops", {}).freeze
  CLIENT_RE = %r{\Abfocus-ruby/#{Regexp.escape(Bfocus::VERSION)}\z}.freeze
  REQUEST_ID_RE = /\A[0-9a-f]{32}\z/.freeze
  WRITES = %w[POST PUT PATCH DELETE].freeze
  SENT = "$sent" # em expect.error.request_id: "o X-Request-Id que a SDK enviou"

  # op (neutro) → método da SDK. Os `args` dos casos já estão em snake_case e batem com os
  # nomes dos parâmetros: os obrigatórios (posicionais) saem pelo nome, o resto vira keyword.
  OPS = {
    "customers.upsert" => ->(c) { c.customers.method(:upsert) },
    "customers.get" => ->(c) { c.customers.method(:get) },
    "customers.list" => ->(c) { c.customers.method(:list) },
    "customers.list_all" => ->(c) { c.customers.method(:list_all) },
    "customers.delete" => ->(c) { c.customers.method(:delete) },
    "customers.batch" => ->(c) { c.customers.method(:batch) },
    "customers.identifiers.add" => ->(c) { c.customers.identifiers.method(:add) },
    "customers.identifiers.remove" => ->(c) { c.customers.identifiers.method(:remove) },
    "people.upsert" => ->(c) { c.people.method(:upsert) },
    "people.list" => ->(c) { c.people.method(:list) },
    "people.delete" => ->(c) { c.people.method(:delete) },
    "people.batch" => ->(c) { c.people.method(:batch) },
    "people.identifiers.list" => ->(c) { c.people.identifiers.method(:list) },
    "people.identifiers.add" => ->(c) { c.people.identifiers.method(:add) },
    "people.identifiers.remove" => ->(c) { c.people.identifiers.method(:remove) },
    "customers.contacts.list" => ->(c) { c.customers.contacts.method(:list) },
    "customers.contacts.upsert" => ->(c) { c.customers.contacts.method(:upsert) },
    "customers.contacts.delete" => ->(c) { c.customers.contacts.method(:delete) },
    "customers.products.list" => ->(c) { c.customers.products.method(:list) },
    "customers.products.attach" => ->(c) { c.customers.products.method(:attach) },
    "customers.products.detach" => ->(c) { c.customers.products.method(:detach) },
    "customers.interactions.list" => ->(c) { c.customers.interactions.method(:list) },
    "customers.interactions.list_all" => ->(c) { c.customers.interactions.method(:list_all) },
    "customers.interactions.create" => ->(c) { c.customers.interactions.method(:create) },
    "products.list" => ->(c) { c.products.method(:list) },
    "products.get" => ->(c) { c.products.method(:get) },
    "products.upsert" => ->(c) { c.products.method(:upsert) },
    "products.archive" => ->(c) { c.products.method(:archive) },
    "release_notes.list" => ->(c) { c.release_notes.method(:list) },
    "release_notes.list_all" => ->(c) { c.release_notes.method(:list_all) },
    "release_notes.get" => ->(c) { c.release_notes.method(:get) },
    "release_notes.upsert" => ->(c) { c.release_notes.method(:upsert) },
    "release_notes.publish" => ->(c) { c.release_notes.method(:publish) },
    "kb.articles.list" => ->(c) { c.kb.articles.method(:list) },
    "kb.articles.list_all" => ->(c) { c.kb.articles.method(:list_all) },
    "kb.articles.get" => ->(c) { c.kb.articles.method(:get) },
    "kb.articles.upsert" => ->(c) { c.kb.articles.method(:upsert) },
    "kb.articles.batch_upsert" => ->(c) { c.kb.articles.method(:batch_upsert) },
    "kb.articles.publish" => ->(c) { c.kb.articles.method(:publish) },
    "kb.articles.unpublish" => ->(c) { c.kb.articles.method(:unpublish) },
    "kb.articles.delete" => ->(c) { c.kb.articles.method(:delete) },
    "kb.search" => ->(c) { c.kb.method(:search) },
    "ai_agents.list" => ->(c) { c.ai_agents.method(:list) },
    "ai_agents.get" => ->(c) { c.ai_agents.method(:get) },
    "ai_agents.preview" => ->(c) { c.ai_agents.method(:preview) }
  }.freeze

  ERROR_TYPES = {
    "authentication" => Bfocus::AuthenticationError,
    "permission_denied" => Bfocus::PermissionDeniedError,
    "not_found" => Bfocus::NotFoundError,
    "conflict" => Bfocus::ConflictError,
    "validation" => Bfocus::ValidationError,
    "rate_limit" => Bfocus::RateLimitError,
    "server" => Bfocus::ServerError,
    "network" => Bfocus::NetworkError,
    "api" => Bfocus::Error
  }.freeze

  module_function

  # `args` neutros → chamada idiomática: parâmetros obrigatórios (posicionais) pelo nome, o
  # resto como keyword args. Argumento que o método não conhece estoura ArgumentError.
  def invoke(method, args)
    rest = args.dup
    positional = []
    method.parameters.each do |kind, name|
      next unless kind == :req
      raise ArgumentError, "caso sem o argumento obrigatório #{name}" unless rest.key?(name.to_s)

      positional << rest.delete(name.to_s)
    end
    method.call(*positional, **rest.transform_keys(&:to_sym))
  end

  # Retorno da SDK → JSON neutro (`Page` vira Hash; Enumerator vira lista).
  def normalize(value)
    case value
    when Bfocus::Page
      { "items" => value.items, "page" => value.page, "page_size" => value.page_size,
        "total" => value.total, "pages" => value.pages }
    when Enumerator then value.to_a
    else value
    end
  end

  # Forma canônica: distingue `1` de `1.0` e ignora a ordem das chaves.
  def canonical(value)
    JSON.generate(sort_keys(value))
  end

  def sort_keys(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, sort_keys(value[key])] }
    when Array then value.map { |item| sort_keys(item) }
    else value
    end
  end
end

class ConformanceTest < Minitest::Test
  include Conformance

  def assert_json_equal(expected, actual, what)
    assert_equal expected, actual, what
    assert_equal Conformance.canonical(expected), Conformance.canonical(actual), "#{what} (tipos JSON)"
  end

  def run_case(kase)
    op = kase.fetch("op")
    skip "#{op} fora da SDK (sdk_excluded_ops)" if EXCLUDED.include?(op)
    assert OPS.key?(op), "op #{op.inspect} sem método na SDK (e fora de sdk_excluded_ops)"

    exchanges = kase.fetch("exchanges")
    server = TestSupport.server
    server.reset(exchanges.map { |exchange| exchange["response"] })
    sleeps = []
    client = Bfocus::Client.new(API_KEY, base_url: server.base_url, sleeper: ->(s) { sleeps << s })

    result = nil
    error = nil
    begin
      args = Marshal.load(Marshal.dump(kase.fetch("args")))
      result = Conformance.normalize(Conformance.invoke(OPS.fetch(op).call(client), args))
    rescue Bfocus::Error => e
      error = e
    end

    sent = server.requests
    assert_empty server.errors, "erros no servidor falso"
    check_exchanges(exchanges, sent)
    assert_equal exchanges.count { |exchange| exchange["retry"] }, sleeps.size,
                 "uma espera (desligada) por nova tentativa"

    expect = kase.fetch("expect")
    if expect.key?("error")
      want = expect["error"]
      refute_nil error, "esperava erro #{want['type']}, veio #{result.inspect}"
      assert_instance_of ERROR_TYPES.fetch(want["type"]), error
      assert_equal want["code"], error.code
      assert_equal want["status"], error.status
      if want.key?("request_id")
        expected_id = want["request_id"]
        if expected_id == SENT
          expected_id = sent.last[:headers]["x-request-id"]
          refute_nil expected_id
        end
        assert_equal expected_id, error.request_id
      end
      assert_equal want["retry_after"], error.retry_after if want.key?("retry_after")
      assert_equal want["required_scope"], error.required_scope if want.key?("required_scope")
      assert_equal want["validation"], error.validation if want.key?("validation")
      assert_includes error.message, want["code"]
    else
      assert_nil error, "erro inesperado: #{error.inspect}"
      assert_json_equal expect["result"], result, "resultado"
    end
  end

  def check_exchanges(exchanges, sent)
    assert_equal exchanges.size, sent.size,
                 "nº de requisições: #{sent.map { |r| "#{r[:method]} #{r[:path]}" }.join(', ')}"
    previous = nil
    exchanges.zip(sent).each_with_index do |(exchange, got), index|
      want = exchange.fetch("request")
      where = "troca #{index}"
      headers = got[:headers]

      assert_equal want["method"], got[:method], "#{where}: método"
      assert_equal want["path"], got[:path], "#{where}: caminho (cru)"
      assert_equal want["query"].to_a.sort, got[:query].sort, "#{where}: query"
      if want["body"].nil?
        assert_equal "", got[:body], "#{where}: não devia ter corpo"
        refute headers.key?("content-type"), "#{where}: Content-Type sem corpo"
      else
        assert_equal "application/json", headers["content-type"], "#{where}: Content-Type"
        body = JSON.parse(got[:body].dup.force_encoding(Encoding::UTF_8))
        assert_json_equal want["body"], body, "#{where}: corpo"
      end

      assert_equal "Bearer #{API_KEY}", headers["authorization"], "#{where}: Authorization"
      assert_equal "application/json", headers["accept"], "#{where}: Accept"
      assert_match CLIENT_RE, headers["x-bfocus-client"].to_s, "#{where}: X-Bfocus-Client"
      assert_equal headers["x-bfocus-client"], headers["user-agent"], "#{where}: User-Agent"
      assert_match REQUEST_ID_RE, headers["x-request-id"].to_s, "#{where}: X-Request-Id"
      if WRITES.include?(want["method"])
        refute_empty headers["idempotency-key"].to_s, "#{where}: Idempotency-Key"
      else
        refute headers.key?("idempotency-key"), "#{where}: Idempotency-Key em GET"
      end

      assert exchange.key?("retry"), "#{where}: troca sem o campo 'retry'"
      if index.zero?
        refute exchange["retry"], "a 1ª troca não pode ser nova tentativa"
      elsif exchange["retry"]
        # nova tentativa da MESMA chamada: ids repetidos
        assert_equal previous["x-request-id"], headers["x-request-id"], "#{where}: X-Request-Id da nova tentativa"
        if WRITES.include?(want["method"]) # em GET a ausência já foi conferida acima
          assert_equal previous["idempotency-key"], headers["idempotency-key"],
                       "#{where}: Idempotency-Key da nova tentativa"
        end
      else
        # chamada lógica nova (ex.: próxima página do list_all): ids novos
        refute_equal previous["x-request-id"], headers["x-request-id"],
                     "#{where}: chamada nova precisa de X-Request-Id novo"
        if headers.key?("idempotency-key")
          refute_equal previous["idempotency-key"], headers["idempotency-key"],
                       "#{where}: chamada nova precisa de Idempotency-Key nova"
        end
      end
      previous = headers
    end
  end

  seen = {}
  Conformance::CASES.fetch("cases").each do |kase|
    name = "test_case_#{kase.fetch('id').gsub(/\W+/, '_').gsub(/\A_+|_+\z/, '')}"
    raise "id de caso duplicado: #{kase['id']}" if seen.key?(name)

    seen[name] = true
    define_method(name) { run_case(kase) }
  end
end

class ConformanceCoverageTest < Minitest::Test
  include Conformance

  def test_os_casos_foram_carregados
    assert_operator CASES.fetch("cases").size, :>=, 66
    assert_equal 1, CASES.fetch("version")
  end

  def test_todo_op_dos_casos_tem_metodo
    ops = CASES.fetch("cases").map { |kase| kase["op"] }.uniq
    assert_equal [], (ops - OPS.keys - EXCLUDED).sort, "ops sem método na SDK — implemente ou exclua"
  end

  def test_op_desconhecido_falha
    fake = { "id" => "x/y", "op" => "nao.existe", "args" => {}, "exchanges" => [], "expect" => { "result" => nil } }
    error = assert_raises(Minitest::Assertion) { ConformanceTest.new("probe").run_case(fake) }
    assert_includes error.message, "nao.existe"
  end

  def test_helpers_apontam_para_ops_mapeados
    refute_empty HELPERS
    HELPERS.each do |helper, base|
      assert OPS.key?(helper), "helper #{helper} sem método"
      assert OPS.key?(base), "op base #{base} sem método"
    end
  end

  def test_excluidos_nao_estao_na_sdk
    assert_equal [], (EXCLUDED & OPS.keys)
    client = Bfocus::Client.new(API_KEY)
    refute client.customers.respond_to?(:create), "customers.create (formato legado) não entra na SDK"
  end

  def test_toda_operacao_da_spec_tem_metodo
    skip "public.json só existe no monorepo" unless File.file?(TestSupport::MONOREPO_SPEC)

    spec = TestSupport.read_json(TestSupport::MONOREPO_SPEC)
    op_ids = spec.fetch("paths").values.flat_map do |item|
      item.values.filter_map { |op| op["operationId"] if op.is_a?(Hash) }
    end
    assert_equal [], (op_ids.uniq - OPS.keys - EXCLUDED).sort
  end

  def test_copia_dos_casos_em_dia
    skip "fonte dos casos só existe no monorepo" unless File.file?(TestSupport::MONOREPO_CASES)

    assert File.binread(TestSupport::VENDORED_CASES) == File.binread(TestSupport::MONOREPO_CASES),
           "test/fixtures/conformance/cases.json desatualizado — rode " \
           "`python3 clients/conformance/generate.py` (ele escreve a cópia; não edite à mão)"
  end
end

class SignatureVectorsTest < Minitest::Test
  def test_vetores
    vectors = Conformance::CASES.fetch("signatures")
    refute_empty vectors
    vectors.each do |vector|
      got = Bfocus.sign_widget_identity(vector["secret"], vector["user_external_id"], vector["customer_external_id"])
      assert_equal vector["expected"], got, "vetor #{vector['user_external_id']}"
    end
  end

  def test_vetores_v2
    vectors = Conformance::CASES.fetch("signatures_v2")
    refute_empty vectors
    vectors.each do |vector|
      got = Bfocus.sign_widget_identity_v2(vector["secret"], vector["user_external_id"],
                                           vector["customer_external_id"], now: vector["timestamp"])
      assert_equal vector["expected"], got, "vetor v2 #{vector['user_external_id']}"
      at = Time.at(vector["timestamp"] + 0.9)
      assert_equal vector["expected"],
                   Bfocus.sign_widget_identity_v2(vector["secret"], vector["user_external_id"],
                                                  vector["customer_external_id"], now: at),
                   "Time com fração vira segundos inteiros (floor)"
    end
  end
end
