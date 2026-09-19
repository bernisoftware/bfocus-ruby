# frozen_string_literal: true

# Unitários: lotes (batch_upsert, customers/people.batch), list_all, novas tentativas, rede,
# codificação, erros, assinatura do widget (v1 e v2).

require "date"
require "socket"
require "test_helper"

def customer_item(number)
  { "id" => "id-#{number}", "external_id" => "C#{number}", "name" => "Cliente #{number}" }
end

class BatchUpsertTest < ServerTestCase
  # Chaves string sem chaves `{}` virariam **kwargs no Ruby 3 — o Hash vai explícito.
  def chunk_response(chunk)
    ok({
         "results" => chunk.map do |article|
           { "external_id" => article["external_id"] || article[:external_id], "ok" => true,
             "action" => "created", "error" => nil, "article" => nil }
         end,
         "created" => chunk.size, "updated" => 0, "unchanged" => 0, "failed" => 0
       })
  end

  def test_divide_em_lotes_de_100_e_agrega
    articles = Array.new(250) { |i| { "external_id" => "git:a#{i}", "title" => "A#{i}" } }
    bf = client(articles.each_slice(100).map { |chunk| chunk_response(chunk) })

    out = bf.kb.articles.batch_upsert(articles)

    assert_equal 3, requests.size
    bodies = requests.map { |r| json_body(r) }
    assert_equal [100, 100, 50], bodies.map { |b| b["articles"].size }
    assert_equal articles.map { |a| a["external_id"] }, bodies.flat_map { |b| b["articles"].map { |a| a["external_id"] } }
    requests.each do |r|
      assert_equal "POST", r[:method]
      assert_equal "/api/v1/integration/kb/articles/batch", r[:path]
    end
    # cada lote é uma chamada lógica: ids próprios
    assert_equal 3, requests.map { |r| r[:headers]["idempotency-key"] }.uniq.size
    assert_equal 3, requests.map { |r| r[:headers]["x-request-id"] }.uniq.size

    assert_equal articles.map { |a| a["external_id"] }, out["results"].map { |r| r["external_id"] }
    assert_equal [250, 0, 0, 0], out.values_at("created", "updated", "unchanged", "failed")
  end

  def test_exatamente_100_vai_em_um_lote
    articles = Array.new(100) { |i| { "external_id" => "git:a#{i}" } }
    client([chunk_response(articles)]).kb.articles.batch_upsert(articles)
    assert_equal 1, requests.size
  end

  def test_idempotency_key_do_usuario_por_lote
    articles = Array.new(150) { |i| { "external_id" => "git:a#{i}" } }
    bf = client([chunk_response(articles[0, 100]), chunk_response(articles[100..])])
    bf.kb.articles.batch_upsert(articles, idempotency_key: "sync-42")
    assert_equal %w[sync-42 sync-42:2], requests.map { |r| r[:headers]["idempotency-key"] }

    many = Array.new(250) { |i| { "external_id" => "git:a#{i}" } }
    bf = client(many.each_slice(100).map { |chunk| chunk_response(chunk) })
    bf.kb.articles.batch_upsert(many, idempotency_key: "k")
    assert_equal %w[k k:2 k:3], requests.map { |r| r[:headers]["idempotency-key"] }

    bf = client([chunk_response(articles[0, 1])])
    bf.kb.articles.batch_upsert(articles[0, 1], idempotency_key: "sync-43")
    assert_equal "sync-43", requests.first[:headers]["idempotency-key"]
  end

  def test_soma_contadores_mistos
    articles = Array.new(101) { |i| { "external_id" => "git:a#{i}" } }
    first = ok({ "results" => [{ "external_id" => "x", "ok" => true }] * 100,
                 "created" => 60, "updated" => 30, "unchanged" => 9, "failed" => 1 })
    second = ok({ "results" => [{ "external_id" => "y", "ok" => false }],
                  "created" => 0, "updated" => 0, "unchanged" => 0, "failed" => 1, "novo" => "x" })
    out = client([first, second]).kb.articles.batch_upsert(articles)
    assert_equal 101, out["results"].size
    assert_equal [60, 30, 9, 2], out.values_at("created", "updated", "unchanged", "failed")
    assert_equal "x", out["novo"], "campo novo não numérico é preservado"
  end

  def test_vazio_nao_chama_a_api
    out = client([]).kb.articles.batch_upsert([])
    assert_empty requests
    assert_equal({ "results" => [], "created" => 0, "updated" => 0, "unchanged" => 0, "failed" => 0 }, out)
  end

  def test_valida_external_id_antes_de_enviar
    bf = client([])
    assert_raises(ArgumentError) { bf.kb.articles.batch_upsert([{ "title" => "sem id" }]) }
    assert_raises(ArgumentError) { bf.kb.articles.batch_upsert([{ "external_id" => "" }]) }
    assert_raises(ArgumentError) { bf.kb.articles.batch_upsert([{ "external_id" => "docs/guia" }]) }
    assert_raises(TypeError) { bf.kb.articles.batch_upsert(["git:a"]) }
    assert_raises(TypeError) { bf.kb.articles.batch_upsert({ "external_id" => "git:a" }) }
    assert_empty requests
  end

  def test_product_null_explicito_e_chaves_simbolo
    article = { external_id: "git:global", title: "G", product: nil }
    client([chunk_response([article])]).kb.articles.batch_upsert([article])
    assert_equal({ "articles" => [{ "external_id" => "git:global", "title" => "G", "product" => nil }] },
                 json_body(requests.first))
  end
