# frozen_string_literal: true

# SDK oficial em Ruby da API pública do bFocus: clientes, produtos, release notes, base de
# conhecimento e agentes de IA. Só biblioteca padrão (net/http, json, openssl, securerandom).
#
# @example
#   require "bfocus"
#
#   client = Bfocus::Client.new(ENV.fetch("BFOCUS_API_KEY"))
#   client.customers.upsert("ERP 1042", name: "Padaria Estrela")
module Bfocus
end

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "time"
require "uri"

require_relative "bfocus/version"
require_relative "bfocus/unset"
require_relative "bfocus/errors"
require_relative "bfocus/page"
require_relative "bfocus/codec"
require_relative "bfocus/transport"
require_relative "bfocus/resources/base"
require_relative "bfocus/resources/customers"
require_relative "bfocus/resources/products"
require_relative "bfocus/resources/release_notes"
require_relative "bfocus/resources/knowledge_base"
require_relative "bfocus/resources/ai_agents"
require_relative "bfocus/client"
require_relative "bfocus/widget"
