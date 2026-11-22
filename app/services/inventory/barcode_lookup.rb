# Resolves a scanned / typed code to ONE product of an already-authorized
# product scope: any of the product's barcodes (primary or additional, every
# barcode type), else its SKU. Barcodes are matched exactly as stored and
# compared (ProductBarcode.normalize / comparison_key) within the business —
# the (business_id, LOWER(barcode)) unique index, so one row at most.
class Inventory::BarcodeLookup
  Result = Struct.new(:product, :matched_on, keyword_init: true) # matched_on: :barcode | :sku

  def initialize(scope, business_id:)
    @scope       = scope
    @business_id = business_id
  end

  def find(code)
    key = ProductBarcode.comparison_key(code)
    return nil if key.nil?

    if (pb = ProductBarcode.where(business_id: @business_id).matching(code)
                           .joins(:product).merge(@scope).includes(:product).first)
      Result.new(product: pb.product, matched_on: :barcode)
    elsif (product = @scope.where(business_id: @business_id).find_by("LOWER(products.sku) = ?", key))
      Result.new(product: product, matched_on: :sku)
    end
  end
end
