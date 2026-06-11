# Shared JSON lookup used by the barcode-scanner Stimulus controller on every
# inventory document form (goods receipt, stock issue, stock transfer, and later
# stock count / purchase orders / adjustments). Scoped through ProductPolicy so a
# warehouse-restricted user can only resolve products they may already see.
class Inventory::BarcodeLookupsController < Inventory::BaseController
  def show
    authorize Product, :index?

    result = Inventory::BarcodeLookup.new(policy_scope(Product)).find(params[:code])
    if result
      render json: {
        id:         result.product.id,
        name:       result.product.name,
        sku:        result.product.sku,
        barcode:    result.product.barcode,
        matched_on: result.matched_on
      }
    else
      render json: { error: "not_found" }, status: :not_found
    end
  end
end
