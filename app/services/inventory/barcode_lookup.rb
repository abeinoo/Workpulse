# Resolves a scanned/typed code to a single product within a caller-supplied
# scope. The scope is whatever set of products the caller already trusts the user
# to see (e.g. policy_scope(Product) or business.products) — keeping this object
# free of any authorization concern and reusable from controllers, importers, and
# future modules (Stock Count, Purchase Orders, Inventory Adjustments).
#
# Matching is exact on barcode first, then falls back to SKU, so a code printed as
# either still resolves. Case-insensitive to mirror the product uniqueness rules.
class Inventory::BarcodeLookup
  Result = Struct.new(:product, :matched_on, keyword_init: true) # matched_on: :barcode | :sku

  def initialize(scope)
    @scope = scope
  end

  def find(code)
    code = code.to_s.strip
    return nil if code.blank?

    if (product = @scope.where("LOWER(barcode) = ?", code.downcase).first)
      Result.new(product: product, matched_on: :barcode)
    elsif (product = @scope.where("LOWER(sku) = ?", code.downcase).first)
      Result.new(product: product, matched_on: :sku)
    end
  end
end
