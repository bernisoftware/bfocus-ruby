# frozen_string_literal: true

module Bfocus
  # Marca de argumento **não informado** — diferente de `nil`, que vai como `null` e LIMPA o
  # campo na API. É o valor padrão dos keyword args opcionais de corpo; você nunca precisa
  # usá-la. Existe uma única instância: {Bfocus::UNSET}.
  class Unset
    def inspect
      "Bfocus::UNSET"
    end
    alias to_s inspect

    # Continua sendo a mesma instância (comparação por identidade).
    def dup
      self
    end

    # Continua sendo a mesma instância (comparação por identidade).
    def clone(freeze: true) # rubocop:disable Lint/UnusedMethodArgument
      self
    end
  end

  # Valor padrão dos keyword args opcionais de corpo: "não envie este campo".
  UNSET = Unset.new.freeze
  Unset.private_class_method :new
end
