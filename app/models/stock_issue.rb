class StockIssue < ApplicationRecord
  include ImmutableDocument
  include Voidable

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

  validates :issue_number, presence: true,
                          uniqueness: { scope: :business_id, case_sensitive: false }
  validates :issued_on, presence: true
  validates :branch_id, presence: true, on: :create
  validate  :has_at_least_one_item
  validate  :branch_in_same_business

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(issued_on: :desc, id: :desc) }

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

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
  end

  def branch_in_same_business
    return if branch.nil? || business_id.nil?

    errors.add(:branch, :invalid) if branch.business_id != business_id
  end
end
