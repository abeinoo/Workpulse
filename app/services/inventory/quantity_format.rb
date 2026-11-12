module Inventory
  # The one display convention for inventory quantities (stock count CSV,
  # screens, audit metadata): whole numbers without a trailing ".0",
  # fractional quantities with their exact decimals — never rounded or
  # truncated (a ledger on-hand of 4.004 shows as "4.004").
  module QuantityFormat
    module_function

    def plain(value)
      return nil if value.nil?

      d = value.to_d
      d.frac.zero? ? d.to_i.to_s : d.to_s("F")
    end

    # "+2", "-1.004", "0".
    def signed(value)
      return nil if value.nil?

      "#{'+' if value.to_d.positive?}#{plain(value)}"
    end
  end
end
