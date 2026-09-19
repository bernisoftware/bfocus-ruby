# frozen_string_literal: true

# Apoio dos testes: servidor HTTP falso (stdlib) e localização dos casos de conformidade.
#
# Os casos moram em `clients/conformance/cases.json` no monorepo. O espelho público
# (`bernisoftware/bfocus-ruby`) recebe só `clients/ruby` — por isso existe a cópia
# `test/fixtures/conformance/cases.json`, escrita pelo `clients/conformance/generate.py` (não
# edite à mão). A suíte lê a cópia; um teste trava que ela seja idêntica à fonte quando as
# duas existem (no monorepo).

require "json"
require "minitest/autorun"
require "bfocus"

require_relative "support/fake_server"

module TestSupport
  ROOT = File.expand_path("..", __dir__) # clients/ruby (ou a raiz do espelho público)
  VENDORED_CASES = File.join(ROOT, "test", "fixtures", "conformance", "cases.json")
  # No monorepo: <raiz>/clients/ruby. Fora dele (espelho, container) estes caminhos não
  # existem e os testes que dependem deles são pulados.
  MONOREPO_CASES = File.expand_path("../conformance/cases.json", ROOT)
  MONOREPO_SPEC = File.expand_path("../../api/openapi/public.json", ROOT)
  # CI do espelho: roda a suíte de novo contra a gem INSTALADA (não o ./lib).
  AGAINST_GEM = ENV["BFOCUS_TEST_AGAINST_GEM"] == "1"

  def self.read_json(path)
    JSON.parse(File.binread(path).force_encoding(Encoding::UTF_8))
  end

  def self.cases
    @cases ||= read_json(VENDORED_CASES)
  end

  def self.server
    @server ||= FakeServer.new.tap { |srv| Minitest.after_run { srv.stop } }
  end

  # Resposta de sucesso no envelope da API.
  def self.ok(data, status: 200, pagination: nil, headers: {})
    body = { "code" => status, "data" => data, "message" => "Executado com sucesso" }
    body["pagination"] = pagination if pagination
    { "status" => status, "headers" => headers, "body" => body }
  end

  # Resposta de erro no envelope da API.
  def self.fail_with(status, code, headers = {})
    {
      "status" => status,
      "headers" => headers,
      "body" => { "code" => status, "data" => nil, "message" => code, "error" => code,
                  "validation" => {}, "request_id" => "req-unit" }
    }
  end

  def self.json_body(record)
    raw = record[:body]
    raw.empty? ? nil : JSON.parse(raw.dup.force_encoding(Encoding::UTF_8))
  end
end

if TestSupport::AGAINST_GEM
  loaded = $LOADED_FEATURES.find { |path| path.end_with?("/bfocus.rb") }
  if loaded.nil? || loaded.start_with?(File.join(TestSupport::ROOT, "lib"))
    abort "BFOCUS_TEST_AGAINST_GEM=1, mas o bfocus foi carregado de #{loaded.inspect} (não da gem instalada)"
  end
  puts "bfocus carregado da gem instalada: #{loaded}"
end

# Base dos testes que falam com o servidor falso.
class ServerTestCase < Minitest::Test
  def server
    TestSupport.server
  end

  def requests
    server.requests
  end

  def client(responses, **options)
    server.reset(responses)
    @sleeps = []
    sleeps = @sleeps
    Bfocus::Client.new("bf_live_unit", base_url: server.base_url,
                                       sleeper: ->(seconds) { sleeps << seconds }, **options)
  end

  def ok(data, **kwargs)
    TestSupport.ok(data, **kwargs)
  end

  def fail_with(status, code, headers = {})
    TestSupport.fail_with(status, code, headers)
  end

  def json_body(record)
    TestSupport.json_body(record)
  end
end
