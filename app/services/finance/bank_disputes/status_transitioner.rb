module Finance
  module BankDisputes
    # Single generic entry point for every BankDispute status transition
    # (submit to bank, start investigation, refund, confirm successful,
    # reject, close). The transitions are structurally identical — validate
    # the move against BankDispute::TRANSITIONS, persist the target status
    # plus whichever optional fields apply, and log an audit entry — so one
    # service handles all of them rather than six near-duplicate classes.
    class StatusTransitioner
      include AuditLoggable

      Result = Struct.new(:ok, :dispute, :error, keyword_init: true) { def ok? = ok }

      TRANSITION_FIELDS = {
        "submitted_to_bank" => %i[bank_ticket_number notes],
        "under_investigation" => %i[notes],
        "refunded" => %i[notes],
        "confirmed_successful" => %i[notes],
        "rejected" => %i[notes],
        "closed" => %i[notes]
      }.freeze

      def initialize(bank_dispute_id, actor:, target_status:, params: {})
        @bank_dispute_id = bank_dispute_id
        @actor           = actor
        @target_status   = target_status.to_s
        @params          = params
      end

      def call
        dispute = BankDispute.where(business_id: @actor.business_id).find(@bank_dispute_id)

        return err(dispute, "invalid_transition") unless dispute.can_transition_to?(@target_status)

        was_open = !dispute.resolved?

        ActiveRecord::Base.transaction do
          attrs = TRANSITION_FIELDS.fetch(@target_status, []).each_with_object({}) do |field, h|
            h[field] = @params[field] if @params.key?(field)
          end
          attrs[:status] = @target_status

          dispute.update!(attrs)

          log_audit(actor: @actor, auditable: dispute, action: @target_status, metadata: attrs.except(:status))

          # The only transitions landing on a resolved status (refunded,
          # confirmed_successful, rejected) start from "under_investigation"
          # (never-resolved), so this fires exactly once per dispute — the
          # later resolved -> closed transition starts from an
          # already-resolved status and is correctly skipped.
          if was_open && dispute.resolved?
            Finance::BankDisputes::RemainingBalanceReleaser.call(dispute, actor: @actor)
          end

          Result.new(ok: true, dispute: dispute)
        end
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, dispute: dispute, error: e.record.errors.full_messages.to_sentence)
      end

      private

      def err(dispute, key)
        Result.new(ok: false, dispute: dispute, error: I18n.t("finance.bank_disputes.errors.#{key}"))
      end
    end
  end
end
