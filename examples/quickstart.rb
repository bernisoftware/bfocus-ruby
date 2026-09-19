# frozen_string_literal: true

# bFocus — quickstart da SDK Ruby.
#
# Rodar:
#   gem install bfocus
#   BFOCUS_API_KEY=bf_live_... ruby examples/quickstart.rb
#
# De dentro do repositório da SDK (sem instalar): ruby -Ilib examples/quickstart.rb
# Opcional: BFOCUS_BASE_URL=http://localhost:8000 para apontar para a API local.
# A chave precisa dos escopos customers:write, products:read e kb:read.

require "bfocus"

api_key = ENV["BFOCUS_API_KEY"].to_s
if api_key.empty?
  warn "Defina BFOCUS_API_KEY (Integrações → Chaves de API no bFocus)."
  exit 2
end

# base_url vazio/nil cai no padrão (produção).
client = Bfocus::Client.new(api_key, base_url: ENV["BFOCUS_BASE_URL"])

begin
  # 1) Cliente: cria ou atualiza pelo id do SEU sistema. Só o que você passa muda.
  customer = client.customers.upsert(
    "ERP 1042",
    name: "Padaria Estrela",
    email: "contato@padaria.example",
    custom_fields: [{ key: "plano", label: "Plano", value: "ouro" }]
  )
  puts "cliente: #{customer['id']} #{customer['name']}"

  # 2) Registro no histórico do cliente.
  client.customers.interactions.create("ERP 1042", "Cliente sincronizado pelo quickstart.")

  # 3) Catálogo de produtos.
  client.products.list.each do |product|
    puts "produto: #{product['slug']} - #{product['name']}"
  end

  # 4) Busca na base de conhecimento (exige o módulo de Atendimento).
  client.kb.search("como emitir nota fiscal", limit: 3).each do |hit|
    puts "artigo: #{hit['title']}"
  end

  # 5) Clientes com "padaria" (percorre todas as páginas sozinho, sob demanda).
  puts "clientes com 'padaria': #{client.customers.list_all(q: 'padaria').count}"
rescue Bfocus::Error => e
  # Decida pelo `code` (estável); informe o `request_id` ao suporte.
  warn "erro #{e.code} (HTTP #{e.status}) request_id=#{e.request_id}"
  exit 1
end

# 6) Identidade do widget: assinada no SEU backend, sem rede e sem chave de API.
secret = ENV["BFOCUS_WIDGET_SECRET"].to_s
puts "assinatura do widget: #{Bfocus.sign_widget_identity(secret, 'USR-1', 'ERP 1042')}" unless secret.empty?