end

class ListAllTest < ServerTestCase
  def test_percorre_todas_as_paginas_preguicosamente
    bf = client([
                  ok([customer_item(1), customer_item(2)], pagination: { "page" => 1, "page_size" => 2, "total" => 5, "pages" => 3 }),
                  ok([customer_item(3), customer_item(4)], pagination: { "page" => 2, "page_size" => 2, "total" => 5, "pages" => 3 }),
                  ok([customer_item(5)], pagination: { "page" => 3, "page_size" => 2, "total" => 5, "pages" => 3 })
                ])
    all = bf.customers.list_all(q: "padaria", page_size: 2)
    assert_kind_of Enumerator::Lazy, all
    assert_empty requests, "list_all é preguiçoso"
    assert_equal %w[C1 C2 C3 C4 C5], all.map { |c| c["external_id"] }.to_a
    assert_equal((1..3).map { |n| [["page", n.to_s], ["page_size", "2"], %w[q padaria]] },
                 requests.map { |r| r[:query].sort })
  end

  def test_first_so_busca_o_necessario
    page = { "page" => 1, "page_size" => 2, "total" => 6, "pages" => 3 }
    bf = client([ok([customer_item(1), customer_item(2)], pagination: page)])
    assert_equal %w[C1], bf.customers.list_all(page_size: 2).first(1).map { |c| c["external_id"] }
    assert_equal 1, requests.size
  end

  def test_page_size_padrao_100
    bf = client([ok([], pagination: { "page" => 1, "page_size" => 100, "total" => 0, "pages" => 0 })])
    assert_equal [], bf.customers.list_all.to_a
    assert_equal [%w[page 1], %w[page_size 100]], requests.first[:query].sort
  end

  def test_para_em_pagina_vazia
    bf = client([ok([], pagination: { "page" => 1, "page_size" => 2, "total" => 9, "pages" => 5 })])
    assert_equal [], bf.customers.list_all(page_size: 2).to_a
    assert_equal 1, requests.size
  end

  def test_outros_list_all
    one = { "page" => 1, "page_size" => 100, "total" => 1, "pages" => 1 }
    bf = client([ok([{ "id" => "i" }], pagination: one)] * 3)
    total = bf.customers.interactions.list_all("ERP 1").to_a.size +
            bf.release_notes.list_all("erp", published: false).to_a.size +
            bf.kb.articles.list_all(product: "erp", status: "draft").to_a.size
    assert_equal 3, total
    assert_equal [
      ["/api/v1/integration/customers/ERP%201/interactions", [%w[page 1], %w[page_size 100]]],
      ["/api/v1/integration/products/erp/release-notes", [%w[page 1], %w[page_size 100], %w[published false]]],
      ["/api/v1/integration/kb/articles", [%w[page 1], %w[page_size 100], %w[product erp], %w[status draft]]]
    ], requests.map { |r| [r[:path], r[:query].sort] }
  end

  def test_page_enumerable
    bf = client([ok([customer_item(1)], pagination: { "page" => 1, "page_size" => 1, "total" => 2, "pages" => 2 })])
    page = bf.customers.list(page_size: 1)
    assert_instance_of Bfocus::Page, page
    assert_equal %w[C1], page.map { |c| c["external_id"] }
    assert_equal 1, page.size
    assert page.next_page?
    assert_equal({ items: [customer_item(1)], page: 1, page_size: 1, total: 2, pages: 2 }, page.to_h)
    assert_equal 1, page.each.size
  end
