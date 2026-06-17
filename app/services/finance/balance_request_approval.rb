module Finance
  # Handles BalanceRequest lifecycle: submit → approve → mark_paid, plus reject.
  #
  # Unlike expenses, balance requests require an explicit mark_paid step because
  # money is being physically issued. mark_paid creates the top_up transaction
  # on the creator's balance account, increasing their balance.
  #
  # Self-approval is blocked with the usual business-owner exception.
  class BalanceRequestApproval
    include AuditLoggable

    Result = Struct.new(:ok, :balance_request, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(balance_request, actor:)
      @request = balance_request
      @actor   = actor
    end

    # draft → pending_approval
    def submit!
      transition(from: "draft", to: "pending_approval", action: "submit")
    end

    # pending_approval → approved
    def approve!
      return self_approval_error if self_approval?

      transition(from: "pending_approval", to: "approved", action: "approve") do
        @request.approved_by = @actor
        @request.approved_at = Time.current
      end
    end

    # pending_approval → rejected
    def reject!(reason:)
      return self_approval_error if self_approval?

      transition(from: "pending_approval", to: "rejected", action: "reject",
                 metadata: { reason: reason }) do
        @request.rejection_reason = reason
      end
    end

    # approved → paid
    # Creates a top_up transaction on the creator's balance account.
    def mark_paid!
      unless @request.status == "approved"
        return Result.new(ok: false, balance_request: @request,
                          error: I18n.t("finance.balance_requests.errors.must_be_approved"))
      end

      account = creator_account
      unless account
        return Result.new(ok: false, balance_request: @request,
                          error: I18n.t("finance.balance_requests.errors.no_balance_account",
                                        name: @request.created_by.full_name))
      end

      ActiveRecord::Base.transaction do
        account.custody_transactions.create!(
          business:   account.business,
          txn_type:   "top_up",
          amount:     @request.amount,
          created_by: @actor,
          notes:      I18n.t("finance.balance_requests.top_up_note",
                             reference: @request.reference_number)
        )
        account.refresh_balance!

        @request.status  = "paid"
        @request.paid_by = @actor
        @request.paid_at = Time.current
        @request.save!

        log_audit(actor: @actor, auditable: @request, action: "mark_paid",
                  changes: { status: [ "approved", "paid" ] })
      end
      Result.new(ok: true, balance_request: @request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, balance_request: @request,
                 error: e.record.errors.full_messages.to_sentence)
    end

    private

    def creator_account
      @request.created_by&.custody_accounts&.active&.first
    end

    def self_approval?
      return false if @actor.owner?

      Approvals::SelfApproval.by_requester?(approver: @actor,
                                            requester: @request.created_by_id)
    end

    def self_approval_error
      Result.new(ok: false, balance_request: @request,
                 error: Approvals::SelfApproval.error_message)
    end

    def transition(from:, to:, action:, metadata: {})
      unless @request.status == from
        return Result.new(ok: false, balance_request: @request,
                          error: I18n.t("finance.balance_requests.errors.invalid_transition",
                                        default: "Invalid status transition."))
      end

      ActiveRecord::Base.transaction do
        @request.status = to
        yield if block_given?
        @request.save!
        log_audit(actor: @actor, auditable: @request, action: action,
                  changes: { status: [ from, to ] }, metadata: metadata)
      end
      Result.new(ok: true, balance_request: @request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, balance_request: @request,
                 error: e.record.errors.full_messages.to_sentence)
    end
  end
end
