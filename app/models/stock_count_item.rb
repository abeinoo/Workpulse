class StockCountItem < ApplicationRecord
  # Where a counted quantity came from (see Inventory::StockCountRecorder and
  # Inventory::StockCountCompletion):
  #   physical — entered by a counter; counted_at is the entry time and
  #              system_quantity the ledger quantity read at that same moment.
  #   system   — not recounted on a legacy count: the ledger quantity at the
  #              completion cutoff was adopted (difference 0). Never a physical
  #              count.
  #   nil      — not counted, or a legacy quantity entered before per-product
  #              count times existed (see #legacy_unverified?).
  QUANTITY_SOURCES = %w[physical system].freeze

  belongs_to :stock_count
  belongs_to :product

  has_one :business, through: :stock_count

  # A counted quantity entered by a person is whole units only; blank (nil)
  # means "not counted yet". (only_integer can't be used: the value lives in a
  # decimal column, so it comes back as BigDecimal "n.0" and the integer
  # string-regex would reject every value; we instead reject genuinely
  # fractional inputs while accepting whole values.)
  #
  # A system-derived row holds the ledger on-hand adopted at completion (D9),
  # which can be fractional (e.g. 4.004 after a 0.004 receipt). It is kept
  # exactly — never rounded — so the whole-number rule does not apply to it.
  validates :counted_quantity, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate  :counted_quantity_is_whole, unless: :system_derived?
  validates :product_id, uniqueness: { scope: :stock_count_id }
  validates :quantity_source, inclusion: { in: QUANTITY_SOURCES }, allow_nil: true
  validate  :product_is_transactable
  validate  :product_in_same_business, if: :will_save_change_to_product_id?

  def product_is_transactable
    return unless product
    errors.add(:product_id, :parent_not_allowed) if Product.where(parent_product_id: product.id).exists?
  end

  # Line product ids (including rows the barcode scanner adds) come straight
  # from form params — never trust one that belongs to another business (IP-1).
  def product_in_same_business
    return if product.nil? || stock_count.nil? || stock_count.business_id.nil?

    errors.add(:product_id, :other_business) if product.business_id != stock_count.business_id
  end

  before_validation :compute_difference

  # A row is "counted" once a quantity has been entered — including an explicit
  # zero. A blank (nil) counted quantity means it has not been counted yet.
  def counted?
    !counted_quantity.nil?
  end

  def physical? = quantity_source == "physical"
  def system_derived? = quantity_source == "system"

  # A quantity entered before per-product count times existed: kept as
  # history, never trusted as a physical count (decisions D8/D9).
  def legacy_unverified?
    counted? && quantity_source.nil?
  end

  private

  def counted_quantity_is_whole
    return if counted_quantity.nil?
    errors.add(:counted_quantity, :not_an_integer) unless counted_quantity == counted_quantity.to_i
  end

  # difference = counted − system (nil while uncounted). For a physical row the
  # system quantity is the ledger quantity at the row's count time, so the
  # difference is exactly what the approval posts — movements after the count
  # are left as they are.
  def compute_difference
    self.system_quantity ||= 0
    self.difference = counted? ? counted_quantity.to_d - system_quantity.to_d : nil
  end
end