end

class RetryTest < ServerTestCase
  def test_backoff_exponencial_com_jitter_e_ids_repetidos
    bf = client([fail_with(503, "X"), fail_with(504, "X"), ok({ "deleted" => true })])
    assert_equal({ "deleted" => true }, bf.customers.delete("C1"))
    assert_equal 2, @sleeps.size
    assert_includes 0.5..0.625, @sleeps[0]
    assert_includes 1.0..1.25, @sleeps[1]
    assert_equal 1, requests.map { |r| r[:headers]["idempotency-key"] }.uniq.size
    assert_equal 1, requests.map { |r| r[:headers]["x-request-id"] }.uniq.size
  end

  def test_backoff_tem_teto_de_8s
    assert_includes 8.0..10.0, Bfocus::Transport.backoff(10)
  end

  def test_retry_after_tem_teto_de_60s
    bf = client([fail_with(429, "RATE_LIMITED", { "Retry-After" => "120" }), ok({ "id" => "x" })])
    bf.products.get("erp")
    assert_equal [60.0], @sleeps
  end

  def test_retry_after_vale_em_503
    bf = client([fail_with(503, "X", { "Retry-After" => "3" }), ok({ "id" => "x" })])
    bf.products.get("erp")
    assert_equal [3.0], @sleeps
  end

  def test_retry_after_em_data_http_com_teto
    soon = (Time.now + 30).httpdate
    later = (Time.now + 3600).httpdate
    bf = client([fail_with(503, "X", { "Retry-After" => soon }),
                 fail_with(429, "RATE_LIMITED", { "Retry-After" => later }),
                 ok({ "id" => "x" })])
    assert_equal({ "id" => "x" }, bf.products.get("erp"))
    assert_equal 2, @sleeps.size
    assert_includes 25.0..31.0, @sleeps[0]
    assert_equal 60.0, @sleeps[1]
  end

  def test_retry_after_do_erro_so_em_429
    bf = client([fail_with(503, "UNAVAILABLE", { "Retry-After" => "5" })], max_retries: 0)
    error = assert_raises(Bfocus::ServerError) { bf.products.get("erp") }
    assert_nil error.retry_after, "retry_after do erro só é preenchido em 429"
    assert_equal 503, error.status
  end

  def test_500_e_4xx_nao_repetem
    bf = client([fail_with(500, "INTERNAL_ERROR")])
    assert_raises(Bfocus::ServerError) { bf.products.get("erp") }
    assert_equal [1, []], [requests.size, @sleeps]

    bf = client([fail_with(400, "BAD_REQUEST")])
    error = assert_raises(Bfocus::Error) { bf.products.get("erp") }
    assert_instance_of Bfocus::Error, error
    assert_equal [1, []], [requests.size, @sleeps]
  end

  def test_max_retries_zero
    bf = client([fail_with(429, "RATE_LIMITED", { "Retry-After" => "2" })], max_retries: 0)
    error = assert_raises(Bfocus::RateLimitError) { bf.products.get("erp") }
    assert_equal 2, error.retry_after
    assert_includes error.message, "tente de novo em 2s"
    assert_equal [1, []], [requests.size, @sleeps]
  end

  def test_nao_json_esgotado
    bad = { "status" => 502, "headers" => {}, "body" => "Bad Gateway" }
    bf = client([bad, bad, bad])
    error = assert_raises(Bfocus::ServerError) { bf.products.get("erp") }
    assert_equal ["HTTP_502", 502], [error.code, error.status]
    assert_equal "Bad Gateway", error.body
    assert_equal 3, requests.size
  end

  def test_parse_retry_after
    parse = Bfocus::Transport.method(:parse_retry_after)
    assert_equal 7, parse.call("7")
    assert_instance_of Integer, parse.call("7")
    assert_equal 1.5, parse.call("1.5")
    assert_nil parse.call(nil)
    assert_nil parse.call("")
    assert_nil parse.call("amanhã")
    assert_includes 25..31, parse.call((Time.now + 30).httpdate)
    assert_equal 0, parse.call((Time.now - 30).httpdate)
  end
