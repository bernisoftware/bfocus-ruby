# frozen_string_literal: true

# A versão existe em dois lugares — `lib/bfocus/version.rb` e o gemspec (que lê
# `Bfocus::VERSION`) — e vai no header `X-Bfocus-Client` de TODA requisição: é por ele que a
# API sabe quem avisar quando uma correção exige atualizar a SDK. Se ele congelar (no bZapper
# congelou em 0.3.0 por releases seguidas), o aviso vai para o alvo errado.

require "test_helper"

class VersionTest < ServerTestCase
  VERSION_RB = File.join(TestSupport::ROOT, "lib", "bfocus", "version.rb")
  GEMSPEC = File.join(TestSupport::ROOT, "bfocus.gemspec")
  # O MESMO padrão do scripts/release-sdks.sh — `(?m)^(\s*VERSION\s*=\s*")([^"]+)(")` em Python
  # (em Ruby, `^` já é começo de linha). Se não casar, o bump não acontece; se casar num
  # comentário, o bump muda o comentário e a constante congela.
  RELEASE_RE = /^(\s*VERSION\s*=\s*")([^"]+)(")/.freeze

  def test_formato_da_versao
    assert_match(/\A\d+\.\d+\.\d+\z/, Bfocus::VERSION)
  end

  def test_padrao_do_release_casa_em_version_rb
    text = File.read(VERSION_RB, encoding: "UTF-8")
    match = RELEASE_RE.match(text) # como o `re.search` do release: a 1ª ocorrência é o alvo
    refute_nil match, "o padrão do release-sdks.sh não casa em lib/bfocus/version.rb"
    assert_equal Bfocus::VERSION, match[2]
    assert_equal 1, text.scan(RELEASE_RE).size, 'uma única linha VERSION = "..." em lib/bfocus/version.rb'

    # Simula o bump do release e avalia o resultado: a versão nova precisa aparecer na
    # CONSTANTE (e não num comentário que por acaso tenha o mesmo formato).
    bumped = text[0...match.begin(0)] + match[1] + "9.8.7" + match[3] + text[match.end(0)..]
    sandbox = Module.new
    sandbox.module_eval(bumped, VERSION_RB)
    assert_equal "9.8.7", sandbox.const_get(:Bfocus, false).const_get(:VERSION, false)
  end

  def test_gemspec_le_a_constante
    source = File.read(GEMSPEC, encoding: "UTF-8")
    assert_includes source, "spec.version = Bfocus::VERSION"
    refute_match(/spec\.version\s*=\s*["']/, source, "o gemspec não pode fixar o número")

    if TestSupport::AGAINST_GEM
      # Rodando contra a gem instalada: a versão dela é a do código carregado.
      assert_equal Bfocus::VERSION, Gem.loaded_specs.fetch("bfocus").version.to_s
      return
    end

    spec = Gem::Specification.load(GEMSPEC)
    assert_equal Bfocus::VERSION, spec.version.to_s
    assert_equal "bfocus", spec.name
    assert_equal Gem::Requirement.new(">= 3.0"), spec.required_ruby_version
    assert_empty spec.runtime_dependencies, "zero dependência de runtime"
    assert_equal "MIT", spec.license
    extra = spec.files.reject { |f| f.start_with?("lib/") || %w[README.md LICENSE].include?(f) }
    assert_empty extra, "a gem leva só lib/, README.md e LICENSE"
    assert_includes spec.files, "lib/bfocus.rb"
    assert_includes spec.files, "lib/bfocus/version.rb"
  end

  def test_identificacao_do_cliente
    assert_equal "bfocus-ruby/#{Bfocus::VERSION}", Bfocus::CLIENT_ID
    assert_match %r{\Abfocus-ruby/\d+\.\d+\.\d+\z}, Bfocus::CLIENT_ID
  end

  def test_header_vai_em_toda_requisicao
    bf = client([ok([]), ok({ "deleted" => true })])
    bf.products.list
    bf.customers.delete("C1")
    requests.each do |record|
      assert_equal "bfocus-ruby/#{Bfocus::VERSION}", record[:headers]["x-bfocus-client"]
      assert_equal "bfocus-ruby/#{Bfocus::VERSION}", record[:headers]["user-agent"]
    end
  end
end
