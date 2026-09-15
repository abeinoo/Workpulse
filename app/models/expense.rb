class Expense < ApplicationRecord
  include Attachable
  include Settleable

  belongs_to :business
  belongs_to :branch,           optional: true
  belongs_to :expense_category
  belongs_to :expense_type,     optional: true
  belongs_to :created_by,  class_name: "User", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :cancelled_by, class_name: "User", optional: true
  belongs_to :source_recurring_expense, class_name: "RecurringExpense", optional: true
  belongs_to :source_pos_import, class_name: "PosImport", optional: true, inverse_of: :generated_expenses
  belongs_to :source_payroll_period, class_name: "PayrollPeriod", optional: true

  has_many :expense_allocations, dependent: :destroy
  has_many :allocated_branches,  through: :expense_allocations, source: :branch
  has_many :expense_taggings,    dependent: :destroy
  has_many :expense_tags,        through: :expense_taggings
  has_many :custody_transactions, dependent: :nullify

  has_many_attached :documents

  accepts_nested_attributes_for :expense_allocations, allow_destroy: true,
                                reject_if: ->(attrs) { attrs[:branch_id].blank? }

  # draft → pending_approval → approved  (or → rejected)
  # draft | pending_approval | approved → cancelled (requester/manager cancel)
  STATUSES = %w[draft pending_approval approved rejected cancelled].freeze
  enum :status, { draft: "draft", pending_approval: "pending_approval",
                  approved: "approved", rejected: "rejected", cancelled: "cancelled" },
       default: "draft"

  # A branch is always required: either a specific branch, or the "shared" option
  # (branch_id blank), split across branches via expense_allocations.
  DISTRIBUTION_METHODS = %w[equal percentage manual].freeze

  # How the expense is funded. "employee_custody" (deduct_from_balance checked),
  # "not_linked_to_balance" (a Direct expense paid through a means this system
  # doesn't track as an account), and "unpaid" (an Installment expense, whose
  # payments each carry their own independent source) are reachable today — the
  # rest are reserved on the selector so display logic doesn't need to change
  # shape once they're wired up, mirroring GoodsReceipt::FUNDING_SOURCE_KINDS.
  #
  # IMPORTANT: payment_source answers "where did the money come from?" — never
  # "was the expense paid?". "not_linked_to_balance" and "unpaid" both mean no
  # CustodyAccount is involved, but only "unpaid" means no money has actually
  # been paid yet. See #sync_payment_source and Settleable#financial_status,
  # which is the actual (and only) source of paid/unpaid truth.
  PAYMENT_SOURCES = %w[employee_custody not_linked_to_balance company_cash bank_account supplier_credit unpaid].freeze

  # Payment Type ("direct" — the amount entered IS the actual payment — vs
  # "installment" — the amount entered is only the total agreed, paid off
  # later) is INDEPENDENT of deduct_from_balance ("paid from my custody
  # account or not"). They answer two different questions and must never be
  # conflated:
  #   - direct   + deduct_from_balance: true  → auto-settled in full from the
  #                                             creator's custody account at
  #                                             approval (unchanged
  #                                             Finance::ExpenseApproval
  #                                             mechanism)
  #   - direct   + deduct_from_balance: false → at approval, the full amount is
  #                                             posted as a FinancialSettlement
  #                                             with a NIL funding_source — the
  #                                             amount is understood as already
  #                                             paid through a means this
  #                                             system doesn't track as an
  #                                             account (see
  #                                             Finance::ExpenseApproval
  #                                             #post_unlinked_settlement).
  #                                             No CustodyTransaction is
  #                                             created; the expense still
  #                                             shows as fully paid
  #   - installment (regardless)             → nothing posted at approval;
  #                                             every actual payment is
  #                                             recorded afterward through
  #                                             Finance::ExpensePaymentRecorder,
  #                                             each with its OWN independent
  #                                             "paid from balance?" choice
  # "Paid from my balance" is always an explicit, opt-in choice made by
  # whoever is performing the action — never inferred from who created the
  # expense (a painter can be paid from MY custody, company cash, or someone
  # else's account entirely).
  PAYMENT_TYPES = %w[direct installment].freeze
  enum :payment_type, { direct: "direct", installment: "installment" }, default: "direct"

  # Once system_generated? (see #system_generated?), only these columns may
  # still change — the void path. Everything else is locked at the model
  # layer, not just the policy layer, so a system-generated expense can never
  # be edited even from the console or a future service bug.
  SYSTEM_GENERATED_MUTABLE_ATTRIBUTES = %w[voided_at voided_by_id void_reason updated_at].freeze

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :expense_date, presence: true

  validates :reference_number, presence: true,
                               uniqueness: { scope: :business_id, case_sensitive: false }
  validates :distribution_method, inclusion: { in: DISTRIBUTION_METHODS }, allow_nil: true
  validates :payment_source, inclusion: { in: PAYMENT_SOURCES }
  validate  :branch_in_same_business
  validate  :category_in_same_business
  validate  :type_matches_category
  validate  :allocations_consistent_when_shared
  validate  :documents_acceptable
  validate  :creator_has_balance_account_if_deducting

  before_validation :normalize_branch_mode
  before_validation :force_no_balance_deduction_for_installment
  before_validation :sync_payment_source
  before_update  :prevent_system_generated_mutation
  before_destroy :prevent_system_generated_destruction

  scope :for_business, ->(business)   { where(business: business) }
  scope :for_branch,   ->(branch_id)  { where(branch_id: branch_id) if branch_id.present? }
  scope :with_status,  ->(status)     { where(status: status) if status.present? }
  scope :for_category, ->(id)         { where(expense_category_id: id) if id.present? }
  scope :for_type,     ->(id)         { where(expense_type_id: id) if id.present? }
  scope :on_or_after,  ->(date)       { where(expense_date: date..) if date.present? }
  scope :on_or_before, ->(date)       { where(expense_date: ..date) if date.present? }
  scope :in_period,    ->(from, to)   { where(expense_date: from..to) }
  scope :pending,      -> { where(status: "pending_approval") }
  scope :recent,       -> { order(expense_date: :desc, id: :desc) }

  def effective_allocations
    expense_allocations.reject(&:marked_for_destruction?)
  end

  def employee_custody_funded?
    payment_source == "employee_custody"
  end

  # Settleable's required hook: the amount considered "fully settled".
  def settlement_total
    amount
  end

  # Public: read by ExpensePolicy (blocks manual edit/delete) and views (badge).
  def system_generated?
    source_recurring_expense_id.present? || source_payroll_period_id.present?
  end

  private

  # branch_id present  → specific-branch expense: any distribution data is ignored
  #                       (existing allocation rows are dropped, not saved).
  # branch_id blank    → shared/organization-level expense: is_shared is always
  #                       true, so an incomplete distribution fails validation
  #                       loudly instead of silently saving as an unscoped expense.
  def normalize_branch_mode
    if branch_id.present?
      expense_allocations.each(&:mark_for_destruction)
      self.distribution_method = nil
      self.is_shared = false
    else
      self.is_shared = true
    end
  end

  def branch_in_same_business
    return if branch.nil? || business_id.nil?

    errors.add(:branch, :invalid) if branch.business_id != business_id
  end

  def category_in_same_business
    return if expense_category.nil? || business_id.nil?

    errors.add(:expense_category, :invalid) if expense_category.business_id != business_id
  end

  def type_matches_category
    return if expense_type.nil?

    errors.add(:expense_type, :invalid) if expense_type.expense_category_id != expense_category_id
  end

  def allocations_consistent_when_shared
    return unless is_shared

    errors.add(:distribution_method, :required) if distribution_method.blank?

    rows = effective_allocations
    if rows.empty?
      errors.add(:expense_allocations, :at_least_one_branch_required)
    else
      total = rows.sum { |a| a.allocation_percentage.to_d }
      errors.add(:base, :allocation_not_100) unless total == 100
    end
  end

  def sync_payment_source
    self.payment_source =
      if deduct_from_balance?
        "employee_custody"
      elsif direct?
        "not_linked_to_balance"
      else
        "unpaid"
      end
  end

  # The payment-source decision belongs to each individual payment for an
  # installment expense (see Finance::ExpensePaymentRecorder's own
  # paid_from_balance choice, made per payment by whoever records it) — never
  # to the expense as a whole. This is enforced here, at the data-model
  # level, not just hidden in the UI: no matter how a request is built (a
  # tampered form submission, a console call, a future bug), an installment
  # expense can never carry deduct_from_balance: true, so
  # Finance::ExpenseApproval#post_balance_deduction can never auto-settle
  # the full agreed amount for one. Only Direct expenses may opt into the
  # single full-amount custody deduction at approval.
  def force_no_balance_deduction_for_installment
    self.deduct_from_balance = false if installment?
  end

  def creator_has_balance_account_if_deducting
    return unless deduct_from_balance?
    return if created_by.nil?
    return if created_by.custody_accounts.active.exists?

    errors.add(:base, :no_balance_account)
  end

  def prevent_system_generated_mutation
    return unless system_generated?

    disallowed = changed_attribute_names_to_save - SYSTEM_GENERATED_MUTABLE_ATTRIBUTES
    return if disallowed.empty?

    raise ActiveRecord::ReadOnlyRecord, "System-generated expenses can only be voided, not edited."
  end

  def prevent_system_generated_destruction
    raise ActiveRecord::ReadOnlyRecord, "System-generated expenses cannot be deleted." if system_generated?
  end

  def documents_acceptable
    return unless documents.attached?

    documents.blobs.each do |blob|
      next if Attachable::DOCUMENT_CONTENT_TYPES.include?(blob.content_type)

      human_types = Attachable::DOCUMENT_CONTENT_TYPES
        .map { |t| Attachable::CONTENT_TYPE_LABELS.fetch(t, t.split("/").last.upcase) }
        .join(", ")
      errors.add(:documents, :invalid_content_type,
                 message: I18n.t("attachments.errors.invalid_content_type",
                                 types: human_types,
                                 default: "must be one of: #{human_types}"))
    end
  end
end
