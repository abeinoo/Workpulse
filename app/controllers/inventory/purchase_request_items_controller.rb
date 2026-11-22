# The Purchase Request page's item editor (add / edit / delete one line before
# approval). Thin by design: authorize, hand the line to the existing
# Inventory::PurchaseRequestUpdater as items_attributes — which enforces the
# editable state under lock, one line per product, the request's warehouse and
# every item validation, and audits the change — then redirect.
class Inventory::PurchaseRequestItemsController < Inventory::BaseController
  before_action :set_purchase_request

  # PurchaseRequest's nested attributes ignore a line without product_id
  # (reject_if) — so a line always carries it here: a missing product is
  # refused with a message, never "saved" as a silent no-op.
  def create
    return missing_product if line_params["product_id"].blank?

    save({ "0" => line_params }, t("inventory.purchase_requests.item_added"))
  end

  def update
    return missing_product if line_params["product_id"].blank?

    save({ "0" => line_params.merge(id: item.id) }, t("inventory.purchase_requests.item_updated"))
  end

  def destroy
    save({ "0" => { id: item.id, product_id: item.product_id, _destroy: "1" } }, t("inventory.purchase_requests.item_deleted"))
  end

  private

  def set_purchase_request
    @purchase_request = policy_scope(PurchaseRequest).find(params[:purchase_request_id])
    authorize @purchase_request, :edit_items?
  end

  def item
    @purchase_request.items.find(params[:id])
  end

  def line_params
    params.require(:purchase_request).require(:items_attributes).require("0")
          .permit(:product_id, :supplier_id, :quantity, :unit_price, :entered_quantity, :packaging_level_id, :entered_unit_price).to_h
  end

  def missing_product
    redirect_to inventory_purchase_request_path(@purchase_request, anchor: "items"),
                alert: t("inventory.purchase_requests.errors.item_product_required")
  end

  def save(items_attributes, ok_message)
    result = Inventory::PurchaseRequestUpdater.new(
      @purchase_request.id, actor: current_user, attributes: { items_attributes: items_attributes }
    ).call
    flash_key, message = result.ok? ? [ :notice, ok_message ] : [ :alert, result.error ]
    redirect_to inventory_purchase_request_path(@purchase_request, anchor: "items"), flash_key => message
  end
end
