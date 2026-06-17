module Inventory
  # Generates sequential internal barcodes for products that don't have a
  # manufacturer-assigned code.  Internal codes are numeric, starting from
  # INTERNAL_START, and are globally unique (enforced by the DB index).
  class BarcodeGenerator
    INTERNAL_START = 10_000_001

    # Returns the next available internal barcode string without persisting it.
    # Safe to call for display/form pre-fill; the caller is responsible for
    # uniqueness on save (the DB index will reject collisions).
    def self.next_code
      last = ProductBarcode
               .where(barcode_type: "internal")
               .where("barcode ~ '^[0-9]+$'")
               .maximum("CAST(barcode AS BIGINT)")
      ([ last.to_i, INTERNAL_START - 1 ].max + 1).to_s
    end
  end
end
