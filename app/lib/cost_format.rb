# Display text for costs (Decisions 11 and 18; docs/inventory/multi_unit_nested_packaging_design.md §12).
# Formatting only: stored precision, calculations and money rounding are
# never changed by it.
#
#   unit("25.00000000") => "25"     unit("25.5")       => "25.5"
#   unit("0.70400000")  => "0.704"  unit("0.00000125") => "0.00000125"
#
# Fixed-point always (BigDecimal#to_s("F")), never scientific notation; the
# same text in screens, reports, CSV exports and audit displays.
module CostFormat
  module_function

  def unit(value)
    return nil if value.nil?

    text = value.to_d.round(8).to_s("F")
    text = text.sub(/\.?0+\z/, "") if text.include?(".")
    text == "-0" ? "0" : text
  end

  # Fixed-point text for a CSV cell (no scientific notation): unit costs
  # keep up to 8 dp, money and quantities keep their own precision.
  def csv(value, scale: 8)
    return nil if value.nil?

    unit(value.to_d.round(scale))
  end
end
