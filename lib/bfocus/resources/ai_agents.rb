# frozen_string_literal: true

module Bfocus
  module Resources
    # Agentes de IA — `client.ai_agents`. Exige o módulo de Atendimento.
    #
    # Agente: `"id"`, `"name"`, `"product"` (`{"id", "slug", "name", "is_active"}`), `"active"`,
    # `"persona"`, `"scope"`, `"avatar_url"`, `"created_at"`, `"updated_at"`.
    class AIAgents < Base
      # Agentes de IA da conta. `GET /ai-agents`
      # @return [Array<Hash>]
      def list(timeout: nil)
        call("GET", "/ai-agents", timeout: timeout)
      end

      # Um agente. `GET /ai-agents/{agent_id}`
      # @return [Hash]
      def get(agent_id, timeout: nil)
        call("GET", "/ai-agents/#{segment(agent_id, 'agent_id')}", timeout: timeout)
      end

      # Testa a resposta do agente a uma mensagem (consome IA da conta).
      # `POST /ai-agents/{agent_id}/preview`
      #
      # @param history [Array<Hash>] turnos anteriores, `[{role: "customer"|"bot", content: "…"}]`
      #   (até 20).
      # @return [Hash] `"action"` (`answer`, `handoff` ou `refuse`), `"answer_html"`,
      #   `"escalated"`, `"refused"`, `"handoff_reason"`, `"confidence"`, `"topic"`, `"guards"`,
      #   `"citations"`, `"sources"`, `"collected"`, `"missing"`.
      def preview(agent_id, message, history: UNSET, idempotency_key: nil, timeout: nil)
        body = compact("message" => message, "history" => history)
        call("POST", "/ai-agents/#{segment(agent_id, 'agent_id')}/preview",
             body: body, idempotency_key: idempotency_key, timeout: timeout)
      end
    end
  end
end
