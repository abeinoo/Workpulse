class Expense < ApplicationRecord
  include Attachable

  belongs_to :business
  belongs_to :branch,           optional: true
  belongs_to :expense_category
  belongs_to :expense_type,     optional: true
  belongs_to :created_by,  class_name: "User", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :source_recurring_expense, class_name: "RecurringExpense", optional: true

  has_many :expense_allocations, dependent: :destroy
  has_many :allocated_branches,  through: :expense_allocations, source: :branch
  has_many :expense_taggings,    dependent: :destroy
  has_many :expense_tags,        through: :expense_taggings
  has_many :custody_transactions, dependent: :nullify

  has_many_attached :documents

  accepts_nested_attributes_for :expense_allocations, allow_destroy: true,
                                reject_if: ->(attrs) { attrs[:branch_id].blank? }

  # draft → pending_approval → approved  (or → rejected)
  STATUSES = %w[draft pending_approval approved rejected].freeze
  enum :status, { draft: "draft", pending_approval: "pending_approval",
                  approved: "approved", rejected: "rejected" },
       default: "draft"

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :expense_date, presence: true
  validates :notes, presence: true, unless: :system_generated?
  validates :reference_number, presence: true,
                               uniqueness: { scope: :business_id, case_sensitive: false }
  validate  :branch_in_same_business
  validate  :category_in_same_business
  validate  :type_matches_category
  validate  :allocations_consistent_when_shared
  validate  :documents_acceptable
  validate  :creator_has_balance_account_if_deducting

  before_validation :sync_shared_flag

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

  private

  def system_generated?
    source_recurring_expense_id.present?
  end

  def sync_shared_flag
    self.is_shared = effective_allocations.any?
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

    errors.add(:branch_id, :present_for_shared) if branch_id.present?

    total = effective_allocations.sum { |a| a.allocation_percentage.to_d }
    errors.add(:base, :allocation_not_100) unless total == 100
  end

  def creator_has_balance_account_if_deducting
    return unless deduct_from_balance?
    return if created_by.nil?
    return if created_by.custody_accounts.active.exists?

    errors.add(:base, :no_balance_account)
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
