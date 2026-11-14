# JSON search behind the searchable product pickers (product-combobox): name,
# SKU or barcode, scoped by ProductPolicy (business isolation) and the
# picker's kind (Inventory::ProductPickerSearch). Read-only; at most 20 rows.
class Inventory::ProductSearchesController < Inventory::BaseController
  def index
    authorize Product, :index?
    kind = params[:kind].presence || "transactable"
    return head(:bad_request) unless Inventory::ProductPickerSearch.kind?(kind)

    products = Inventory::ProductPickerSearch.new(policy_scope(Product), kind: kind).call(params[:q])
    render json: products.map { |product| product_picker_json(product) }
  end
end