end

class NetworkTest < Minitest::Test
  def closed_port
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close # ninguém escuta nesta porta
    port
  end

  def test_porta_fechada_vira_network_error
    sleeps = []
    bf = Bfocus::Client.new("bf_live_unit", base_url: "http://127.0.0.1:#{closed_port}", timeout: 2,
                                            sleeper: ->(s) { sleeps << s })
    error = assert_raises(Bfocus::NetworkError) { bf.customers.get("C1") }
    assert_kind_of Bfocus::Error, error
    assert_equal [0, "NETWORK_ERROR"], [error.status, error.code]
    assert_match(/\A[0-9a-f]{32}\z/, error.request_id, "request_id = o X-Request-Id enviado")
    assert_equal 2, sleeps.size, "rede é repetida max_retries vezes"
    assert_includes error.message, "NETWORK_ERROR"
    refute_nil error.cause
  end

  def test_timeout_vira_network_error
    # Aceita a conexão (backlog) mas nunca responde.
    silent = TCPServer.new("127.0.0.1", 0)
    begin
      bf = Bfocus::Client.new("bf_live_unit", base_url: "http://127.0.0.1:#{silent.addr[1]}", max_retries: 0)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Bfocus::NetworkError) { bf.customers.get("C1", timeout: 0.3) } # por chamada vence o do cliente
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    ensure
      silent.close
    end
  end
end

