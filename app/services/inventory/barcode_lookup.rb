class Inventory::BarcodeLookup
  Result = Struct.new(:product, :matched_on, keyword_init: true) # matched_on: :barcode | :sku

  def initialize(scope)
    @scope = scope
  end

  def find(code)
    code = code.to_s.strip
    return nil if code.blank?

    if (pb = ProductBarcode
                .where("LOWER(product_barcodes.barcode) = ?", code.downcase)
                .joins(:product)
                .where(product: @scope)
                .first)
      Result.new(product: pb.product, matched_on: :barcode)
    elsif (product = @scope.where("LOWER(sku) = ?", code.downcase).first)
      Result.new(product: product, matched_on: :sku)
    end
  end
end
