class TillDeposit < ApplicationRecord
  include Voidable
  include AuditLoggable

  belongs_to :daily_reconciliation, inverse_of: :till_deposits
  belongs_to :payment_method
  belongs_to :deposited_by, class_name: "User"
  belongs_to :ignored_by, class_name: "User", optional: true

  has_many :deposit_matches, dependent: :destroy
  has_many :bank_statement_transactions, through: :deposit_matches
  has_many :bank_disputes, dependent: :restrict_with_error

  # Deposits still eligible to receive another matched bank transaction —
  # i.e. not yet fully (or over-) matched. Used to offer a deposit as a valid
  # target from the transaction-initiated manual-match flow even when it
  # already has some (but not all) of its transactions linked.
  #
  # A correlated subquery, not LEFT JOIN + GROUP BY: a grouped scope breaks
  # any relation that composes it with includes/eager_load or other joins
  # (PG::GroupingError on the joined tables' columns), and needs no DISTINCT.
  scope :not_fully_matched, -> {
    where(<<~SQL.squish)
      COALESCE((SELECT SUM(dm.matched_amount) FROM deposit_matches dm
                WHERE dm.till_deposit_id = till_deposits.id), 0) < till_deposits.amount
    SQL
  }

  validates :amount,       presence: true, numericality: { greater_than: 0 }
  validates :deposited_at, presence: true

  validate :payment_method_must_be_cash_like

  VERIFICATION_CRITICAL_FIELDS = %w[amount deposited_at reference payment_method_id voided_at].freeze

  after_save :invalidate_bank_verification_if_critical_change

  # Sum of every matched bank transaction's contribution toward this deposit.
  # Sums the loaded array in Ruby when deposit_matches is already
  # eager-loaded (e.g. via till_deposits: :deposit_matches on the DR index
  # page) instead of issuing a fresh SQL SUM per deposit — chaining .sum onto
  # an association always hits the DB, even when the base association was
  # preloaded across a whole list.
  def matched_total
    deposit_matches.loaded? ? deposit_matches.sum(&:matched_amount) : deposit_matches.sum(:matched_amount)
  end

  # The part of matched_total the bank currently CONFIRMS: links to a
  # transaction that is "verified" on a statement that still exists. A link
  # whose transaction needs re-verification, or that sits on a deleted
  # statement, still occupies the deposit (matched_total / match_status — the
  # capacity ManualMatcher checks) but is not confirmed bank evidence. Uses
  # the preloaded deposit_matches → bank_statement_transaction → bank_statement
  # chain when present (the DR index and export preload it).
  def verified_matched_total
    if deposit_matches.loaded?
      deposit_matches.select { |m| m.bank_statement_transaction.confirms_deposit? }.sum(&:matched_amount)
    else
      deposit_matches.joins(bank_statement_transaction: :bank_statement)
                     .where(bank_statement_transactions: { status: "verified" }, bank_statements: { deleted_at: nil })
                     .sum(:matched_amount)
    end
  end

  # The active bank dispute case, if any — a resolved dispute (refunded,
  # confirmed successful, rejected, or closed) no longer counts, since the
  # outcome is known and the deposit is no longer "at risk". Filters the
  # loaded association in Ruby (rather than a new `.where` query) so this
  # stays N+1-safe when `bank_disputes` is preloaded across a list of deposits.
  def open_bank_dispute
    bank_disputes.reject(&:resolved?).max_by(&:created_at)
  end

  # :unmatched | :partially_matched | :fully_matched | :over_matched — derived
  # from the running total, never stored, so it's always correct regardless
  # of how many transactions end up backing this deposit.
  def match_status
    return :unmatched if deposit_matches.none?

    diff = matched_total - amount
    return :fully_matched if diff.zero?

    diff.positive? ? :over_matched : :partially_matched
  end

  # A deposit deliberately marked as never expected to appear on the bank
  # statement (e.g. a cash deposit reconciled outside the bank entirely) —
  # excluded from "Missing from Bank" once set. Only meaningful while
  # :unmatched; ignoring a matched deposit is rejected at the service layer.
  def ignored?
    ignored_at.present?
  end

  private

  def invalidate_bank_verification_if_critical_change
    return if bank_statement_transactions.empty?
    return unless VERIFICATION_CRITICAL_FIELDS.any? { |f| saved_change_to_attribute?(f) }

    changes = VERIFICATION_CRITICAL_FIELDS.filter_map { |f|
      change = saved_change_to_attribute(f)
      [ f, change ] if change
    }.to_h

    bank_statement_transactions.each do |txn|
      next if txn.ignored?

      previous_status = txn.status
      txn.update_columns(status: "needs_reverification")

      log_audit(
        actor:     deposited_by,
        auditable: txn,
        action:    :verification_invalidated,
        changes:   changes,
        metadata:  { previous_status: previous_status }
      )
    end
  end

  def payment_method_must_be_cash_like
    return unless payment_method
    return if payment_method.cash_like?

    errors.add(:payment_method, :not_cash_like)
  end
end