class EncodingTest < ServerTestCase
  def test_updated_since_vira_utc_z
    cases = [
      [Time.new(2026, 9, 1, 0, 0, 0, "-03:00"), "2026-09-01T03:00:00Z"],
      [Time.utc(2026, 9, 1, 3, 0, 0, 250_000), "2026-09-01T03:00:00.250000Z"],
      [DateTime.new(2026, 9, 1, 0, 0, 0, "-03:00"), "2026-09-01T03:00:00Z"],
      [Date.new(2026, 9, 1), "2026-09-01T00:00:00Z"],
      ["2026-09-01T00:00:00-03:00", "2026-09-01T00:00:00-03:00"] # string passa como veio
    ]
    empty = { "page" => 1, "page_size" => 50, "total" => 0, "pages" => 0 }
    bf = client([ok([], pagination: empty)] * cases.size)
    cases.each { |value, _| bf.customers.list(updated_since: value) }
    assert_equal cases.map(&:last), requests.map { |r| r[:query].to_h["updated_since"] }
  end

  def test_booleano_e_omitidos_na_query
    bf = client([ok([]), ok([])])
    bf.products.list(include_inactive: false)
    bf.products.list
    assert_equal [[%w[include_inactive false]], []], requests.map { |r| r[:query] }
    assert_nil requests.last[:raw_query], "sem filtros, sem '?'"
  end

  def test_query_codifica_espaco_como_percent_20
    bf = client([ok([], pagination: { "page" => 1, "page_size" => 50, "total" => 0, "pages" => 0 })])
    bf.customers.list(q: "padaria & cia")
    assert_equal "q=padaria%20%26%20cia", requests.first[:raw_query]
  end

  def test_omitido_x_null
    bf = client([ok({}), ok({}), ok({})])
    bf.customers.upsert("C1")
    bf.customers.upsert("C1", phone: nil, name: "Novo")
    bf.customers.upsert("C1", custom_fields: [])
    assert_equal [{}, { "phone" => nil, "name" => "Novo" }, { "custom_fields" => [] }], requests.map { |r| json_body(r) }
    assert_equal "application/json", requests.first[:headers]["content-type"]
  end

  def test_corpo_aninhado_com_simbolos_e_datas
    bf = client([ok({})])
    bf.customers.upsert("C1", custom_fields: [{ key: :plano, value: Time.utc(2026, 9, 1, 12), label: "Plano" }])
    assert_equal({ "custom_fields" => [{ "key" => "plano", "value" => "2026-09-01T12:00:00Z", "label" => "Plano" }] },
                 json_body(requests.first))
  end

  def test_caminho_codificado_por_segmento
    bf = client([ok({})] * 3)
    bf.customers.get("ERP/1042 ç")
    bf.customers.contacts.delete("A B", "c?d")
    bf.release_notes.get("erp", "v2.3.0")
    assert_equal [
      "/api/v1/integration/customers/ERP%2F1042%20%C3%A7",
      "/api/v1/integration/customers/A%20B/contacts/c%3Fd",
      "/api/v1/integration/products/erp/release-notes/v2.3.0"
    ], requests.map { |r| r[:path] }
  end

  def test_base_url_com_prefixo_de_caminho
    server.reset([ok({})])
    bf = Bfocus::Client.new("bf_live_unit", base_url: "#{server.base_url}/proxy/")
    bf.products.get("erp")
    assert_equal "/proxy/api/v1/integration/products/erp", requests.first[:path]
  end

  def test_artigo_recusa_barra_e_ids_vazios
    bf = client([])
    calls = [
      -> { bf.kb.articles.get("docs/guia") },
      -> { bf.kb.articles.upsert("a/b", title: "x") },
      -> { bf.customers.get("") },
      -> { bf.customers.get(".") },
      -> { bf.customers.get(nil) },
      -> { bf.customers.delete("..") },
      -> { bf.customers.contacts.upsert("C1", "") },
      -> { bf.customers.products.attach("C1", "..") },
      -> { bf.release_notes.get("erp", ".") },
      -> { bf.release_notes.list_all("") },
      -> { bf.customers.interactions.list_all("..") },
      -> { bf.kb.articles.publish("..") },
      -> { bf.ai_agents.get(".") }
    ]
    calls.each do |call|
      error = assert_raises(ArgumentError) { call.call }
      refute_kind_of Bfocus::Error, error
    end
    assert_empty requests
  end

  def test_idempotency_key_por_chamada_e_so_em_escrita
    bf = client([ok({}), ok({}), ok({})])
    bf.customers.upsert("C1", name: "x", idempotency_key: "minha-chave")
    bf.customers.get("C1")
    bf.customers.products.attach("C1", "erp")
    h0, h1, h2 = requests.map { |r| r[:headers] }
    assert_equal "minha-chave", h0["idempotency-key"]
    refute h1.key?("idempotency-key")
    refute h1.key?("content-type")
    refute_empty h2["idempotency-key"].to_s # PUT sem corpo continua sendo escrita
    refute h2.key?("content-type")
    assert_equal "", requests[2][:body]
  end

  def test_corpo_utf8
    bf = client([ok({})])
    bf.customers.interactions.create("C1", "Pedido faturado — ação ✓", is_internal: false)
    assert_equal({ "content" => "Pedido faturado — ação ✓", "is_internal" => false }, json_body(requests.first))
  end

  def test_timeout_por_chamada_invalido
    bf = client([])
    assert_raises(ArgumentError) { bf.customers.get("C1", timeout: 0) }
    assert_empty requests
  end
end

