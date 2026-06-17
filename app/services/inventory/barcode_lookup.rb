class Inventory::BarcodeLookup
  Result = Struct.new(:product, :variant, :matched_on, keyword_init: true) # matched_on: :barcode | :sku

  def initialize(scope)
    @scope = scope
  end

  def find(code)
    code = code.to_s.strip
    return nil if code.blank?

    # Search ProductBarcode first — barcodes are globally unique so we join back
    # to the product and verify it falls within the policy scope.
    if (pb = ProductBarcode
                .where("LOWER(product_barcodes.barcode) = ?", code.downcase)
                .joins(:product)
                .where(product: @scope)
                .includes(:product_variant)
                .first)
      Result.new(product: pb.product, variant: pb.product_variant, matched_on: :barcode)
    elsif (product = @scope.where("LOWER(sku) = ?", code.downcase).first)
      Result.new(product: product, variant: nil, matched_on: :sku)
    end
  end
end
