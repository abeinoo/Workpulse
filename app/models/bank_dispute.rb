class BankDispute < ApplicationRecord
  include AuditLoggable
  include Attachable

  # Plain string status column, not a Rails `enum` — "new" as a member name
  # collides with ActiveRecord::Base.new, so status is validated via
  # inclusion instead (same approach BankStatementTransaction uses for its
  # own status column).
  STATUSES = %w[new submitted_to_bank under_investigation refunded confirmed_successful rejected closed].freeze

  # missing_from_bank — reported against an already-recorded TillDeposit that
  # never shows up on the bank statement.
  # atm_deposit_failure — reported directly from the Record Deposit dialog,
  # before any TillDeposit exists: cash went into an ATM/POS machine, the
  # card was debited, but the money never reached the bank.
  KINDS = %w[missing_from_bank atm_deposit_failure].freeze

  TRANSITIONS = {
    "new"                  => %w[submitted_to_bank],
    "submitted_to_bank"    => %w[under_investigation],
    "under_investigation"  => %w[refunded confirmed_successful rejected],
    "refunded"             => %w[closed],
    "confirmed_successful" => %w[closed],
    "rejected"             => %w[closed]
  }.freeze

  RESOLVED_STATUSES = %w[refunded confirmed_successful rejected closed].freeze

  belongs_to :till_deposit, optional: true
  belongs_to :daily_reconciliation, optional: true
  belongs_to :business
  belongs_to :branch
  belongs_to :opened_by, class_name: "User"

  # Every RemainingDepositBalance reservation/release this dispute has ever
  # caused — the append-only trail Finance::BankDisputes::RemainingBalance*
  # services write to and read back from (never a computed/cached figure).
  has_many :remaining_deposit_balance_transactions, dependent: :restrict_with_error

  has_many_attached :photos

  validates :transaction_date, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :bank_name, presence: true
  validates :terminal_id, presence: true
  validates :opened_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :kind, inclusion: { in: KINDS }
  validates :card_last4, format: { with: /\A\d{4}\z/ }, allow_blank: true
  validates :card_last4, presence: true, if: -> { kind == "atm_deposit_failure" }
  validate  :at_least_one_anchor
  validate  :photos_acceptable

  scope :open_cases, -> { where.not(status: RESOLVED_STATUSES) }
  scope :atm_deposit_failure, -> { where(kind: "atm_deposit_failure") }

  def resolved? = RESOLVED_STATUSES.include?(status)

  def can_transition_to?(target) = TRANSITIONS.fetch(status, []).include?(target.to_s)

  # The DR this dispute belongs to, regardless of which anchor it uses.
  def daily_reconciliation_for = till_deposit&.daily_reconciliation || daily_reconciliation

  def atm_deposit_failure? = kind == "atm_deposit_failure"

  # True once this dispute is ready to be registered as a deposit
  # (confirmed_successful, no TillDeposit yet) but the resulting
  # Finance::TillDepositRecorder call would actually be rejected — it always
  # attributes the deposit to opened_by (whoever reported the case), never to
  # the confirming accountant, and rejects unless that person is either the
  # till's currently-assigned depositor or the business owner (see
  # Finance::BankDisputes::DepositConfirmer's own comment on why). Surfaced on
  # the show page so this is visible BEFORE the accountant clicks Confirm
  # Deposit and hits a generic "not the depositor" error afterward.
  def blocked_by_depositor_mismatch?
    return false unless status == "confirmed_successful" && till_deposit.blank?
    return false if opened_by.owner?

    session = daily_reconciliation_for&.till_session
    session.present? && session.depositor_id != opened_by_id
  end

  private

  # At least one anchor must always be present — normally exactly one (which
  # deposit/reconciliation this dispute is about), except once an
  # atm_deposit_failure dispute is confirmed successful and
  # Finance::BankDisputes::DepositConfirmer links the resulting TillDeposit:
  # at that point both are legitimately set (the original DR anchor stays as
  # the historical record of where the case was opened).
  def at_least_one_anchor
    return if till_deposit_id.present? || daily_reconciliation_id.present?

    errors.add(:base, :exactly_one_anchor, message: "must be linked to either a deposit or a reconciliation")
  end

  # has_many_attached can't use the Attachable.validates_attachment helper
  # (that one targets a single attachment), so validate each blob here —
  # mirrors GoodsReceipt#invoices_acceptable / Expense#documents_acceptable.
  def photos_acceptable
    return unless photos.attached?

    photos.each do |photo|
      blob = photo.blob
      content_types = Attachable::IMAGE_CONTENT_TYPES + Attachable::DOCUMENT_CONTENT_TYPES

      unless content_types.include?(blob.content_type)
        human_types = content_types
          .map { |t| Attachable::CONTENT_TYPE_LABELS.fetch(t, t.split("/").last.upcase) }
          .uniq.join(", ")
        errors.add(:photos, :invalid_content_type,
                   message: I18n.t("attachments.errors.invalid_content_type",
                                   types: human_types,
                                   default: "must be one of: #{human_types}"))
      end

      if blob.byte_size > Attachable::DEFAULT_DOCUMENT_SIZE
        human_max = ActiveSupport::NumberHelper.number_to_human_size(Attachable::DEFAULT_DOCUMENT_SIZE)
        errors.add(:photos, :file_too_large,
                   message: I18n.t("attachments.errors.file_too_large",
                                   max: human_max,
                                   default: "must be smaller than #{human_max}"))
      end
    end
  end
end