class ClientTest < Minitest::Test
  def test_chave_vazia_e_erro_de_argumento
    ["", "   "].each do |bad|
      error = assert_raises(ArgumentError) { Bfocus::Client.new(bad) }
      refute_kind_of Bfocus::Error, error
    end
    assert_raises(TypeError) { Bfocus::Client.new(nil) }
  end

  def test_padroes_e_sem_rede_na_construcao
    bf = Bfocus::Client.new("bf_live_unit")
    assert_equal "https://api.bfocus.com.br", bf.base_url
    assert_equal [30, 2], [bf.timeout, bf.max_retries]
    bf = Bfocus::Client.new("bf_live_unit_secreta", base_url: "http://127.0.0.1:1/", timeout: 5, max_retries: 0)
    assert_equal "http://127.0.0.1:1", bf.base_url
    refute_includes bf.inspect, "bf_live_unit_secreta"
    refute_includes bf.customers.inspect, "bf_live_unit_secreta"
    assert_equal "https://api.bfocus.com.br", Bfocus::Client.new("k", base_url: nil).base_url
  end

  def test_opcoes_invalidas
    assert_raises(ArgumentError) { Bfocus::Client.new("k", max_retries: -1) }
    assert_raises(ArgumentError) { Bfocus::Client.new("k", max_retries: 1.5) }
    assert_raises(ArgumentError) { Bfocus::Client.new("k", timeout: 0) }
    assert_raises(ArgumentError) { Bfocus::Client.new("k", base_url: "ftp://api.bfocus.com.br") }
    assert_raises(ArgumentError) { Bfocus::Client.new("k", base_url: "não é url") }
    assert_raises(ArgumentError) { Bfocus::Client.new("k", sleeper: 5) }
  end

  def test_recursos
    bf = Bfocus::Client.new("k")
    assert_instance_of Bfocus::Resources::CustomerContacts, bf.customers.contacts
    assert_instance_of Bfocus::Resources::CustomerProducts, bf.customers.products
    assert_instance_of Bfocus::Resources::CustomerInteractions, bf.customers.interactions
    assert_instance_of Bfocus::Resources::KBArticles, bf.kb.articles
    assert_respond_to bf.kb, :search
    assert_respond_to bf.release_notes, :list_all
    assert_respond_to bf.ai_agents, :preview
  end

  def test_unset
    assert_equal "Bfocus::UNSET", Bfocus::UNSET.inspect
    assert Bfocus::UNSET.frozen?
    assert_same Bfocus::UNSET, Bfocus::UNSET.dup
    assert_same Bfocus::UNSET, Bfocus::UNSET.clone
    assert_raises(NoMethodError) { Bfocus::Unset.new }
  end
end

class WidgetSignatureTest < Minitest::Test
  def test_formato_e_argumentos
    signature = Bfocus.sign_widget_identity("bf_whs_x", "USR-1", "ACME-1")
    assert_match(/\A[0-9a-f]{64}\z/, signature)
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity("", "u", "c") }
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity(nil, "u", "c") }
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity("s", nil, "c") }
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity("s", "u", nil) }
  end

  def test_utf8_independe_da_codificacao_da_string
    utf8 = Bfocus.sign_widget_identity("bf_whs_9f3kQ2mZ", "usuário-ç", "Cliente & Cia")
    latin1 = Bfocus.sign_widget_identity("bf_whs_9f3kQ2mZ", "usuário-ç".encode("ISO-8859-1"), "Cliente & Cia")
    assert_equal utf8, latin1
  end
end

class UnknownFieldsTest < ServerTestCase
  def test_campos_desconhecidos_sao_preservados
    customer = customer_item(1).merge("campo_novo" => { "x" => [1, 2] })
    envelope = ok(customer)
    envelope["body"]["meta_nova"] = "ignorada" # campo novo no envelope
    listing = ok([customer], pagination: { "page" => 1, "page_size" => 1, "total" => 1, "pages" => 1,
                                           "cursor" => "abc" })
    bf = client([envelope, listing])
    assert_equal customer, bf.customers.get("C1")
    page = bf.customers.list
    assert_equal [customer], page.items
    assert_equal [1, 1, 1, 1], [page.page, page.page_size, page.total, page.pages]
  end

  def test_erro_com_campos_desconhecidos
    response = fail_with(422, "VALIDATION_ERROR")
    response["body"]["validation"] = { "email" => "value is not a valid email address" }
    response["body"]["dica"] = "campo novo"
    bf = client([response])
    error = assert_raises(Bfocus::ValidationError) { bf.customers.upsert("C1", email: "x") }
    assert_equal({ "email" => "value is not a valid email address" }, error.validation)
    assert_equal "campo novo", error.body["dica"]
    assert_equal "req-unit", error.request_id
  end
end

