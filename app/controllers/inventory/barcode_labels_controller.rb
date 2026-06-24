class Inventory::BarcodeLabelsController < Inventory::BaseController
  layout "barcode_labels"

  # Single-product label sheet
  # GET /inventory/barcode_labels/:id
  def show
    authorize Product, :index?
    @product  = policy_scope(Product).active.includes(:product_barcodes).find(params[:id])
    @barcodes = if params[:barcode_id].present?
                  @product.product_barcodes.where(id: params[:barcode_id])
                else
                  @product.product_barcodes.ordered
                end
    @quantity   = (params[:quantity].presence || 1).to_i.clamp(1, 100)
    @show_price = params[:show_price] != "0"
  end

  # Bulk label sheet for multiple products
  # GET /inventory/barcode_labels?product_ids[]=1&product_ids[]=2
  def index
    authorize Product, :index?
    product_ids = Array(params[:product_ids]).map(&:to_i).uniq.first(100)
    @products   = policy_scope(Product).active.includes(:product_barcodes).where(id: product_ids).ordered
    @quantity   = (params[:quantity].presence || 1).to_i.clamp(1, 20)
    @show_price = params[:show_price] != "0"
  end
end
