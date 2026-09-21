# frozen_string_literal: true

module Bfocus
  module Resources
    # Identificadores extras de uma pessoa — `client.people.identifiers`: liga o id de OUTRO
    # sistema seu ao mesmo cadastro.
    #
    # Retorno: `{"external_id", "identifiers" => [{"external_id", "label", "source"}, …]}`.
    # Id que já pertence a outro cadastro: `ConflictError` com `code == "IDENTIFIER_IN_USE"`.
    class PersonIdentifiers < Base
      # Todos os identificadores da pessoa: o principal (`"external_id"` do retorno) e os extras.
      # `GET /people/{person_external_id}/identifiers` (escopo `customers:read`). Aceita no
      # caminho o principal OU qualquer um dos extras.
      #
      # É a fonte de verdade para RECONCILIAR: {People#list} mostra só o identificador principal,
      # então um id que virou extra some de lá sem ter sumido do cadastro — e, sem esta leitura,
      # era preciso ESCREVER (tentar um {#add}) para descobrir o que tinha acontecido.
      #
      # @return [Hash]
      # @raise [Bfocus::NotFoundError] `PERSON_NOT_FOUND`.
      def list(person_external_id, timeout: nil)
        call("GET", "/people/#{segment(person_external_id, 'person_external_id')}/identifiers",
             timeout: timeout)
      end

      # Liga `extra_id` à pessoa (idempotente). `PUT /people/{person_external_id}/identifiers/{extra_id}`
      #
      # @param label [String, nil] rótulo livre. Não informado = sem corpo.
      # @return [Hash]
      def add(person_external_id, extra_id, label: UNSET, idempotency_key: nil, timeout: nil)
        pid = segment(person_external_id, "person_external_id")
        extra = segment(extra_id, "extra_id")
        body = label.equal?(UNSET) ? nil : { "label" => label }
        call("PUT", "/people/#{pid}/identifiers/#{extra}",
             body: body, idempotency_key: idempotency_key, timeout: timeout)
      end

      # Desliga `extra_id` da pessoa. `DELETE /people/{person_external_id}/identifiers/{extra_id}`
      # @return [Hash]
      def remove(person_external_id, extra_id, idempotency_key: nil, timeout: nil)
        pid = segment(person_external_id, "person_external_id")
        extra = segment(extra_id, "extra_id")
        call("DELETE", "/people/#{pid}/identifiers/#{extra}",
             idempotency_key: idempotency_key, timeout: timeout)
      end
    end

    # Pessoas (usuários do seu sistema) de um cliente — `client.people`. Sub-recurso:
    # {#identifiers}.
    #
    # Pessoa: `"external_id"` (pode ser `nil` para quem chegou por e-mail/widget sem id),
    # `"name"`, `"email"`, `"phone"`, `"role"`, `"access"`, `"is_primary"`,
    # `"customer_external_id"` e `"custom_fields"` (lista de `{"key", "label", "value",
    # "visibility"}`). O `upsert` devolve também `"status"`
    # (`"created"`/`"updated"`/`"unchanged"`).
    #
    # O `external_id` da pessoa é o mesmo `user_external_id` assinado no widget — por isso não
    # pode ter `:` (use outro separador, ex.: `"app-77"`).
    class People < Base
      # @return [PersonIdentifiers]
      attr_reader :identifiers

      def initialize(transport)
        super
        @identifiers = PersonIdentifiers.new(transport)
      end

      # Cria ou atualiza uma pessoa do cliente pelo `external_id` dela.
      # `PUT /customers/{customer_external_id}/people/{person_external_id}`
      #
      # Só o que vier muda; `nil` limpa. O e-mail (ou telefone) acha a pessoa que já chegou por
      # outro caminho e ela é adotada, nunca duplicada. Se ela já existia em OUTRO cliente, NÃO é
      # transferida: fica ligada também a este (cadastro único, `"linked" => true` na resposta).
      # `access: true` devolve o acesso retirado por {#delete}.
      #
      # @param document [String] CPF da pessoa, com ou sem máscara (a resposta traz só os 11
      #   dígitos). A PESSOA É ÚNICA: o mesmo CPF é sempre o mesmo cadastro, em qualquer produto.
      #   Id desconhecido + CPF de uma ficha existente → `"merged_into"` = id principal dela (o
      #   seu id vira identificador extra). Id de uma ficha + CPF de OUTRA → as duas são mescladas
      #   na hora (`"merged_into"` = a que tinha o CPF). `nil`/vazio NÃO apaga (não é campo do
      #   `clear`). Erros: 422 `PERSON_DOCUMENT_INVALID` (CPF inválido) e 409
      #   `PERSON_DOCUMENT_CONFLICT` (a ficha já tem OUTRO CPF — nunca troca sozinho).
      # @param access [Boolean] pode abrir chamados/usar o widget.
      # @param is_primary [Boolean] contato principal do cliente.
      # @param extra_emails [Array<String>] e-mails adicionais.
      # @param extra_phones [Array<String>] telefones adicionais.
      # @param custom_fields [Array<Hash>] campos personalizados (`{"key", "label", "value"}`).
      #   Ao contrário de `extra_emails`/`extra_phones`, a lista SUBSTITUI a lista inteira: mande
      #   o que o seu sistema tem hoje, porque campo que ficar de fora é REMOVIDO. Não passar o
      #   argumento não mexe em nada. A visibilidade é decidida no bFocus e preservada entre
      #   sincronizações.
      # @param clear [Array<String>] campos a APAGAR nesta pessoa: `["email"]`, `["phone"]` ou os
      #   dois. Apagar é EXPLÍCITO: `phone: nil`, `clear: []` e não passar o argumento continuam
      #   significando "não mexe" — a SDK não traduz `nil` em `clear`. Campo fora da lista aceita
      #   é RECUSADO pela API (422 `PERSON_CLEAR_FIELD_INVALID`), não ignorado; e só se limpa a
      #   PRÓPRIA ficha: alcançando a pessoa por um identificador EXTRA, a API recusa (409
      #   `PERSON_CLEAR_NOT_OWN_RECORD`) — apagar contato de ficha alcançada por apelido seria
      #   apagar dado de outro sistema.
      # @return [Hash] a pessoa + `"status"`, `"linked"` (já existia em outro cliente e agora está
      #   ligada a este também) e `"merged_into"` (o id que você mandou era um apelido; este é o
      #   principal do cadastro).
      def upsert(customer_external_id, person_external_id, name: UNSET, email: UNSET, phone: UNSET,
                 document: UNSET, role: UNSET, access: UNSET, is_primary: UNSET, extra_emails: UNSET, extra_phones: UNSET,
                 custom_fields: UNSET, clear: UNSET, idempotency_key: nil, timeout: nil)
        cid = segment(customer_external_id, "customer_external_id")
        pid = segment(person_external_id, "person_external_id")
        person = compact(
          "name" => name, "email" => email, "phone" => phone, "document" => document, "role" => role,
          "access" => access,
          "is_primary" => is_primary, "extra_emails" => extra_emails, "extra_phones" => extra_phones,
          "custom_fields" => custom_fields, "clear" => clear
        )
        call("PUT", "/customers/#{cid}/people/#{pid}",
             body: { "person" => person }, idempotency_key: idempotency_key, timeout: timeout)
      end

      # Pessoas do cliente. `GET /customers/{customer_external_id}/people`
      # @return [Array<Hash>]
      def list(customer_external_id, timeout: nil)
        call("GET", "/customers/#{segment(customer_external_id, 'customer_external_id')}/people",
             timeout: timeout)
      end

      # Retira o acesso da pessoa NESTE cliente (ela continua no histórico).
      # `DELETE /customers/{customer_external_id}/people/{person_external_id}`
      #
      # O acesso é DO VÍNCULO: a mesma pessoa circula por vários clientes e tirar o acesso aqui
      # não tira o dela nos outros.
      # @return [Hash] a pessoa, com `"access" => false` e `"unlinked"` (`true` = ela segue ativa
      #   em outros clientes; `false` = era só deste e foi desligada).
      def delete(customer_external_id, person_external_id, idempotency_key: nil, timeout: nil)
        cid = segment(customer_external_id, "customer_external_id")
        pid = segment(person_external_id, "person_external_id")
        call("DELETE", "/customers/#{cid}/people/#{pid}",
             idempotency_key: idempotency_key, timeout: timeout)
      end

      # Cria/atualiza até {Bfocus::BATCH_MAX} (500) pessoas numa chamada. `POST /people/batch`
      #
      # Cada item (Hash plano, chaves string ou símbolo): `customer_external_id` e `external_id`
      # (da pessoa), ambos obrigatórios, + os campos do {#upsert} (ausente = não muda; `nil`
      # limpa). No fio vira `{"customer_external_id" => …, "person" => {"external_id" => …, …}}`.
      #
      # A SDK **não divide** o lote: mais de 500 itens lança `ArgumentError` antes de qualquer
      # requisição (use `items.each_slice(Bfocus::BATCH_MAX)`); o `"index"` de cada resultado é
      # a posição no lote enviado. Um item com erro não desfaz os outros. Lista vazia devolve o
      # resultado zerado sem chamar a API.
      #
      # @return [Hash] `{"results" => [{"index", "status", "external_id", "merged_into", "error",
      #   "code"}, …], "summary" => {"created", "updated", "unchanged", "error"}}`
      # @raise [ArgumentError] mais de 500 itens ou item sem `customer_external_id`/`external_id`.
      # @raise [TypeError] `items` não é lista de Hash.
      def batch(items, idempotency_key: nil, timeout: nil)
        list = batch_items(items, "people.batch")
        return empty_batch_result if list.empty?

        wire = list.each_with_index.map do |item, index|
          customer = batch_id!(item, "customer_external_id", "people.batch", index)
          batch_id!(item, "external_id", "people.batch", index)
          { "customer_external_id" => customer, "person" => item.reject { |key, _| key == "customer_external_id" } }
        end
        call("POST", "/people/batch",
             body: { "items" => wire }, idempotency_key: idempotency_key, timeout: timeout)
      end
    end
  end
end