class ErrorShapeTest < ServerTestCase
  def test_mensagem_e_campos
    bf = client([{
                  "status" => 403,
                  "headers" => { "X-Required-Scope" => "kb:write" },
                  "body" => { "code" => 403, "data" => nil, "message" => "INTEGRATION_SCOPE_MISSING",
                              "error" => "INTEGRATION_SCOPE_MISSING", "validation" => {}, "request_id" => "req-9" }
                }])
    error = assert_raises(Bfocus::PermissionDeniedError) { bf.kb.articles.publish("git:x") }
    assert_equal "kb:write", error.required_scope
    assert_includes error.message, "kb:write"
    assert_includes error.message, "req-9"
    assert_nil error.retry_after
    assert_includes error.inspect, "INTEGRATION_SCOPE_MISSING"
  end

  def test_modulo_nao_contratado_e_permission_denied
    bf = client([fail_with(403, "MODULE_NOT_CONTRACTED", { "X-Required-Module" => "atendimento" })])
    error = assert_raises(Bfocus::PermissionDeniedError) { bf.kb.search("nota") }
    assert_equal "MODULE_NOT_CONTRACTED", error.code
    assert_includes error.message, "atendimento"
  end

  def test_2xx_sem_envelope_e_invalid_response
    bodies = [
      { "status" => 200, "headers" => {}, "body" => "<html>proxy</html>" },
      { "status" => 200, "headers" => {}, "body" => nil }, # corpo vazio
      { "status" => 200, "headers" => {}, "body" => { "id" => "sem envelope" } },
      { "status" => 201, "headers" => { "X-Request-Id" => "req-do-header" }, "body" => [1, 2] }
    ]
    bf = client(bodies)
    errors = bodies.map { assert_raises(Bfocus::Error) { bf.products.get("erp") } }
    errors.each do |error|
      assert_instance_of Bfocus::Error, error
      assert_equal "INVALID_RESPONSE", error.code
      assert_includes error.message, "INVALID_RESPONSE"
    end
    assert_equal [200, 200, 200, 201], errors.map(&:status)
    assert_equal requests[0, 3].map { |r| r[:headers]["x-request-id"] }, errors[0, 3].map(&:request_id)
    assert_equal "req-do-header", errors[3].request_id
  end

  def test_request_id_cai_para_o_enviado
    bf = client([{ "status" => 404, "headers" => {}, "body" => "Not Found" },
                 { "status" => 409, "headers" => {}, "body" => { "code" => 409, "error" => "X" } }])
    2.times do
      error = assert_raises(Bfocus::Error) { bf.products.get("erp") }
      assert_equal requests.last[:headers]["x-request-id"], error.request_id
    end
  end

  def test_code_cai_para_message
    bf = client([{ "status" => 404, "headers" => {}, "body" => { "code" => 404, "message" => "TENANT_NOT_FOUND" } }])
    error = assert_raises(Bfocus::NotFoundError) { bf.products.list }
    assert_equal "TENANT_NOT_FOUND", error.code
    assert_equal({}, error.validation)
  end

  def test_classe_por_status
    assert_equal Bfocus::Error, Bfocus::Error.class_for(400)
    assert_equal Bfocus::Error, Bfocus::Error.class_for(418)
    assert_equal Bfocus::ServerError, Bfocus::Error.class_for(502)
    assert_equal Bfocus::ValidationError, Bfocus::Error.class_for(422)
    [Bfocus::AuthenticationError, Bfocus::PermissionDeniedError, Bfocus::NotFoundError, Bfocus::ConflictError,
     Bfocus::ValidationError, Bfocus::RateLimitError, Bfocus::ServerError, Bfocus::NetworkError].each do |klass|
      assert_operator klass, :<, Bfocus::Error
    end
    assert_operator Bfocus::Error, :<, StandardError
  end
end

