class RecurringExpense < ApplicationRecord
  belongs_to :business
  belongs_to :branch,           optional: true
  belongs_to :expense_category
  belongs_to :expense_type,     optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :recurring_expense_allocations, dependent: :destroy
  has_many :allocated_branches, through: :recurring_expense_allocations, source: :branch
  has_many :generated_expenses, class_name: "Expense",
                                foreign_key: :source_recurring_expense_id,
                                dependent: :nullify

  accepts_nested_attributes_for :recurring_expense_allocations, allow_destroy: true,
                                reject_if: ->(attrs) { attrs[:branch_id].blank? }

  FREQUENCIES = %w[weekly monthly quarterly yearly].freeze
  enum :frequency, { weekly: "weekly", monthly: "monthly",
                     quarterly: "quarterly", yearly: "yearly" }

  ADVANCE_BY = { "weekly" => 1.week, "monthly" => 1.month,
                 "quarterly" => 3.months, "yearly" => 1.year }.freeze

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :frequency, presence: true
  validates :start_date, :next_run_on, presence: true
  validate  :end_after_start
  validate  :next_run_on_after_start
  validate  :branch_in_same_business
  validate  :category_in_same_business
  validate  :type_matches_category

  scope :for_business, ->(business) { where(business: business) }
  scope :for_branch,   ->(branch_id) { where(branch_id: branch_id) if branch_id.present? }
  scope :active,       -> { where(active: true) }
  scope :ordered,      -> { order(:next_run_on) }

  # Active templates due to generate on/before `date` and not past their end_date.
  scope :due_on, ->(date) {
    active.where(next_run_on: ..date)
          .where("end_date IS NULL OR end_date >= ?", date)
  }

  # The next scheduled date strictly after `from`, per frequency.
  def next_occurrence_after(from = next_run_on)
    from + ADVANCE_BY.fetch(frequency)
  end

  # True when this template has ended (end_date passed) on the given date.
  def ended_on?(date)
    end_date.present? && end_date < date
  end

  private

  def end_after_start
    return if end_date.blank? || start_date.blank?

    errors.add(:end_date, :after_start) if end_date < start_date
  end

  def next_run_on_after_start
    return if next_run_on.blank? || start_date.blank?

    errors.add(:next_run_on, :before_start) if next_run_on < start_date
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
end
