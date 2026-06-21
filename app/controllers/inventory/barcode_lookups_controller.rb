# Shared JSON lookup used by the barcode-scanner Stimulus controller on every
# inventory document form (goods receipt, stock issue, stock transfer, and later
# stock count / purchase orders / adjustments). Scoped through ProductPolicy so a
# warehouse-restricted user can only resolve products they may already see.
class Inventory::BarcodeLookupsController < Inventory::BaseController
  def show
    authorize Product, :index?

    result = Inventory::BarcodeLookup.new(policy_scope(Product).active).find(params[:code])
    if result
      product = result.product
      if product.parent?
        render json: { error: "parent_product", name: product.name }, status: :unprocessable_entity
      else
        render json: {
          id:           product.id,
          name:         product.name,
          sku:          product.sku,
          barcode:      product.barcode,
          barcodes:     product.product_barcodes.pluck(:barcode),
          matched_on:   result.matched_on
        }
      end
    else
      render json: { error: "not_found" }, status: :not_found
    end
  end
end