class PeopleAndBatchTest < ServerTestCase
  def batch_response(size)
    ok({
         "results" => Array.new(size) do |i|
           { "index" => i, "status" => "created", "external_id" => "x#{i}", "merged_into" => nil,
             "error" => nil, "code" => nil }
         end,
         "summary" => { "created" => size, "updated" => 0, "unchanged" => 0, "error" => 0 }
       })
  end

  def test_limite_exportado
    assert_equal 500, Bfocus::BATCH_MAX
  end

  def test_customers_batch_501_erro_sem_requisicao
    bf = client([])
    items = Array.new(501) { |i| { "external_id" => "erp-#{i}", "name" => "C#{i}" } }
    error = assert_raises(ArgumentError) { bf.customers.batch(items) }
    assert_equal "customers.batch aceita até 500 itens por chamada (recebeu 501); divida em lotes de 500.",
                 error.message
    assert_empty requests
  end

  def test_people_batch_501_erro_sem_requisicao
    bf = client([])
    items = Array.new(501) { |i| { "customer_external_id" => "erp-1", "external_id" => "app-#{i}" } }
    error = assert_raises(ArgumentError) { bf.people.batch(items) }
    assert_includes error.message, "people.batch aceita até 500 itens por chamada (recebeu 501)"
    assert_empty requests
  end

  def test_customers_batch_500_uma_requisicao
    items = Array.new(500) { |i| { external_id: "erp-#{i}", name: "C#{i}", phone: Bfocus::UNSET } }
    out = client([batch_response(500)]).customers.batch(items, idempotency_key: "carga-1")
    assert_equal 1, requests.size
    body = json_body(requests.first)
    assert_equal 500, body["items"].size
    assert_equal({ "external_id" => "erp-0", "name" => "C0" }, body["items"].first)
    assert_equal "/api/v1/integration/customers/batch", requests.first[:path]
    assert_equal "carga-1", requests.first[:headers]["idempotency-key"]
    assert_equal 500, out["summary"]["created"]
  end

  def test_people_batch_500_uma_requisicao_no_formato_do_fio
    items = Array.new(500) { |i| { customer_external_id: "erp-1", external_id: "app-#{i}", phone: nil } }
    client([batch_response(500)]).people.batch(items)
    assert_equal 1, requests.size
    body = json_body(requests.first)
    assert_equal 500, body["items"].size
    assert_equal({ "customer_external_id" => "erp-1", "person" => { "external_id" => "app-0", "phone" => nil } },
                 body["items"].first)
    assert_equal "/api/v1/integration/people/batch", requests.first[:path]
  end

  def test_batch_valida_itens_antes_de_enviar
    bf = client([])
    assert_raises(ArgumentError) { bf.customers.batch([{ "name" => "sem id" }]) }
    assert_raises(ArgumentError) { bf.people.batch([{ "external_id" => "app-1" }]) }
    assert_raises(ArgumentError) { bf.people.batch([{ "customer_external_id" => "erp-1" }]) }
    assert_raises(TypeError) { bf.customers.batch({ "external_id" => "erp-1" }) }
    assert_raises(TypeError) { bf.people.batch(["app-1"]) }
    assert_empty requests
  end

  def test_upsert_so_o_que_veio
    person = { "external_id" => "app-1", "access" => true, "status" => "unchanged" }
    client([ok(person)]).people.upsert("erp-1", "app-1")
    assert_equal({ "person" => {} }, json_body(requests.first))
    assert_equal "/api/v1/integration/customers/erp-1/people/app-1", requests.first[:path]
  end

  def test_identifiers_label_nil_explicito_vai_no_corpo
    client([ok({ "external_id" => "app-1", "identifiers" => [] })]).people.identifiers.add("app-1", "crm-1", label: nil)
    assert_equal({ "label" => nil }, json_body(requests.first))
  end

  def test_caminho_invalido
    bf = client([])
    assert_raises(ArgumentError) { bf.people.upsert("erp-1", "") }
    assert_raises(ArgumentError) { bf.customers.identifiers.add("erp-1", "..") }
    assert_empty requests
  end
end

class WidgetSignatureV2Test < Minitest::Test
  def test_formato_e_agora
    before = Time.now.to_i
    signature = Bfocus.sign_widget_identity_v2("bf_whs_x", "app-77", "erp-1042")
    match = /\Av2\.(\d+)\.([0-9a-f]{64})\z/.match(signature)
    refute_nil match, signature
    assert_in_delta before, match[1].to_i, 5
    assert_in_delta Time.now.to_i, match[1].to_i, 5
  end

  def test_instante_fixo
    expected = Bfocus.sign_widget_identity_v2("bf_whs_x", "USR-1", "ACME-1", now: 1_789_000_000)
    assert_equal expected, Bfocus.sign_widget_identity_v2("bf_whs_x", "USR-1", "ACME-1", now: Time.at(1_789_000_000))
    assert expected.start_with?("v2.1789000000.")
  end

  def test_argumentos_invalidos
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity_v2("", "u", "c") }
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity_v2(nil, "u", "c") }
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity_v2("s", nil, "c") }
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity_v2("s", "u", nil) }
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity_v2("s", "app:77", "c") }
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity_v2("s", "u", "c", now: -1) }
    assert_raises(ArgumentError) { Bfocus.sign_widget_identity_v2("s", "u", "c", now: "1789000000") }
  end
end
