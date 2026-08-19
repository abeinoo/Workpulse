class Inventory::GoodsReceiptsController < Inventory::BaseController
  def index
    authorize GoodsReceipt
    @filters = filter_params

    @goods_receipts = policy_scope(GoodsReceipt)
                       .for_warehouse(@filters[:warehouse_id])
                       .for_supplier(@filters[:supplier_id])
                       .for_approval_status(@filters[:approval_status])
                       .for_receiving_status(@filters[:receiving_status])
                       .on_or_after(parsed_date(@filters[:date_from]))
                       .on_or_before(parsed_date(@filters[:date_to]))
                       .recent
                       .includes(:supplier, :warehouse)

    @filter_warehouses = accessible_warehouses
    @filter_suppliers  = current_user.business.suppliers.ordered
    @active_filters    = @filters.values.any?(&:present?)
    @filtered_count    = @goods_receipts.count
  end

  def show
    @goods_receipt = find_receipt(
      includes: [ :funding_source, :custody_transactions, :created_by, :decided_by, :confirmed_by, :voided_by ]
    )
    authorize @goods_receipt
    @items           = @goods_receipt.items.includes(:product)
    @settlements     = @goods_receipt.financial_settlements.chronological.includes(:funding_source, :created_by)
    @audit_logs      = AuditLog.for_auditable(@goods_receipt).recent.includes(:actor)
    @timeline_events = build_timeline_events
  end

  def new
    @goods_receipt = current_user.business.goods_receipts.build(received_on: Date.current, funding_source_kind: "employee_custody")
    @goods_receipt.items.build
    authorize @goods_receipt
    load_options
  end

  def create
    @goods_receipt = current_user.business.goods_receipts.build(receipt_params)
    @goods_receipt.created_by = current_user
    assign_funding_source
    authorize @goods_receipt
    ensure_warehouses_accessible!(@goods_receipt.warehouse_id)

    result = Inventory::GoodsReceiptDraftService.new(@goods_receipt, actor: current_user).call
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.created")
    else
      load_options
      @goods_receipt.items.build if @goods_receipt.items.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @goods_receipt = find_receipt
    authorize @goods_receipt
    load_options
  end

  def update
    @goods_receipt = find_receipt
    authorize @goods_receipt
    @goods_receipt.assign_attributes(receipt_params)
    assign_funding_source
    ensure_warehouses_accessible!(@goods_receipt.warehouse_id)

    result = Inventory::GoodsReceiptDraftService.new(@goods_receipt, actor: current_user).call
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.updated")
    else
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def submit
    @goods_receipt = find_receipt
    authorize @goods_receipt, :submit_for_approval?
    result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: @goods_receipt.id, actor: current_user).submit!
    redirect_with_result(result, ok_message: t("inventory.goods_receipts.submitted"))
  end

  def approve
    @goods_receipt = find_receipt
    authorize @goods_receipt, :approve?
    result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: @goods_receipt.id, actor: current_user).approve!
    redirect_with_result(result, ok_message: t("inventory.goods_receipts.approved"))
  end

  def reject
    @goods_receipt = find_receipt
    authorize @goods_receipt, :reject?
    result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: @goods_receipt.id, actor: current_user)
                                            .reject!(reason: params[:rejection_reason])
    redirect_with_result(result, ok_message: t("inventory.goods_receipts.rejected"))
  end

  def confirm
    @goods_receipt = find_receipt
    authorize @goods_receipt, :confirm?
    result = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: @goods_receipt.id, actor: current_user).call
    redirect_with_result(result, ok_message: t("inventory.goods_receipts.confirmed"))
  end

  def void
    @goods_receipt = find_receipt
    authorize @goods_receipt, :void?
    result = Inventory::GoodsReceiptVoider.new(goods_receipt_id: @goods_receipt.id, actor: current_user, reason: params[:void_reason]).call
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.voided")
    else
      redirect_to inventory_goods_receipt_path(@goods_receipt),
                  alert: result.error.presence || @goods_receipt.errors.full_messages.to_sentence.presence || t("inventory.void.failed")
    end
  end

  # Requester self-service cancel of a not-yet-approved receipt — nothing has
  # been posted yet, so this reuses the exact same void machinery as #void
  # (Inventory::GoodsReceiptVoider), just gated by :cancel? instead of :void?
  # and labeled "Cancel Request" in the UI. See GoodsReceiptPolicy#cancel?.
  def cancel
    @goods_receipt = find_receipt
    authorize @goods_receipt, :cancel?
    result = Inventory::GoodsReceiptVoider.new(goods_receipt_id: @goods_receipt.id, actor: current_user, reason: params[:cancellation_reason]).call
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: t("inventory.goods_receipts.cancelled")
    else
      redirect_to inventory_goods_receipt_path(@goods_receipt),
                  alert: result.error.presence || @goods_receipt.errors.full_messages.to_sentence.presence || t("inventory.void.failed")
    end
  end

  private

  def filter_params
    params.permit(:warehouse_id, :supplier_id, :approval_status, :receiving_status, :date_from, :date_to)
  end

  def parsed_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def find_receipt(includes: [])
    policy_scope(GoodsReceipt).includes(includes).find(params[:id])
  end

  def redirect_with_result(result, ok_message:)
    if result.ok?
      redirect_to inventory_goods_receipt_path(@goods_receipt), notice: ok_message
    else
      redirect_to inventory_goods_receipt_path(@goods_receipt), alert: result.error
    end
  end

  def load_options
    @warehouses      = accessible_warehouses
    @suppliers       = current_user.business.suppliers.ordered
    @products        = current_user.business.products.transactable.ordered
    @custody_account = current_user.custody_accounts.active.first
  end

  # Employee Custody always means the acting user's own account — never a
  # selectable employee. Ignoring any client-supplied account id here is what
  # makes "never allow selecting another employee" actually true server-side.
  def assign_funding_source
    return unless @goods_receipt.funding_source_kind == "employee_custody"

    @goods_receipt.funding_source = current_user.custody_accounts.active.first
  end

  def receipt_params
    params.require(:goods_receipt).permit(
      :warehouse_id, :supplier_id, :received_on, :notes, :funding_source_kind, invoices: [],
      items_attributes: [ :id, :product_id, :quantity, :unit_cost, :_destroy ]
    )
  end

  # Builds the show page's Activity Timeline: one entry per event that
  # actually happened, in chronological order. Only :created (created_at is a
  # guaranteed column) and :settled (sourced from @settlements, never from an
  # audit log — settlement creation isn't separately audited) skip the audit
  # log; every decision/lifecycle step is sourced from @audit_logs rather than
  # the receipt's own decided_at/decided_by columns, since those are
  # overwritten on each decision and would lose history across a
  # reject → resubmit → approve cycle. No queries here — everything is
  # already preloaded on @goods_receipt / @audit_logs / @settlements by #show.
  def build_timeline_events
    events = [ { type: :created, time: @goods_receipt.created_at, actor: @goods_receipt.created_by } ]

    @audit_logs.each do |log|
      case log.action
      when "submit_for_approval"
        events << { type: :submitted, time: log.created_at, actor: log.actor }
      when "approve"
        events << { type: :approved, time: log.created_at, actor: log.actor }
      when "reject"
        events << { type: :rejected, time: log.created_at, actor: log.actor, data: log.metadata["reason"] }
      when "confirm"
        events << { type: :received, time: log.created_at, actor: log.actor }
      when "void"
        events << { type: :voided, time: log.created_at, actor: log.actor, data: log.metadata["reason"] }
      end
    end

    # Only the original deduction, never its reversal (a negative amount) —
    # a void already gets its own :voided entry, and reversal-vs-original
    # nuance belongs in the Payment Information ledger, not the headline timeline.
    @settlements.select { |s| s.amount.positive? }.each do |settlement|
      events << { type: :settled, time: settlement.settled_at, actor: settlement.created_by, data: settlement }
    end

    events.sort_by { |event| event[:time] }
  end
end
