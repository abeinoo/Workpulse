# Advance payments on a Purchase Request ("الدفعات المقدمة"). Thin by design:
# authorize, call the service with IDs, redirect. All rules live in
# Inventory::PurchaseRequestAdvanceRecorder (records AND posts the funding — no
# confirmation step) / PurchaseRequestAdvanceWorkflow (reverse; cancel of
# advances still pending from the old two-step workflow).
class Inventory::PurchaseRequestAdvancesController < Inventory::BaseController
  before_action :set_purchase_request

  def new
    @advance = build_advance(paid_on: BusinessDay.current(context: current_user.business), source_kind: nil)
    authorize @advance
    @idempotency_key = SecureRandom.uuid
    load_options
  end

  def create
    authorize build_advance

    result = Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: @purchase_request.id, actor: current_user,
      params: advance_params, idempotency_key: params[:idempotency_key]
    ).call

    if result.ok?
      redirect_to advances_anchor, notice: t("inventory.purchase_request_advances.created")
    else
      @advance = build_advance(**advance_params.to_h.symbolize_keys.slice(:amount, :source_kind, :custody_account_id,
                                                                          :paid_on, :reference, :notes))
      @error = result.error
      @idempotency_key = params[:idempotency_key].presence || SecureRandom.uuid
      load_options
      render :new, status: :unprocessable_content
    end
  end

  def cancel
    advance = find_advance
    authorize advance
    respond_with_result workflow(advance).cancel!(reason: params[:reason]), t("inventory.purchase_request_advances.cancelled")
  end

  def reverse
    advance = find_advance
    authorize advance
    respond_with_result workflow(advance).reverse!(reason: params[:reason]), t("inventory.purchase_request_advances.reversed")
  end

  private

  def set_purchase_request
    @purchase_request = policy_scope(PurchaseRequest).find(params[:purchase_request_id])
    authorize @purchase_request, :show?
  end

  def find_advance
    @purchase_request.advances.find(params[:id])
  end

  # Unsaved — never added to @purchase_request.advances (no autosave risk).
  def build_advance(**attrs)
    PurchaseRequestAdvance.new(business: @purchase_request.business, purchase_request: @purchase_request, **attrs)
  end

  def workflow(advance)
    Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: current_user)
  end

  def respond_with_result(result, ok_message)
    if result.ok?
      redirect_to advances_anchor, notice: ok_message
    else
      redirect_to advances_anchor, alert: result.error
    end
  end

  def advances_anchor = inventory_purchase_request_path(@purchase_request, anchor: "advances")

  def advance_params
    params.require(:purchase_request_advance)
          .permit(:amount, :source_kind, :custody_account_id, :paid_on, :reference, :notes)
  end

  def load_options
    # The accounts the user may pay from, with their ledger balances — decided by
    # Finance & Sales (S2).
    # Every advance funds the request's responsible employee (nil when none is
    # assigned or they are no longer eligible — the form then shows a blocking
    # state). Eligibility and balances are decided by Finance & Sales.
    responsible_id = @purchase_request.responsible_employee_id
    if responsible_id
      @responsible_option = Inventory::PurchaseRequestAdvanceEffects.responsible_employee_options(actor: current_user)
                                                                     .find { |option| option.user_id == responsible_id }
    end
    # Employee custody transfer sources: never the responsible employee's own account.
    @custody_options = Inventory::PurchaseRequestAdvanceEffects.custody_account_options(actor: current_user)
                                                               .reject { |o| o.id == @responsible_option&.custody_account_id }
    # Context only — an advance is not capped by the request total.
    @funded_total = @purchase_request.confirmed_funding_total
  end
end
