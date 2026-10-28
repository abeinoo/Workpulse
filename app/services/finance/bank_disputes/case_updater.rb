module Finance
  module BankDisputes
    # Accountant/Finance Manager/Super Admin case-management updates on an
    # open BankDispute: bank ticket number, a free-text case note (tagged
    # with one of a fixed set of categories — "Waiting for bank response",
    # "Bank requested additional documents", etc.), and additional photo
    # evidence. These are operational updates, not workflow-state
    # transitions (see Finance::BankDisputes::StatusTransitioner for those) —
    # each one that's actually present produces its own audit entry so the
    # timeline reads as a distinct line per update.
    class CaseUpdater
      include AuditLoggable

      Result = Struct.new(:ok, :dispute, :error, keyword_init: true) { def ok? = ok }

      CASE_NOTE_CATEGORIES = %w[
        waiting_for_bank additional_info_requested customer_contacted
        documents_submitted bank_called_back escalated other
      ].freeze

      def initialize(bank_dispute_id, actor:, bank_ticket_number: nil, case_note: nil,
                     case_note_category: nil, photos: [])
        @bank_dispute_id     = bank_dispute_id
        @actor               = actor
        @bank_ticket_number  = bank_ticket_number.presence
        @case_note           = case_note.presence
        @case_note_category  = case_note_category.presence
        @photos              = Array(photos).reject(&:blank?)
      end

      def call
        dispute = BankDispute.where(business_id: @actor.business_id).find(@bank_dispute_id)

        return err(dispute, "case_closed") if dispute.status == "closed"

        ActiveRecord::Base.transaction do
          if @bank_ticket_number && @bank_ticket_number != dispute.bank_ticket_number
            dispute.update!(bank_ticket_number: @bank_ticket_number)
            log_audit(actor: @actor, auditable: dispute, action: "bank_ticket_number_added",
                      metadata: { bank_ticket_number: @bank_ticket_number })
          end

          # Fail-closed (BUG-003): a case note is stored only in its audit
          # entry, so without the entry nothing would be saved.
          if @case_note
            log_audit!(actor: @actor, auditable: dispute, action: "case_note_added",
                       metadata: { category: @case_note_category, note: @case_note })
          end

          if @photos.any?
            dispute.photos.attach(@photos)
            log_audit(actor: @actor, auditable: dispute, action: "attachments_added",
                      metadata: { count: @photos.size })
          end

          Result.new(ok: true, dispute: dispute)
        end
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, dispute: dispute, error: e.record.errors.full_messages.to_sentence)
      rescue AuditLoggable::AuditWriteFailed
        Result.new(ok: false, dispute: dispute, error: I18n.t("audit_log.errors.write_failed"))
      end

      private

      def err(dispute, key)
        Result.new(ok: false, dispute: dispute, error: I18n.t("finance.bank_disputes.errors.#{key}"))
      end
    end
  end
end
