# A document line entered in a unit of the product's packaging (a level, e.g.
# "3 boxes") or in its base unit (packaging_level nil). `quantity` stays the
# canonical base quantity every stock, reservation and over-receipt check
# reads; `entered_quantity` + `packaging_level` record what the user entered
# (docs/inventory/multi_unit_nested_packaging_design.md §7).
#
# When entered_quantity is given, quantity is derived from it
# (entered × the level's base quantity); callers that only set `quantity`
# (imports, older code paths) keep working unchanged as base-unit lines.
module PackagedLine
  extend ActiveSupport::Concern

  included do
    belongs_to :packaging_level, class_name: "ProductPackagingLevel", optional: true

    before_validation :derive_base_quantity
    validate :packaging_level_matches_product
    validate :package_count_is_whole
  end

  def package_line? = packaging_level_id.present?

  # The amount in the unit the user chose (base lines: the base quantity).
  def unit_quantity = entered_quantity.presence || quantity

  private

  def derive_base_quantity
    return if entered_quantity.blank?

    level = packaging_level
    self.quantity = level ? entered_quantity.to_d * level.base_quantity.to_d : entered_quantity.to_d
  end

  def packaging_level_matches_product
    return if packaging_level.nil?

    if packaging_level.product_id != product_id
      errors.add(:packaging_level_id, :invalid)
    elsif !packaging_level.active? && will_save_change_to_packaging_level_id?
      errors.add(:packaging_level_id, :retired)
    end
  end

  def package_count_is_whole
    return if packaging_level.nil? || entered_quantity.blank?

    errors.add(:entered_quantity, :not_whole_packages) unless entered_quantity.to_d == entered_quantity.to_d.truncate
  end
end
