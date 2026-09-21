# bfocus

SDK oficial em **Ruby** da API pública do [bFocus](https://bfocus.com.br): clientes, pessoas,
produtos, release notes, base de conhecimento e agentes de IA.

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
- Hashes de entrada (`custom_fields`, itens do `batch_upsert`/`customers.batch`/`people.batch`,
  `history`) aceitam chaves símbolo ou string.

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

### Identificadores extras

Ligue o id de **outro sistema seu** (CRM, loja, app…) ao mesmo cadastro: depois disso o cliente (ou
a pessoa) é encontrado por qualquer um dos ids. É idempotente (ligar de novo não muda nada). Se o id
já pertence a outro cadastro, a API recusa com `Bfocus::ConflictError` e `code == "IDENTIFIER_IN_USE"`.

```ruby
cliente = client.customers.identifiers.add("erp-1042", "crm-88", label: "CRM") # label é opcional
cliente["identifiers"] # => [{"external_id" => "crm-88", "label" => "CRM", "source" => "api"}]
client.customers.identifiers.remove("erp-1042", "crm-88")

client.people.identifiers.add("app-77", "crm-p5")
client.people.identifiers.remove("app-77", "crm-p5")
```

### Ler os identificadores da pessoa (para reconciliar)

`client.people.list(...)` mostra só o identificador **principal** de cada pessoa. Quando dois
cadastros seus eram a mesma pessoa, um dos ids virou **extra** — e some da listagem sem ter sumido
do cadastro. É isso que faz a sua conferência fechar "633 de 636" sem explicar os 3.

`people.identifiers.list` é a fonte de verdade dessa conferência, e é **leitura**: antes dela era
preciso ESCREVER (tentar um `add`) para descobrir o que tinha acontecido. Aceita no caminho o id
principal **ou qualquer um dos extras**.

```ruby
ids = client.people.identifiers.list("crm-p5") # o id extra que "sumiu" da listagem
ids["external_id"]                             # => "app-77" — o principal do cadastro
ids["identifiers"].each { |i| puts "#{i['external_id']} #{i['label']} #{i['source']}" }
```

## Pessoas

As pessoas (usuários do seu sistema) de cada cliente, em `client.people`. O `external_id` da pessoa
é o mesmo `user_external_id` que você assina para o [widget](#identidade-do-widget).

```ruby
pessoa = client.people.upsert(
  "erp-1042", "app-77",
  name: "Paula Reis", email: "paula@padaria.example", role: "Financeiro", is_primary: true,
  extra_emails: ["paula.reis@pessoal.example"]
)
pessoa["status"] # => "created", "updated" ou "unchanged"

client.people.list("erp-1042")            # todas as pessoas do cliente
client.people.delete("erp-1042", "app-77") # retira o acesso; a pessoa continua no histórico
client.people.upsert("erp-1042", "app-77", access: true) # devolve o acesso
```

- **Nunca duplica.** O e-mail (ou o telefone) acha a pessoa que já chegou por e-mail, pelo widget
  ou por outro sistema, e ela é **adotada** (ganha o seu `external_id`).
- A mesma pessoa enviada com **outro cliente** NÃO é transferida: fica **ligada** também a ele
  (`"linked" => true` na resposta). O cadastro é único e a mesma pessoa circula por vários clientes.
- **O acesso é do vínculo.** `delete` (e `access: false`) tira o acesso dela NESTE cliente, não nos
  outros: `"unlinked" => true` na resposta quer dizer que ela segue ativa em algum outro.
- Como no resto da SDK, só o que você passa muda; `nil` limpa (`phone: nil`).
- Campos: `name`, `email`, `phone`, `document` (CPF), `role`, `access` (pode usar o atendimento), `is_primary`
  (contato principal), `extra_emails`, `extra_phones`, `custom_fields`, `clear`.
- Erros comuns (`code`): `CUSTOMER_NOT_FOUND`, `NAME_REQUIRED` (ao criar), `PERSON_EMAIL_TAKEN`,
  `PERSON_PHONE_TAKEN`, `PERSON_CONTACT_OTHER_CUSTOMER`, `PERSON_EMAIL_STAFF`,
  `PERSON_CLEAR_FIELD_INVALID`, `PERSON_CLEAR_NOT_OWN_RECORD`, `PERSON_DOCUMENT_INVALID`,
  `PERSON_DOCUMENT_CONFLICT`.

### Campos personalizados da pessoa

`custom_fields` leva o que só existe no seu sistema (matrícula, centro de custo, filial). É a
**exceção** ao "só o que vier muda": a lista enviada **substitui a lista inteira** — campo que
ficar de fora é **removido**. Mande sempre a lista que o seu sistema tem hoje; omitir o argumento não mexe
em nada, como em qualquer outro campo.

A `visibility` é decidida no bFocus e **preservada entre sincronizações** — por isso ela não vai
no envio, só volta na resposta: o seu ERP não rebaixa nem promove a exposição de um dado sem
querer.

Vale no upsert de pessoa, no lote de pessoas e na listagem de pessoas do cliente.

```ruby
pessoa = client.people.upsert(
  "erp-1042", "app-77",
  custom_fields: [ # a lista INTEIRA do seu sistema
    { key: "matricula", label: "Matrícula", value: "4471" },
    { key: "filial", label: "Filial", value: "Centro" }
  ]
)
pessoa["custom_fields"].each do |campo|
  puts "#{campo['key']} #{campo['value']} #{campo['visibility']}" # visibility vem do bFocus
end
```

### Apagar o e-mail ou o telefone da pessoa

Um contato gravado errado ficava preso para sempre: enquanto a ficha errada segurasse o telefone,
nenhum reenvio o soltava. `clear` apaga.

```ruby
client.people.upsert("erp-1042", "app-77", clear: ["phone"])          # some o telefone
client.people.upsert("erp-1042", "app-77", clear: %w[email phone])    # somem os dois
```

Três regras que parecem contraintuitivas e são de propósito:

- **Apagar é explícito.** `phone: nil`, `clear: []` e não passar o argumento continuam significando
  **"não mexe"** — a SDK não traduz `nil` em `clear`. Fazer o `nil` apagar teria apagado, em
  silêncio e na primeira carga seguinte, o dado de todo sistema que manda `nil` para "não tenho
  esse valor".
- **Campo fora da lista é recusado, não ignorado**: hoje só `"email"` e `"phone"`; qualquer outro
  devolve 422 `PERSON_CLEAR_FIELD_INVALID` (`Bfocus::ValidationError`).
- **Só se limpa a própria ficha.** Se você alcançou a pessoa por um identificador **extra**, a API
  recusa com 409 `PERSON_CLEAR_NOT_OWN_RECORD` (`Bfocus::ConflictError`): apagar o contato de uma
  ficha alcançada por apelido seria apagar dado de outro sistema. Para saber se o id que você tem em
  mãos é o principal ou um extra, use `client.people.identifiers.list(...)`.

Vale no `people.upsert` e no `people.batch` (`"clear" => ["phone"]` no item).

### CPF: a pessoa é única

`document` é o CPF da pessoa. É por ele que dois sistemas que conhecem a mesma pessoa por ids
diferentes chegam ao MESMO cadastro.

```ruby
p = client.people.upsert("erp-1042", "app-91", name: "Paula Reis", document: "529.982.247-25")
p["document"]     # "52998224725"
p["merged_into"]  # "app-77" se o CPF já era de outra ficha; nil se não
```

Regras (valem no upsert e no lote):

- **A pessoa é única.** O mesmo CPF é sempre o mesmo cadastro, em qualquer produto e cliente. Mande
  com ou sem máscara; a resposta traz só os 11 dígitos em `document`.
- **Id desconhecido + CPF que já existe** → a API acha a ficha, o seu id vira identificador extra
  dela e a resposta vem com `merged_into` = o id principal. Guarde esse id do seu lado.
- **Id de uma ficha + CPF de OUTRA** → as duas são mescladas na hora; `merged_into` = a que tinha o CPF.
- **`document: nil` NÃO apaga** o CPF (e `document` não é campo do `clear`). Omitir é o mesmo que "não mexe".
- Erros: 422 `PERSON_DOCUMENT_INVALID` (CPF inválido, `Bfocus::ValidationError`) e 409 `PERSON_DOCUMENT_CONFLICT` (a
  ficha já tem OUTRO CPF — a API nunca troca sozinho; `Bfocus::ConflictError`).

No lote: `"document" => "529.982.247-25"` no item.

### Contato já usado: um 409 que você consegue resolver

`PERSON_EMAIL_TAKEN` e `PERSON_PHONE_TAKEN` (409) não são "tente de novo": o e-mail (ou o
telefone) já é de outra pessoa da conta. O erro diz **de quem**, em `error.data` (a API repete o mesmo
detalhe em `error.validation`, por compatibilidade):

| campo | o que é |
| --- | --- |
| `field` | `email` ou `phone` — qual contato está tomado |
| `owner_external_id` | o identificador da pessoa que já usa esse contato |
| `owner_name` | o nome dela |
| `owner_customer_external_id` | o cliente a que ela pertence |

**É o `owner_customer_external_id` que decide a ação**, e os dois casos pedem coisas opostas:

- **mesmo cliente que você enviou** → é quase sempre a MESMA pessoa em dois sistemas. Uma pessoa
  tem **N identificadores**: registre o seu como **extra** dela. A partir daí o seu id encontra
  essa pessoa.
- **outro cliente** → ninguém decide sozinho a quem a pessoa pertence. Não force: registre o caso
  e leve para quem conhece o cadastro. Unificar dois clientes é decisão de gente, não de um
  casamento por e-mail.

```ruby
begin
  client.people.upsert("erp-1042", "app-77", name: "Paula Reis", email: "paula@padaria.example")
rescue Bfocus::ConflictError => e
  raise unless %w[PERSON_EMAIL_TAKEN PERSON_PHONE_TAKEN].include?(e.code)

  dono = e.data
  if dono["owner_customer_external_id"] == "erp-1042"
    # A mesma pessoa, com dois ids: o seu vira mais um identificador dela.
    client.people.identifiers.add(dono["owner_external_id"], "app-77", label: "ERP")
  else
    # Dono em OUTRO cliente: não decida sozinho — registre e leve para o cadastro.
    avisar_cadastro(e.code, dono)
  end
end
```

`PERSON_CONTACT_OTHER_CUSTOMER` (409) é o mesmo assunto pelo outro lado: o e-mail (ou o telefone) é
de uma pessoa de **outro cliente**. A API **não liga duas fichas sozinha** só porque o contato casou
— dois cadastros podem dividir um e-mail ou um telefone, e ligar por palpite já destruiu fichas.
Repetir a chamada não resolve. Se for **mesmo a mesma pessoa** (confirme antes), o erro traz o dono
nos dados, como os outros dois conflitos: registre o seu id como identificador extra da ficha dele
(`owner_external_id`) e o próximo envio **liga** a pessoa ao seu cliente (`linked: true`), sem
sobrescrever os dados da outra ficha.

## Lotes — `customers.batch` e `people.batch`

Até **500 itens por chamada** (`Bfocus::BATCH_MAX`). Acima disso a SDK lança `ArgumentError` antes
de qualquer requisição — ela não divide sozinha, porque o `index` de cada resultado é a posição no
lote que **você** enviou. Divida assim:

```ruby
clientes = meus_clientes.map do |c|
  { external_id: "erp-#{c.id}", name: c.nome, document: c.cnpj, email: c.email }
end

clientes.each_slice(Bfocus::BATCH_MAX) do |fatia|
  resultado = client.customers.batch(fatia)
  resultado["results"].each do |item|
    next unless item["status"] == "error"

    warn "#{fatia[item['index']][:external_id]}: #{item['error']} (HTTP #{item['code']})"
  end
end
```

- Cada item de `customers.batch` é `external_id` + os campos do `customers.upsert`.
- Cada item de `people.batch` é **plano**: `customer_external_id` + `external_id` (da pessoa) + os
  campos do `people.upsert`.
- Retorno: `results` (um por item: `index`, `status` — `created`/`updated`/`unchanged`/`error` —,
  `external_id`, `merged_into`, `error` com o código estável e `code` com o status HTTP do item) +
  `summary` (`created`, `updated`, `unchanged`, `error`).
- **Um erro não desfaz os outros**: confira `summary["error"]` e registre os itens com erro.
- Lista vazia devolve o resultado zerado sem fazer requisição.
- `idempotency_key:` vale para o lote inteiro (um lote = uma chamada).

## Sincronizar clientes e usuários do seu sistema

**Ids com o prefixo do sistema, sem `:`.** Use `-` como separador — `erp-1042` para clientes,
`app-77` para pessoas — ou UUIDs puros: vários sistemas seus convivem no mesmo bFocus sem colisão. A
assinatura do widget recusa `:` (é o separador dela), então não use `:` em nenhum `external_id` de
cliente ou pessoa.

**Carga inicial (no deploy):** clientes em fatias de 500 → vincule cada um ao produto → pessoas em
fatias de 500.

```ruby
def carga_inicial(client, clientes, usuarios)
  clientes.each_slice(Bfocus::BATCH_MAX) do |fatia|
    r = client.customers.batch(fatia.map { |c| { external_id: "erp-#{c.id}", name: c.nome } })
    registrar_erros(r, fatia) if r["summary"]["error"].positive?
  end

  clientes.each { |c| client.customers.products.attach("erp-#{c.id}", "erp-cloud") }

  usuarios.each_slice(Bfocus::BATCH_MAX) do |fatia|
    itens = fatia.map do |u|
      { customer_external_id: "erp-#{u.cliente_id}", external_id: "app-#{u.id}",
        name: u.nome, email: u.email }
    end
    r = client.people.batch(itens)
    registrar_erros(r, fatia) if r["summary"]["error"].positive?
  end
end
```

**Depois, no dia a dia**, espelhe cada evento do seu sistema:

| No seu sistema | No bFocus |
| --- | --- |
| criou/alterou cliente | `customers.upsert` |
| criou/alterou usuário | `people.upsert` |
| excluiu/desativou usuário | `people.delete` |
| excluiu cliente | `customers.delete` |

Vincule o cliente ao produto com `customers.products.attach`. Se a resposta trouxer `merged_into`,
o cadastro foi unificado em outro: atualize o id do seu lado.

**Nunca bloqueie a requisição do seu usuário esperando o bFocus.** Enfileire (job/outbox) e tente de
novo com backoff; a SDK já repete 429/5xx com a mesma `Idempotency-Key`, e a fila cobre
indisponibilidades longas.

```ruby
# app/jobs/bfocus_sync_usuario_job.rb (ActiveJob; o mesmo vale para Sidekiq etc.)
class BfocusSyncUsuarioJob < ApplicationJob
  retry_on Bfocus::NetworkError, Bfocus::RateLimitError, Bfocus::ServerError,
           wait: :polynomially_longer, attempts: 10

  def perform(usuario_id)
    u = Usuario.find(usuario_id)
    if u.ativo?
      BFOCUS.people.upsert("erp-#{u.cliente_id}", "app-#{u.id}", name: u.nome, email: u.email)
    else
      BFOCUS.people.delete("erp-#{u.cliente_id}", "app-#{u.id}")
    end
  end
end

# no model, depois de salvar — a requisição do usuário não espera o bFocus:
after_commit { BfocusSyncUsuarioJob.perform_later(id) }
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
| Pessoa (`people.list`, `delete`) | `external_id` (pode ser `nil`), `name`, `email`, `phone`, `role`, `access`, `is_primary`, `customer_external_id`, `custom_fields` (lista de `{key, label, value, visibility}`) |
| Pessoa gravada (`people.upsert`) | a pessoa + `status` (`created`/`updated`/`unchanged`) |
| Cliente com identificadores (`customers.identifiers.add`, `remove`) | o cliente + `identifiers` (lista de `{external_id, label, source}`) |
| Identificadores da pessoa (`people.identifiers.list`, `add`, `remove`) | `external_id`, `identifiers` (lista de `{external_id, label, source}`) |
| Lote (`customers.batch`, `people.batch`) | `results` (lista de `{index, status, external_id, merged_into, error, code}`; `status` ∈ `created`/`updated`/`unchanged`/`error`), `summary` (`{created, updated, unchanged, error}`) |
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

Todas têm `code`, `status`, `request_id`, `validation`, `data`, `retry_after`, `required_scope` e
`body`. O `data` é o `data` do corpo: o detalhe estruturado que alguns erros trazem (`{}` quando
não há) — é por ele que um 409 de contato tomado diz de **quem** é o contato (veja
[Pessoas](#pessoas)).
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

### Identidade do widget v2 (com validade)

A v2 carimba o instante na assinatura, então uma assinatura vazada deixa de valer sozinha:

```ruby
user_hash = Bfocus.sign_widget_identity_v2(
  ENV.fetch("BFOCUS_WIDGET_SECRET"),
  "app-77",   # user_external_id: sem ":" (é o separador; a API recusa)
  "erp-1042"  # customer_external_id: a empresa dele
)
# => "v2.<ts>.<hex>", ex.: "v2.1789000000.9c1e…"

# instante explícito (segundos unix, não ms; ou Time) — útil em testes:
Bfocus.sign_widget_identity_v2(segredo, "app-77", "erp-1042", now: 1_789_000_000)
```

- `hex` = HMAC-SHA256 em hex minúsculo de `"v2:<ts>:<user_external_id>:<customer_external_id>"`.
- Vale de **7 dias atrás até 5 minutos à frente**: gere a cada renderização da página, **nunca
  guarde**. Vai no mesmo lugar da v1 (`userHash` do widget).
- O id do usuário não pode ter `:` (`ArgumentError`) — use `-` como separador (`app-77`).
- A v1 continua aceita.

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
