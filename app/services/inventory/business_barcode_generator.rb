module Inventory
  # Generates a unique, business-scoped internal barcode and persists it as the
  # primary ProductBarcode for the given product.
  #
  # Barcode format:  "#{prefix}#{zero-padded-sequence}"
  # e.g. prefix="PRD", next_number=42  →  "PRD000042"
  # e.g. prefix=nil,   next_number=1   →  "000001"
  #
  # Atomicity guarantee:
  #   The business row is locked (SELECT FOR UPDATE) for the duration of the
  #   block so that concurrent product creates in the same business cannot
  #   draw the same sequence number. The sequence counter advances to the
  #   number *after* the one actually used, skipping any that were already
  #   taken by a manually-entered barcode with the same value.
  #
  # Must be called inside an existing transaction (Product#after_create already
  # provides one; the with_lock nested call is a no-op savepoint on PostgreSQL).
  class BusinessBarcodeGenerator
    PAD_WIDTH = 6

    def initialize(business)
      @business = business
    end

    # Creates a primary ProductBarcode on +product+ and advances the sequence.
    # Raises ActiveRecord::RecordInvalid if the barcode cannot be saved.
    def call(product)
      @business.with_lock do
        n      = @business.barcode_next_number
        prefix = @business.barcode_prefix.to_s.strip

        n = skip_taken(n, prefix)
        code = format_code(prefix, n)

        product.product_barcodes.create!(
          barcode:      code,
          barcode_type: "internal",
          is_primary:   true
        )

        @business.update_columns(barcode_next_number: n + 1)
      end
    end

    private

    # Advance n until the formatted candidate is not already used in this business.
    def skip_taken(n, prefix)
      loop do
        return n unless taken?(format_code(prefix, n))
        n += 1
      end
    end

    def format_code(prefix, n)
      "#{prefix}#{n.to_s.rjust(PAD_WIDTH, '0')}"
    end

    def taken?(code)
      ProductBarcode
        .joins(:product)
        .where(product: { business: @business })
        .where("LOWER(product_barcodes.barcode) = ?", code.downcase)
        .exists?
    end
  end
end
