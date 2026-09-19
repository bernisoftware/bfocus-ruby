# bfocus

SDK oficial em **Ruby** da API pública do [bFocus](https://bfocus.com.br): clientes, produtos,
release notes, base de conhecimento e agentes de IA.

Zero dependências de runtime (só biblioteca padrão: `net/http`, `json`, `openssl`,
`securerandom`) · Ruby 3.0+ · novas tentativas e idempotência automáticas.

## Instalação

```bash
gem install bfocus -v 0.1.0
```

Ou no `Gemfile`:

```ruby
gem "bfocus", "0.1.0"
```

## Hello world

```ruby
require "bfocus"

client = Bfocus::Client.new("bf_live_...")

cliente = client.customers.upsert("ERP 1042", name: "Padaria Estrela", email: "contato@padaria.example")
puts cliente["id"], cliente["name"]
```

`upsert` cria ou atualiza pelo `external_id` do **seu** sistema — rodar de novo não duplica.

## Autenticação

Crie a chave no bFocus em **Integrações → Chaves de API**, marcando só os escopos de que a
integração precisa. Ela vai em `Authorization: Bearer <chave>` em toda requisição (a SDK cuida disso).

| Escopo | Permite |
| --- | --- |
| `customers:read` | Ler clientes, contatos, produtos vinculados e interações |
| `customers:write` | Cadastrar, atualizar e excluir clientes, contatos e interações |
| `products:read` | Ler o catálogo de produtos |
| `products:write` | Cadastrar, atualizar e arquivar produtos |
| `kb:read` | Ler e buscar artigos da base de conhecimento |
| `kb:write` | Criar, atualizar, publicar e excluir artigos da base de conhecimento |
| `ai_agents:read` | Ler os agentes de IA |
| `ai_agents:preview` | Testar a resposta de um agente de IA (consome IA da conta) |
| `release_notes:read` | Ler release notes |
| `release_notes:write` | Criar, atualizar e publicar release notes |

A chave legada (`bf_sk_…`) só alcança clientes (`customers:*`). A base de conhecimento e os
agentes de IA exigem o **módulo de Atendimento** contratado (sem ele a API responde
`MODULE_NOT_CONTRACTED` — veja [Erros](#erros)). Guarde a chave fora do código:

```ruby
require "bfocus"

client = Bfocus::Client.new(
  ENV.fetch("BFOCUS_API_KEY"),
  base_url: "https://api.bfocus.com.br", # padrão; em dev: "http://localhost:8000"
  timeout: 30,                           # segundos, por tentativa
  max_retries: 2                         # novas tentativas além da primeira (0 desliga)
)
```

Construir o cliente não faz nenhuma chamada de rede. O cliente não guarda estado entre chamadas
(cada tentativa abre a própria conexão), então pode ser compartilhado entre threads.

## Como os métodos funcionam

- **Retorno desembrulhado**: o método devolve o `data` da resposta como `Hash` (ou `Array` de
  `Hash`) com **chaves string**, exatamente como a API devolve — `cliente["name"]`. Campos novos
  que a API passar a devolver aparecem no Hash; nunca viram erro. Datas chegam como string ISO 8601
  (use `Time.iso8601(...)` se precisar). Os campos de cada retorno estão em
  [Formato dos retornos](#formato-dos-retornos).
- **Listas paginadas** (`customers.list`, `interactions.list`, `release_notes.list`,
  `kb.articles.list`) devolvem `Bfocus::Page` (`items`, `page`, `page_size`, `total`, `pages`,
  `next_page?`), que é `Enumerable`. Para percorrer tudo, use `list_all(...)`: um
  `Enumerator::Lazy` que busca página por página só quando você consome (`page_size` padrão 100) e
  para na última página ou numa página vazia.
- **Só o que você passa muda.** Os upserts são parciais: argumento não informado não é enviado;
  `nil` explícito vai como `null` e **limpa** o campo.

  ```ruby
  client.customers.upsert("ERP 1042", phone: "11 3333-4444") # só o telefone muda
  client.customers.upsert("ERP 1042", phone: nil)            # apaga o telefone
  ```

  (Por baixo, o padrão dos keyword args opcionais é a sentinela `Bfocus::UNSET` — você nunca
  precisa usá-la.)
- Obrigatórios são posicionais; opcionais são keyword args. Toda chamada aceita `timeout:`; as de
  escrita aceitam `idempotency_key:` (veja [Novas tentativas](#novas-tentativas-e-idempotência)).
- Datas (`updated_since`) aceitam `Time`/`DateTime` — convertidos para ISO 8601 em UTC com `Z` —,
  `Date` (meia-noite UTC) ou string, que passa como veio.
- Hashes de entrada (`custom_fields`, itens do `batch_upsert`, `history`) aceitam chaves símbolo
  ou string.

## Clientes

```ruby
client.customers.upsert(
  "ERP 1042",
  name: "Padaria Estrela",
  document: "12.345.678/0001-90",
  custom_fields: [{ key: "plano", label: "Plano", value: "ouro" }] # substitui a lista
)

cliente = client.customers.get("ERP 1042")

pagina = client.customers.list(q: "padaria", page: 1, page_size: 50)
puts pagina.total, pagina.map { |c| c["name"] }.inspect

# Sincronização incremental: tudo o que mudou desde a última rodada, todas as páginas.
desde = Time.now - 3600
client.customers.list_all(updated_since: desde).each do |c|
  puts "#{c['external_id']} #{c['updated_at']}"
end

client.customers.delete("ERP 1042")
```

### Contatos, produtos vinculados e interações

```ruby
client.customers.contacts.upsert("ERP 1042", "CT-1", name: "Ana Souza", role: "Financeiro",
                                                     email: "ana@padaria.example", is_primary: true)
client.customers.contacts.list("ERP 1042")
client.customers.contacts.delete("ERP 1042", "CT-1")

client.customers.products.attach("ERP 1042", "erp-cloud")
client.customers.products.list("ERP 1042")
client.customers.products.detach("ERP 1042", "erp-cloud")

client.customers.interactions.create("ERP 1042", "Pedido 1042 faturado.",
                                     author_email: "carla@suaempresa.com.br")
client.customers.interactions.list_all("ERP 1042").each do |i|
  puts "#{i['created_at']} #{i['content']}"
end
```

## Produtos

```ruby
client.products.upsert("erp-cloud", name: "ERP Cloud", description: "Gestão na nuvem", color: "#6366F1")
client.products.get("erp-cloud")
client.products.list(include_inactive: true)
client.products.archive("erp-cloud") # arquiva, não apaga
```

## Release notes — publicar direto do CI

Um passo no pipeline de release: cria ou atualiza a nota da versão e já publica.

```ruby
# script/publicar_release_note.rb — roda no CI a cada tag
require "bfocus"

client = Bfocus::Client.new(ENV.fetch("BFOCUS_API_KEY")) # escopo release_notes:write
versao = ENV.fetch("GITHUB_REF_NAME")                     # "v2.3.0" — o "v" na frente é aceito

client.release_notes.upsert(
  "erp-cloud",
  versao,
  title: "Versão #{versao.delete_prefix('v')}",
  description_markdown: File.read("release-notes/#{versao}.md", encoding: "UTF-8"),
  audience: "external", # "internal" | "external" | "both"
  publish: true         # cria/atualiza e publica numa chamada só
)
```

Rodar de novo para a mesma versão atualiza a nota (é upsert). Também há:

```ruby
client.release_notes.get("erp-cloud", "2.3.0")
client.release_notes.list("erp-cloud", published: false) # rascunhos (Page)
client.release_notes.list_all("erp-cloud").to_a
client.release_notes.publish("erp-cloud", "2.3.0")
```

## Base de conhecimento — sincronizar a partir de arquivos Markdown

Mantenha a documentação no repositório e sincronize a cada push. `batch_upsert` aceita **qualquer
quantidade** de artigos: a SDK divide em lotes de 100 (o limite da API), envia em sequência e
devolve um único resultado.

```ruby
require "bfocus"

client = Bfocus::Client.new(ENV.fetch("BFOCUS_API_KEY")) # escopos kb:read e kb:write
docs = "docs"

artigos = Dir.glob("#{docs}/**/*.md").sort.map do |arquivo|
  texto = File.read(arquivo, encoding: "UTF-8")
  titulo = texto.lines.find { |l| l.start_with?("# ") }&.delete_prefix("# ")&.strip || File.basename(arquivo, ".md")
  relativo = arquivo.delete_prefix("#{docs}/").delete_suffix(".md")
  {
    # id estável e SEM "/": o caminho do arquivo com ":" no lugar das barras.
    # Aceita letras, números e . _ : ~ @ + = -
    external_id: "git:#{relativo.tr('/', ':')}",
    title: titulo,
    body_markdown: texto,
    product: "erp-cloud" # ou nil (explícito) para um artigo global
  }
end

res = client.kb.articles.batch_upsert(artigos)
puts "#{res['created']} criados, #{res['updated']} atualizados, " \
     "#{res['unchanged']} sem mudança, #{res['failed']} com falha"

res["results"].each do |r| # na mesma ordem enviada
  if !r["ok"]
    puts "falhou: #{r['external_id']} #{r['error']}" # ex.: KB_ARTICLE_TITLE_REQUIRED
  elsif %w[created updated].include?(r["action"])
    client.kb.articles.publish(r["external_id"])     # publica o que entrou ou mudou
  end
end

# Remove do bFocus o que saiu do repositório.
locais = artigos.map { |a| a[:external_id] }
client.kb.articles.list_all(product: "erp-cloud").each do |artigo|
  ext = artigo["external_id"].to_s
  client.kb.articles.delete(ext) if ext.start_with?("git:") && !locais.include?(ext)
end
```

Um item com problema não derruba os outros: ele volta com `"ok" => false` e o motivo em
`"error"`. Para publicar já no lote, mande `status: "published"` em cada item. Lista vazia devolve
o resultado zerado sem chamar a API. Artigo a artigo:

```ruby
client.kb.articles.upsert("notion:emitir-nfse", title: "Como emitir NFS-e",
                                                body_markdown: "# Passo a passo\n\n1. Abra o menu **Fiscal**",
                                                product: nil, status: "published")
client.kb.articles.get("notion:emitir-nfse")      # artigo completo, com body_html
client.kb.articles.list(status: "draft", q: "nota") # Page de resumos (sem body_html)
client.kb.articles.unpublish("notion:emitir-nfse")
client.kb.articles.delete("notion:emitir-nfse")
```

### Busca

```ruby
client.kb.search("como emitir nota fiscal", product: "erp-cloud", limit: 3).each do |hit|
  puts "#{hit['title']} — #{hit['excerpt']}"
end
```

## Agentes de IA

```ruby
agentes = client.ai_agents.list
agente = client.ai_agents.get(agentes.first["id"])

resposta = client.ai_agents.preview(
  agente["id"],
  "Como emito uma NFS-e?",
  history: [{ role: "customer", content: "Oi" },
            { role: "bot", content: "Olá! Como posso ajudar?" }]
)
puts resposta["action"], resposta["answer_html"], resposta["sources"].inspect
```

`preview` consome IA da conta (escopo `ai_agents:preview`).

## Formato dos retornos

Todos são `Hash` com chaves string (campos novos podem aparecer a qualquer momento).

| Retorno (métodos) | Campos |
| --- | --- |
| Cliente (`customers.upsert`, `get`, `list`, `list_all`) | `id`, `external_id`, `name`, `document`, `email`, `phone`, `website`, `notes`, `custom_fields` (lista de `{key, label, type, value, visibility}`), `is_active`, `created_at`, `updated_at` |
| Contato (`customers.contacts.*`) | `id`, `external_id`, `name`, `role`, `email`, `phone`, `notes`, `is_primary`, `created_at`, `updated_at` |
| Produto vinculado (`customers.products.*`) | `id`, `slug`, `name`, `is_active` |
| Interação (`customers.interactions.*`) | `id`, `content`, `is_internal`, `author_kind`, `author_name`, `created_at` |
| Produto (`products.*`) | `id`, `slug`, `name`, `description`, `color`, `icon`, `is_active`, `sort_order`, `current_version`, `ai_level`, `created_at`, `updated_at` |
| Release note (`release_notes.*`) | `id`, `product`, `version`, `title`, `description_html`, `audience`, `is_published`, `require_ack_internal`, `require_ack_external`, `published_at`, `created_at`, `updated_at` |
| Artigo — resumo (`kb.articles.list`, `list_all`) | `id`, `external_id`, `product`, `title`, `excerpt`, `status`, `origin`, `published_at`, `created_at`, `updated_at` |
| Artigo completo (`kb.articles.get`, `upsert`, `publish`, `unpublish`) | o resumo + `body_html` |
| Lote (`kb.articles.batch_upsert`) | `results` (lista de `{external_id, ok, action, error, article}`; `action` ∈ `created`/`updated`/`unchanged`), `created`, `updated`, `unchanged`, `failed` |
| Resultado de busca (`kb.search`) | `id`, `external_id`, `title`, `excerpt` |
| Agente de IA (`ai_agents.list`, `get`) | `id`, `name`, `product` (`{id, slug, name, is_active}`), `active`, `persona`, `scope`, `avatar_url`, `created_at`, `updated_at` |
| Preview (`ai_agents.preview`) | `action` (`answer`/`handoff`/`refuse`), `answer_html`, `escalated`, `refused`, `handoff_reason`, `confidence`, `topic`, `guards`, `citations`, `sources`, `collected`, `missing` |
| Exclusão (`delete`, `detach`) | `deleted` |

## Erros

Qualquer resposta fora de 2xx levanta `Bfocus::Error` (ou uma subclasse):

| Classe | Quando |
| --- | --- |
| `Bfocus::AuthenticationError` | 401 — chave ausente, inválida ou revogada |
| `Bfocus::PermissionDeniedError` | 403 — chave desligada, IP não liberado, escopo faltando (`required_scope`) ou módulo não contratado (`MODULE_NOT_CONTRACTED`) |
| `Bfocus::NotFoundError` | 404 |
| `Bfocus::ConflictError` | 409 — ex.: `KB_ARTICLE_EMPTY`, `AI_DISABLED` |
| `Bfocus::ValidationError` | 422 — motivos por campo em `validation` |
| `Bfocus::RateLimitError` | 429 — `retry_after` em segundos (depois de esgotar as novas tentativas) |
| `Bfocus::ServerError` | 5xx |
| `Bfocus::NetworkError` | conexão/timeout — `status == 0`, `code == "NETWORK_ERROR"` |

Todas têm `code`, `status`, `request_id`, `validation`, `retry_after`, `required_scope` e `body`.
**Decida pelo `code`** — ele é estável (`CUSTOMER_NOT_FOUND`, `INTEGRATION_SCOPE_MISSING`,
`MODULE_NOT_CONTRACTED`, `VALIDATION_ERROR`…). O `message` é texto para humanos e pode mudar. Ao
falar com o suporte, informe o `request_id`: ele vem do corpo da resposta, senão do header
`X-Request-Id`, senão é o id que a própria SDK enviou (a API ecoa o do cliente) — então está
sempre preenchido, inclusive em `NetworkError`.

Se uma resposta 2xx chegar sem o envelope JSON da API (um proxy devolvendo HTML, corpo vazio), a
SDK não devolve `nil` calado: levanta `Bfocus::Error` com `code == "INVALID_RESPONSE"` e o status
recebido. Corpo de erro que não é JSON vira `code == "HTTP_<status>"`.

```ruby
begin
  client.customers.get("ERP 9999")
rescue Bfocus::NotFoundError
  puts "não existe"
rescue Bfocus::Error => e
  case e.code
  when "INTEGRATION_SCOPE_MISSING" then puts "a chave não tem o escopo #{e.required_scope}"
  when "MODULE_NOT_CONTRACTED" then puts "contrate o módulo de Atendimento"
  when "VALIDATION_ERROR" then p e.validation # {"email" => "value is not a valid email address"}
  else puts "#{e.code} #{e.status} #{e.request_id}"
  end
end
```

Argumento inválido no seu código (chave vazia; parâmetro de caminho vazio, `"."` ou `".."`; `/`
no `external_id` de um artigo; item do lote sem `external_id`) levanta `ArgumentError`/`TypeError`
na hora, sem chamar a API — não é `Bfocus::Error`.

## Novas tentativas e idempotência

A SDK tenta de novo sozinha em **erro de rede/timeout, 429, 502, 503 e 504** — até `max_retries`
vezes (padrão 2). Espera o `Retry-After` quando a API manda (segundos ou data HTTP; teto de 60 s);
senão 0,5 s, 1 s, 2 s… (teto de 8 s) + até 25% de variação aleatória. Um 500 ou outro 4xx volta na
hora.

Toda escrita (POST/PUT/DELETE) leva um `Idempotency-Key`, e **a mesma chave vai em todas as
tentativas** da chamada: se a primeira chegou a executar e só a resposta se perdeu, a API devolve a
resposta original (`Idempotent-Replayed: true`) em vez de executar de novo. O `X-Request-Id` também
se repete, para o suporte ver as tentativas como uma chamada só.

Para que a proteção valha também quando o **seu** processo roda de novo (um job reexecutado), passe
uma chave derivada do evento:

```ruby
client.customers.interactions.create(
  "ERP 1042", "Pedido 1042 faturado.",
  idempotency_key: "pedido-1042-faturado"
)
```

A mesma chave com outra requisição volta `IDEMPOTENCY_KEY_REUSED`. No `batch_upsert`, o 1º lote
usa a sua chave como veio e os seguintes `"<chave>:2"`, `"<chave>:3"`… (sem chave, cada lote gera
a sua).

Nos seus testes, troque a espera entre tentativas para não dormir:
`Bfocus::Client.new(chave, sleeper: ->(segundos) {})`.

## Identidade do widget

Para o widget de atendimento reconhecer o usuário logado, o **seu backend** assina a identidade
dele com o segredo do widget (que nunca vai para o navegador). É local — sem rede e sem chave de API:

```ruby
require "bfocus"

assinatura = Bfocus.sign_widget_identity(
  ENV.fetch("BFOCUS_WIDGET_SECRET"),
  "USR-1",    # user_external_id: o usuário no seu sistema
  "ERP 1042"  # customer_external_id: a empresa (cliente) dele
)
# HMAC-SHA256 em hex minúsculo de "v1:USR-1:ERP 1042" — entregue junto dos dois ids à página
# que abre o widget.
```

## Versões

**Fixe a versão exata** (`gem "bfocus", "0.1.0"` no `Gemfile`) e suba de uma versão para a outra
de propósito. Cada release declara se muda a superfície pública (`additive` ou `breaking: …`),
então dá para saber o que revisar antes de subir.

A SDK se identifica em toda requisição (`X-Bfocus-Client: bfocus-ruby/<versão>`, também em
`Bfocus::CLIENT_ID`): quando uma correção exigir atualizar, o bFocus avisa as contas que rodam a
versão afetada.

## Exemplo

Um script rodável está em [`examples/quickstart.rb`](examples/quickstart.rb):

```bash
BFOCUS_API_KEY=bf_live_... ruby examples/quickstart.rb
```

## Desenvolvimento

```bash
bundle install
bundle exec rake test   # conformidade + unitários (servidor HTTP local, sem rede externa)
gem build bfocus.gemspec
```

## Licença

MIT © Berni Software
