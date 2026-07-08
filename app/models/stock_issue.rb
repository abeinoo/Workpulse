class StockIssue < ApplicationRecord
  include ImmutableDocument
  include Voidable

  # "posted" is the historical, default behavior — created and posted in one
  # atomic step (see StockIssuePoster). "draft" exists only for the stock-issue
  # import flow: a single issue is created up front, items are appended to it
  # as each import row resolves (possibly over several requests), and it's only
  # transitioned to "posted" — generating movements — once, when the whole
  # import is complete. There is never more than one issue per import.
  enum :status, { draft: "draft", posted: "posted" }

  belongs_to :business
  belongs_to :warehouse
  # The branch that consumed the issued stock — feeds branch profitability.
  # Required for NEW issues (on :create) so every consumption is attributable;
  # the DB column stays nullable so pre-existing rows remain valid and voidable.
  belongs_to :branch, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :items, class_name: "StockIssueItem", dependent: :destroy
  has_many :inventory_movements, as: :source, dependent: :destroy

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  # issue_number is assigned in before_create (see #assign_issue_number) — the
  # DB's NOT NULL + unique index are the hard guards, so only
  # uniqueness-when-present is validated here (mirrors StockCount#count_number).
  validates :issue_number, uniqueness: { scope: :business_id, case_sensitive: false }, allow_nil: true
  validates :issued_on, presence: true
  validates :branch_id, presence: true, on: :create
  # A draft may sit with zero items while the user resolves import errors —
  # the item requirement only applies once it's actually being posted.
  validate  :has_at_least_one_item, unless: :draft?
  validate  :branch_in_same_business

  before_create :assign_issue_number

  scope :for_business,  ->(business)     { where(business: business) }
  scope :recent,        -> { order(issued_on: :desc, id: :desc) }
  scope :for_warehouse, ->(warehouse_id) { where(warehouse_id: warehouse_id) if warehouse_id.present? }
  scope :for_branch,    ->(branch_id)    { where(branch_id: branch_id) if branch_id.present? }
  scope :on_or_after,   ->(date)         { where(issued_on: date..) if date.present? }
  scope :on_or_before,  ->(date)         { where(issued_on: ..date) if date.present? }

  # Issue #, consumer branch, warehouse, or a product's SKU/name on any line.
  scope :search, ->(term) {
    return all if term.blank?

    t = "%#{term.to_s.strip.downcase}%"
    left_joins(:branch, :warehouse).where(
      "LOWER(stock_issues.issue_number) LIKE :t OR LOWER(branches.name) LIKE :t OR LOWER(warehouses.name) LIKE :t OR " \
      "EXISTS (SELECT 1 FROM stock_issue_items sii JOIN products p ON p.id = sii.product_id " \
      "WHERE sii.stock_issue_id = stock_issues.id AND (LOWER(p.sku) LIKE :t OR LOWER(p.name) LIKE :t))",
      t: t
    )
  }

  def total_value
    items.sum(&:total_cost)
  end

  # Compensating movements that undo this issue: return the issued quantity to
  # the warehouse it was taken from.
  def reversal_entries
    items.map do |item|
      { product: item.product, warehouse: warehouse,
        direction: :in, quantity: item.quantity, unit_cost: item.unit_cost }
    end
  end

  private

  def assign_issue_number
    self.issue_number ||= Inventory::NumberSequencer.new(business, :stock_issue).next_number
  end

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
  end

  def branch_in_same_business
    return if branch.nil? || business_id.nil?

    errors.add(:branch, :invalid) if branch.business_id != business_id
  end
end
