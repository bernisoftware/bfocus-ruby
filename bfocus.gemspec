# frozen_string_literal: true

# A versão vem de Bfocus::VERSION (lib/bfocus/version.rb) — o scripts/release-sdks.sh bumpa só
# aquela linha. Não escreva o número aqui.
require_relative "lib/bfocus/version"

Gem::Specification.new do |spec|
  spec.name = "bfocus"
  spec.version = Bfocus::VERSION
  spec.authors = ["Berni Software"]
  spec.summary = "SDK oficial da API pública do bFocus"
  spec.description = "Clientes, produtos, release notes, base de conhecimento e agentes de IA do " \
                     "bFocus. Zero dependências de runtime, novas tentativas e idempotência automáticas."
  spec.homepage = "https://bfocus.com.br"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/bernisoftware/bfocus-ruby",
    "bug_tracker_uri" => "https://github.com/bernisoftware/bfocus-ruby/issues",
    "documentation_uri" => "https://github.com/bernisoftware/bfocus-ruby#readme"
  }

  # Só o que o usuário precisa: código, README e licença (testes e CI ficam no repositório).
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"].sort + %w[README.md LICENSE] }
  spec.require_paths = ["lib"]
end
