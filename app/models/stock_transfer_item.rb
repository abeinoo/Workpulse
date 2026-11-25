class StockTransferItem < ApplicationRecord
  # Dispatch values each line at the dispatch-time average (unit_cost /
  # total_cost) while the transfer is still awaiting_dispatch; the quantities
  # themselves are fixed from approval on.
  DISPATCH_VALUATION_ATTRIBUTES = %w[unit_cost total_cost updated_at].freeze

  belongs_to :stock_transfer, inverse_of: :items
  belongs_to :product
  has_many :receipt_lines, class_name: "StockTransferReceiptLine", dependent: :restrict_with_exception
  has_many :resolutions,   class_name: "StockTransferResolution",  dependent: :restrict_with_exception

  validates :requested_quantity, numericality: { greater_than: 0 }, allow_nil: true

  has_one :business, through: :stock_transfer

  validates :quantity, numericality: { greater_than: 0 }
  validate  :product_in_same_business, if: :will_save_change_to_product_id?
  validate  :transfer_still_editable

  # Lines are part of the request until the transfer is decided: a posted,
  # rejected or cancelled transfer's lines are history (StockTransfer::EDITABLE_STATUSES).
  before_destroy :prevent_destroy_after_decision

  # Line product ids come straight from form params — never trust one that
  # belongs to another business (IP-1).
  def product_in_same_business
    return if product.nil? || stock_transfer.nil? || stock_transfer.business_id.nil?

    errors.add(:product_id, :other_business) if product.business_id != stock_transfer.business_id
  end

  before_validation :compute_total_cost

  private

  def compute_total_cost
    self.unit_cost ||= 0
    self.total_cost = quantity.to_d * unit_cost.to_d if quantity && unit_cost
  end

  def parent_editable?
    return true if stock_transfer.nil? || stock_transfer.new_record?

    StockTransfer::EDITABLE_STATUSES.include?(stock_transfer.status_in_database)
  end

  def transfer_still_editable
    return unless new_record? || has_changes_to_save?
    return if parent_editable?
    return if persisted? && stock_transfer.status_in_database == "awaiting_dispatch" &&
              (changes_to_save.keys - DISPATCH_VALUATION_ATTRIBUTES).empty?

    errors.add(:base, :transfer_locked)
  end

  def prevent_destroy_after_decision
    return if parent_editable?

    errors.add(:base, :transfer_locked)
    throw :abort
  end
end
