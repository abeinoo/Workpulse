# Stock Transfer workflow screens. Orchestration only: every state change goes
# through its Inventory::StockTransfer* service (which re-applies the
# permission, warehouse reach, locks and audit itself) — the controller passes
# the transfer's id, never a loaded record.
class Inventory::StockTransfersController < Inventory::BaseController
  PER_PAGE = 25

  def index
    authorize StockTransfer
    scope    = policy_scope(StockTransfer)
    @history = Inventory::StockTransferHistory.new(scope, params.permit(*Inventory::StockTransferHistory::FILTERS))
    @status_counts = scope.active.group(:status).count
    filtered = @history.relation.recent
    @total_filtered = filtered.count
    @total_pages    = [ (@total_filtered.to_f / PER_PAGE).ceil, 1 ].max
    @page           = params[:page].to_i.clamp(1, @total_pages)
    @stock_transfers = filtered.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)
                               .includes({ source_warehouse: :branch }, { destination_warehouse: :branch },
                                         :created_by, :approved_by, :dispatched_by, :items, :receipts)
    @filter_warehouses = accessible_warehouses
    @filter_people     = current_user.business.users.where(id: people_ids(scope)).order(:first_name, :last_name)
    pending_stock_transfer_approvals_count # shared with the workspace badge: one count per request
  end

  def show
    @stock_transfer = find_transfer
    authorize @stock_transfer
    @items = @stock_transfer.items.includes(product: [ :product_barcodes, Product::IMAGE_PRELOAD ]).sort_by(&:id)
    @receipts    = @stock_transfer.receipts.includes(:received_by, lines: { stock_transfer_item: :product }).order(:received_at, :id).to_a
    @resolutions = @stock_transfer.resolutions.includes(:resolved_by, stock_transfer_item: :product).order(:resolved_at, :id).to_a
    @audit_logs  = AuditLog.for_auditable(@stock_transfer).includes(:actor).order(:created_at, :id).to_a
    @timeline    = Inventory::StockTransferTimeline.new(@stock_transfer, audit_logs: @audit_logs,
                                                        receipts: @receipts, resolutions: @resolutions).events
    @products_by_id = @items.to_h { |item| [ item.product_id, item.product ] }
    # Lines of the original request (the durable submission snapshot) an
    # approver removed — shown as removed on the review screen.
    submitted = @audit_logs.reverse.find { |log| log.action == "submit_for_approval" }
    requested = Array(submitted&.metadata&.dig("requested_lines")).index_by { |line| line["product_id"].to_i }
    removed_ids = requested.keys - @items.map(&:product_id)
    @removed_lines = Product.where(id: removed_ids).map { |product| [ product, requested[product.id]["quantity"] ] }
    @progress = Inventory::StockTransferProgress.for(@stock_transfer, items: @items) if @stock_transfer.via_transit? && @stock_transfer.dispatched?
    if @stock_transfer.editable? || @stock_transfer.awaiting_dispatch?
      @availability_lines = Inventory::StockAvailability.transfer_lines_for(@stock_transfer).index_by { |line| line.product.id }
    end
  end

  def new
    @stock_transfer = current_user.business.stock_transfers.build(
      transferred_on: BusinessDay.current(context: current_user.business)
    )
    @stock_transfer.items.build
    authorize @stock_transfer
    load_options
  end

  def create
    authorize StockTransfer, :create?
    # Same controller-level guard as before the workflow (the service re-checks).
    ensure_warehouses_accessible!(transfer_params[:source_warehouse_id], transfer_params[:destination_warehouse_id])
    result = Inventory::StockTransferDraftService.new(actor: current_user, attributes: transfer_params).call
    if result.ok?
      if params[:submit_after_save].present? && policy(result.transfer).submit?
        submitted = Inventory::StockTransferSubmission.new(stock_transfer_id: result.transfer.id, actor: current_user).call
        return redirect_to inventory_stock_transfer_path(result.transfer),
                           (submitted.ok? ? { notice: t("inventory.stock_transfers.submitted") } : { alert: submitted.error })
      end
      redirect_to inventory_stock_transfer_path(result.transfer), notice: t("inventory.stock_transfers.draft_saved")
    else
      @stock_transfer = result.transfer
      surface_error(result)
      load_options
      @stock_transfer.items.build if @stock_transfer.items.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @stock_transfer = find_transfer
    authorize @stock_transfer, editing_permission(@stock_transfer)
    load_options
  end

  def update
    @stock_transfer = find_transfer
    authorize @stock_transfer, editing_permission(@stock_transfer)
    result =
      if @stock_transfer.pending_approval?
        Inventory::StockTransferEditor.new(stock_transfer_id: @stock_transfer.id, actor: current_user,
                                           attributes: pending_params, lock_token: params[:lock_token]).call
      else
        ensure_warehouses_accessible!(transfer_params[:source_warehouse_id] || @stock_transfer.source_warehouse_id,
                                      transfer_params[:destination_warehouse_id] || @stock_transfer.destination_warehouse_id)
        Inventory::StockTransferDraftService.new(stock_transfer_id: @stock_transfer.id, actor: current_user,
                                                 attributes: transfer_params, lock_token: params[:lock_token]).call
      end

    if result.ok?
      if params[:submit_after_save].present? && result.transfer.draft? && policy(result.transfer).submit?
        submitted = Inventory::StockTransferSubmission.new(stock_transfer_id: result.transfer.id, actor: current_user).call
        return redirect_to inventory_stock_transfer_path(result.transfer),
                           (submitted.ok? ? { notice: t("inventory.stock_transfers.submitted") } : { alert: submitted.error })
      end
      redirect_to inventory_stock_transfer_path(result.transfer), notice: t("inventory.stock_transfers.updated")
    else
      @stock_transfer = result.transfer
      surface_error(result)
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def submit
    transition(:submit?, t("inventory.stock_transfers.submitted")) do |transfer|
      Inventory::StockTransferSubmission.new(stock_transfer_id: transfer.id, actor: current_user).call
    end
  end

  def approve
    transition(:approve?, nil) do |transfer|
      Inventory::StockTransferApproval.new(stock_transfer_id: transfer.id, actor: current_user).call
    end
  end

  def reject
    transition(:reject?, t("inventory.stock_transfers.rejected")) do |transfer|
      Inventory::StockTransferRejection.new(stock_transfer_id: transfer.id, actor: current_user,
                                            reason: params[:rejection_reason]).call
    end
  end

  def cancel
    transition(:cancel?, t("inventory.stock_transfers.cancelled")) do |transfer|
      Inventory::StockTransferCancellation.new(stock_transfer_id: transfer.id, actor: current_user,
                                               reason: params[:cancellation_reason]).call
    end
  end

  def dispatch_goods
    transition(:dispatch?, t("inventory.stock_transfers.dispatched")) do |transfer|
      Inventory::StockTransferDispatch.new(stock_transfer_id: transfer.id, actor: current_user).call
    end
  end

  def receive
    transition(:receive?, nil) do |transfer|
      Inventory::StockTransferReceiving.new(stock_transfer_id: transfer.id, actor: current_user,
                                            quantities: line_params(:receive, transfer).to_h,
                                            notes: params[:receipt_notes], close_shortfall: params[:close_shortfall]).call
    end
  end

  def resolve
    transition(:resolve?, nil) do |transfer|
      Inventory::StockTransferDiscrepancyResolution.new(stock_transfer_id: transfer.id, actor: current_user,
                                                        entries: line_params(:resolve, transfer, nested: StockTransferResolution::KINDS).to_h,
                                                        reason: params[:resolution_reason]).call
    end
  end

  def void
    @stock_transfer = find_transfer
    authorize @stock_transfer, :void?
    result = Inventory::DocumentVoider.new(@stock_transfer, user: current_user, reason: params[:void_reason]).call
    if result.ok?
      redirect_to inventory_stock_transfer_path(@stock_transfer), notice: t("inventory.stock_transfers.voided")
    else
      redirect_to inventory_stock_transfer_path(@stock_transfer),
                  alert: @stock_transfer.errors.full_messages.to_sentence.presence || t("inventory.void.failed")
    end
  end

  # Live figures for the transfer form / a pending transfer: per product,
  # source on hand / reserved (by OTHER documents) / available, destination
  # on hand and incoming. Read-only; both warehouses must be reachable.
  def availability
    authorize StockTransfer, :availability?
    source_id, destination_id = reachable_ends!
    product_ids = current_user.business.products.where(id: Array(params[:product_ids])).pluck(:id)
    excluding   = (find_transfer(params[:stock_transfer_id]).id if params[:stock_transfer_id].present?)
    render json: { products: availability_rows(source_id, destination_id, product_ids, excluding) }
  end

  # "Get Low-Stock Products": the destination's replenishment suggestions,
  # capped by the source's available stock (Inventory::TransferReplenishment).
  # Rendered as the modal's body; nothing is created.
  def replenishment
    authorize StockTransfer, :create?
    source_id, destination_id = reachable_ends!
    raise ActionController::ParameterMissing, :destination_warehouse_id if destination_id.nil?

    @suggestions = Inventory::TransferReplenishment.new(business: current_user.business, source_warehouse_id: source_id,
                                                         destination_warehouse_id: destination_id).suggestions
    preload_product_images(@suggestions.map(&:product))
    render partial: "replenishment", locals: { suggestions: @suggestions }
  end

  private

  def find_transfer(id = params[:id])
    policy_scope(StockTransfer).find(id)
  end

  # Operation-permission screens: any transfer permission admits the user
  # without the inventory view; each action still authorizes itself.
  def admitted_without_inventory_view? = Inventory::StockTransferAuthorization.any?(current_user)

  def editing_permission(transfer) = transfer.pending_approval? ? :edit_pending? : :update?

  # Both ends from the request, checked like any warehouse choice: of the
  # user's business, operational (never the transit warehouse) and reached.
  def reachable_ends!
    source_id      = params.require(:source_warehouse_id)
    destination_id = params[:destination_warehouse_id].presence
    ensure_warehouses_accessible!(source_id, destination_id)
    raise Pundit::NotAuthorizedError unless Inventory::WarehouseReach.permits?(current_user, *[ source_id, destination_id ].compact)

    [ source_id.to_i, destination_id&.to_i ]
  end

  def transition(permission, notice)
    @stock_transfer = find_transfer
    authorize @stock_transfer, permission
    result = yield(@stock_transfer)
    if result.ok?
      redirect_to inventory_stock_transfer_path(@stock_transfer), notice: notice || outcome_notice(result.transfer)
    else
      redirect_to inventory_stock_transfer_path(@stock_transfer), alert: result.error
    end
  end

  # The notice of a step whose outcome depends on the transfer's new status.
  def outcome_notice(transfer)
    t("inventory.stock_transfers.outcomes.#{transfer.status}", default: t("inventory.stock_transfers.updated"))
  end

  # Per-line quantities keyed by the transfer's OWN line ids only (any other
  # key is dropped); nested: the allowed sub-keys of each line.
  def line_params(key, transfer, nested: nil)
    ids = transfer.items.ids.map(&:to_s)
    allowed = nested ? ids.map { |id| { id => nested } } : ids
    params.fetch(key, ActionController::Parameters.new).permit(*allowed)
  end

  def surface_error(result)
    return if result.error.blank? || @stock_transfer.errors.full_messages.include?(result.error)

    @stock_transfer.errors.add(:base, result.error)
  end

  def availability_rows(source_id, destination_id, product_ids, excluding_transfer_id)
    return [] if product_ids.empty?

    on_hand  = Inventory::StockAvailability.on_hand_by(warehouse_ids: [ source_id, destination_id ].compact, product_ids: product_ids)
    reserved = Inventory::StockAvailability.reserved_by(warehouse_ids: source_id, product_ids: product_ids,
                                                        excluding_transfer_id: excluding_transfer_id)
    incoming = if destination_id
                 Inventory::TransferIncoming.by_product(business_id: current_user.business_id, warehouse_id: destination_id,
                                                        product_ids: product_ids)
    else
                 {}
    end
    product_ids.map do |id|
      source_on_hand = on_hand[[ source_id, id ]].to_d
      held           = reserved[[ source_id, id ]].to_d
      { product_id: id,
        source_on_hand: source_on_hand.to_s("F"), source_reserved: held.to_s("F"),
        source_available: [ source_on_hand - held, 0 ].max.to_s("F"),
        destination_on_hand: (on_hand[[ destination_id, id ]].to_d.to_s("F") if destination_id),
        destination_incoming: (incoming[id].to_d.to_s("F") if destination_id) }
    end
  end

  # Everyone who requested, approved, dispatched or received one of the
  # visible transfers — the "person" filter's choices.
  def people_ids(scope)
    ids = scope.pluck(:created_by_id, :approved_by_id, :dispatched_by_id).flatten
    ids += StockTransferReceipt.where(stock_transfer_id: scope.select(:id)).distinct.pluck(:received_by_id)
    ids.compact.uniq
  end

  def load_options
    @warehouses = accessible_warehouses.includes(:branch)
    # Line pickers search the catalogue on demand; only each line's product is rendered.
    preload_line_products(@stock_transfer&.items)
  end

  # The request date is not a user input: a draft carries the current
  # Business Day; dispatch (or a direct transfer's approval) sets the posting day.
  def transfer_params
    params.require(:stock_transfer).permit(
      :source_warehouse_id, :destination_warehouse_id, :notes,
      items_attributes: [ :id, :product_id, :quantity, :_destroy ]
    )
  end

  # An approver edits lines and notes only; the warehouses are fixed.
  def pending_params
    params.require(:stock_transfer).permit(
      :source_warehouse_id, :destination_warehouse_id, :notes,
      items_attributes: [ :id, :product_id, :quantity, :_destroy ]
    )
  end
end
