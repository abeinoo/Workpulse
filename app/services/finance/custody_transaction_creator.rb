module Finance
  # Records a manual balance transaction. The UI submits a POSITIVE magnitude plus a
  # type; this service derives the signed amount (the model stores signed values so
  # the balance is a plain SUM), persists it, refreshes the account's cached balance,
  # and writes an audit entry.
  #
  # A transfer is recorded as a linked PAIR: a negative leg out of the source and
  # a positive leg into the target, cross-referenced via transfer_counterparty_id.
  #
  # expense_deduction is posted automatically by Finance::ExpenseApproval on
  # approval — it should not be submitted manually via this service.
  class CustodyTransactionCreator
    include AuditLoggable

    Result = Struct.new(:ok, :transaction, :error, keyword_init: true) { def ok? = ok }

    MANUAL_TYPES = %w[top_up adjustment].freeze

    def initialize(account, actor:, params:)
      @account = account
      @actor   = actor
      @params  = params
    end

    def call
      type = @params[:txn_type].to_s
      mag  = parse_magnitude
      return err(I18n.t("finance.custody.errors.amount_required")) unless mag&.positive?

      type == "transfer" ? create_transfer(mag) : create_single(type, mag)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.to_sentence)
    end

    private

    def create_single(type, mag)
      return err(I18n.t("finance.custody.errors.invalid_type")) unless MANUAL_TYPES.include?(type)

      txn = nil
      ActiveRecord::Base.transaction do
        txn = build_txn(@account, type, signed_amount(type, mag))
        txn.save!
        @account.refresh_balance!
        audit(txn)
      end
      Result.new(ok: true, transaction: txn)
    end

    def create_transfer(mag)
      target = @account.business.custody_accounts.find_by(id: @params[:target_account_id])
      if target.nil? || target.id == @account.id
        return err(I18n.t("finance.custody.errors.target_required"))
      end

      out_txn = nil
      ActiveRecord::Base.transaction do
        out_txn = build_txn(@account, "transfer", -mag)
        in_txn  = build_txn(target,   "transfer",  mag)
        out_txn.save!
        in_txn.save!
        out_txn.update_column(:transfer_counterparty_id, in_txn.id)
        in_txn.update_column(:transfer_counterparty_id, out_txn.id)
        @account.refresh_balance!
        target.refresh_balance!
        audit(out_txn, metadata: { target_account_id: target.id })
        audit(in_txn,  metadata: { source_account_id: @account.id })
      end
      Result.new(ok: true, transaction: out_txn)
    end

    def build_txn(account, type, amount)
      account.custody_transactions.build(
        business:   account.business,
        txn_type:   type,
        amount:     amount,
        notes:      @params[:notes],
        created_by: @actor
      ).tap do |txn|
        txn.document.attach(@params[:document]) if @params[:document].present?
      end
    end

    def signed_amount(type, mag)
      case type
      when "top_up"    then mag
      when "adjustment" then @params[:adjustment_direction].to_s == "decrease" ? -mag : mag
      end
    end

    def parse_magnitude
      BigDecimal(@params[:magnitude].to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def audit(txn, metadata: {})
      log_audit(actor: @actor, auditable: txn, action: "balance_#{txn.txn_type}",
                changes: { amount: [ nil, txn.amount ] },
                metadata: metadata.merge(account_id: txn.custody_account_id))
    end

    def err(message)
      Result.new(ok: false, error: message)
    end
  end
end
