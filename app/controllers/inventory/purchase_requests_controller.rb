class Inventory::PurchaseRequestsController < Inventory::BaseController
  PER_PAGE = 25

  # Never counted as "active" purchasing — a request that was turned down or
  # withdrawn shouldn't inflate the summary cards or the "إجمالي الطلبات" total.
  # partially_closed still counts: it's a real, settled outcome of an active
  # request, not a rejection/cancellation of the request itself.
  ACTIVE_STATUSES = %w[draft pending_approval approved partially_received partially_closed fully_received].freeze

  def index
    authorize PurchaseRequest
    @filters = filter_params

    filtered = policy_scope(PurchaseRequest)
               .for_supplier(@filters[:supplier_id])
               .for_status(@filters[:status])
               .for_receiving_status(@filters[:receiving_status])
               .for_creator(@filters[:created_by_id])
               .on_or_after(parsed_date(@filters[:date_from]))
               .on_or_before(parsed_date(@filters[:date_to]))
               .search(@filters[:q])
               .then { |scope| @filters[:needs_action] == "1" ? scope.needs_action : scope }
               .recent

    @total_filtered = filtered.count
    @page            = [ params[:page].to_i, 1 ].max
    @total_pages     = [ (@total_filtered.to_f / PER_PAGE).ceil, 1 ].max
    @page            = @total_pages if @page > @total_pages

    @purchase_requests = filtered
                        .limit(PER_PAGE)
                        .offset((@page - 1) * PER_PAGE)
                        .includes(:supplier, :created_by, items: { goods_receipt_items: :goods_receipt })

    @filter_suppliers = current_user.business.suppliers.ordered
    @filter_creators  = current_user.business.users.order(:first_name, :last_name)
    @active_filters   = @filters.values.any?(&:present?)

    # Summary cards reflect the business-wide picture (this user's scope),
    # never the current filters — same convention as the dashboard's other
    # summary figures. rejected/cancelled are deliberately excluded from
    # "active" per the business rule above.
    counts_by_status = policy_scope(PurchaseRequest).group(:status).count
    @status_counts   = PurchaseRequest.statuses.keys.index_with { |s| counts_by_status[s] || 0 }
    @active_count    = ACTIVE_STATUSES.sum { |s| @status_counts[s] }

    # Highlights the batch just created by #create (see the redirect below) —
    # not a separate concept from the regular listing, just which rows to
    # call out at the top of the same page.
    @just_created = policy_scope(PurchaseRequest).where(id: created_ids).includes(:supplier, :items) if created_ids.any?
  end

  def show
    @purchase_request = policy_scope(PurchaseRequest)
                        .includes(:supplier, :created_by, :submitted_by, :approved_by, :rejected_by, :cancelled_by,
                                  items: [ :product, { goods_receipt_items: :goods_receipt } ],
                                  goods_receipts: :items)
                        .find(params[:id])
    authorize @purchase_request
    load_advances
  end

  # The general "إنشاء طلب شراء" form — any transactable product, low stock or
  # not. Low Stock is offered inside the form only as a convenience source of
  # lines (see _low_stock_picker), never as a precondition. Notes belong to the
  # request; every line needs an explicit, accessible destination warehouse.
  def new
    authorize PurchaseRequest
    @purchase_request = PurchaseRequest.new
    @purchase_request.items.build
    @idempotency_key = SecureRandom.uuid
    load_new_form_options
  end

  # Two entry points share this action and the same service:
  #   - purchase_request[...] — the general form above (one supplier, one request)
  #   - items[]               — the Low Stock Alerts review modal (one request per supplier)
  def create
    authorize PurchaseRequest
    params.key?(:purchase_request) ? create_from_form : create_from_low_stock_selection
  end

  def edit
    @purchase_request = find_request
    authorize @purchase_request, :update?
    @purchase_request.items.build if @purchase_request.items.empty?
    load_options
  end

  def update
    @purchase_request = find_request
    authorize @purchase_request, :update?

    result = Inventory::PurchaseRequestUpdater.new(
      @purchase_request.id, actor: current_user, attributes: purchase_request_update_params
    ).call

    if result.ok?
      redirect_to inventory_purchase_request_path(result.purchase_request), notice: t("inventory.purchase_requests.updated")
    else
      @purchase_request = result.purchase_request
      @purchase_request.items.build if @purchase_request.items.empty?
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @purchase_request = find_request
    authorize @purchase_request
    @purchase_request.destroy
    redirect_to inventory_purchase_requests_path, notice: t("inventory.purchase_requests.deleted")
  rescue ImmutableDocument::DeletionNotAllowedError
    redirect_to inventory_purchase_request_path(@purchase_request), alert: t("inventory.purchase_requests.errors.invalid_transition")
  end

  def submit
    @purchase_request = find_request
    authorize @purchase_request, :submit_for_approval?
    result = Inventory::PurchaseRequestApproval.new(purchase_request_id: @purchase_request.id, actor: current_user).submit!
    redirect_with_result(result, ok_message: t("inventory.purchase_requests.submitted"))
  end

  def approve
    @purchase_request = find_request
    authorize @purchase_request, :approve?
    result = Inventory::PurchaseRequestApproval.new(purchase_request_id: @purchase_request.id, actor: current_user).approve!
    redirect_with_result(result, ok_message: t("inventory.purchase_requests.approved"))
  end

  def reject
    @purchase_request = find_request
    authorize @purchase_request, :reject?
    result = Inventory::PurchaseRequestApproval.new(purchase_request_id: @purchase_request.id, actor: current_user)
                                                .reject!(reason: params[:rejection_reason])
    redirect_with_result(result, ok_message: t("inventory.purchase_requests.rejected"))
  end

  def cancel
    @purchase_request = find_request
    authorize @purchase_request, :cancel?
    result = Inventory::PurchaseRequestCancellation.new(purchase_request_id: @purchase_request.id, actor: current_user,
                                                        reason: params[:cancellation_reason]).call
    redirect_with_result(result, ok_message: t("inventory.purchase_requests.cancelled"))
  end

  def close_remaining
    @purchase_request = find_request
    authorize @purchase_request, :close_remaining?
    result = Inventory::PurchaseRequestRemainingCloser.new(purchase_request_id: @purchase_request.id, actor: current_user,
                                                           reason: params[:close_remaining_reason]).call
    redirect_with_result(result, ok_message: t("inventory.purchase_requests.remaining_closed"))
  end

  # "اعتماد الطلبات المحددة" — all-or-nothing; every state/self-approval
  # check is re-done server-side under lock by the service. Redirects back to
  # the same filtered/paginated list so the counters and rows refresh.
  def bulk_approve
    authorize PurchaseRequest, :bulk_approve?

    result = Inventory::PurchaseRequestBulkApproval.new(
      purchase_request_ids: Array(params[:purchase_request_ids]), actor: current_user
    ).call

    respond_to do |format|
      format.html do
        redirect_back fallback_location: inventory_purchase_requests_path, **bulk_approve_flash(result)
      end
      format.json do
        if result.ok?
          render json: { success: true, approved_count: result.approved_count,
                         total_amount: ActiveSupport::NumberHelper.number_to_rounded(result.total_amount, precision: 2) }
        else
          render json: { success: false, error: result.error }, status: :unprocessable_content
        end
      end
    end
  end

  private

  def bulk_approve_flash(result)
    return { alert: result.error } unless result.ok?

    { notice: t("inventory.purchase_requests.bulk_approved",
                count: result.approved_count, total: helpers.format_currency(result.total_amount)) }
  end

  def create_from_low_stock_selection
    result = Inventory::PurchaseRequestCreator.new(
      current_user.business,
      actor:            current_user,
      items:            purchase_request_items_params,
      source:           PurchaseRequest::SOURCE_LOW_STOCK_ALERT,
      idempotency_key:  params[:idempotency_key]
    ).call

    if result.ok?
      redirect_to inventory_purchase_requests_path(created_ids: result.purchase_requests.map(&:id).join(",")),
                  notice: t("inventory.purchase_requests.created", count: result.purchase_requests.size)
    else
      redirect_to inventory_root_path, alert: result.error
    end
  end

  def create_from_form
    attrs = purchase_request_form_params
    lines = form_lines(attrs)

    result = Inventory::PurchaseRequestCreator.new(
      current_user.business,
      actor:            current_user,
      items:            lines.map { |line| line.merge(supplier_id: attrs[:supplier_id]) },
      notes:            attrs[:notes],
      require_warehouse: true,
      idempotency_key:  params[:idempotency_key]
    ).call

    if result.ok?
      redirect_to inventory_purchase_requests_path(created_ids: result.purchase_requests.map(&:id).join(",")),
                  notice: t("inventory.purchase_requests.created", count: result.purchase_requests.size)
    else
      @purchase_request = PurchaseRequest.new(supplier_id: attrs[:supplier_id], notes: attrs[:notes])
      lines.each { |line| @purchase_request.items.build(line) }
      @purchase_request.items.build if @purchase_request.items.empty?
      @purchase_request.errors.add(:base, result.error)
      @idempotency_key = params[:idempotency_key].presence || SecureRandom.uuid
      load_new_form_options
      render :new, status: :unprocessable_entity
    end
  end

  # Rows with no product chosen are ignored — same rule as the edit form's
  # nested attributes (PurchaseRequest reject_if).
  def form_lines(attrs)
    attrs.fetch(:items_attributes, {}).to_h.values
         .map { |line| line.symbolize_keys.slice(:product_id, :quantity, :unit_price, :source_warehouse_id) }
         .reject { |line| line[:product_id].blank? }
  end

  def created_ids
    params[:created_ids].to_s.split(",").map(&:to_i)
  end
  helper_method :created_ids

  def find_request
    policy_scope(PurchaseRequest).find(params[:id])
  end

  def redirect_with_result(result, ok_message:)
    if result.ok?
      redirect_to inventory_purchase_request_path(@purchase_request), notice: ok_message
    else
      redirect_to inventory_purchase_request_path(@purchase_request), alert: result.error
    end
  end

  def filter_params
    params.permit(:status, :supplier_id, :date_from, :date_to, :created_by_id, :receiving_status, :q, :needs_action)
  end

  def parsed_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def purchase_request_items_params
    return [] unless params[:items].is_a?(Array)

    params[:items].map do |item|
      item.permit(:product_id, :quantity, :unit_price, :supplier_id, :source_warehouse_id, :notes).to_h
    end
  end

  def purchase_request_form_params
    params.require(:purchase_request).permit(
      :supplier_id, :notes,
      items_attributes: [ :product_id, :quantity, :unit_price, :source_warehouse_id ]
    )
  end

  def purchase_request_update_params
    params.require(:purchase_request).permit(
      :supplier_id, :notes,
      items_attributes: [ :id, :product_id, :quantity, :unit_price, :source_warehouse_id, :notes, :_destroy ]
    )
  end

  def load_options
    @suppliers  = current_user.business.suppliers.ordered
    @products   = current_user.business.products.transactable.ordered
    @warehouses = accessible_warehouses
  end

  # "الدفعات المقدمة": every advance (all statuses, for the audit trail) plus
  # the ledger-derived totals — computed here, never in the view.
  def load_advances
    @advances = @purchase_request.advances.includes(:created_by, :confirmed_by, :cancelled_by, :reversed_by,
                                                    custody_account: :user)
                                 .order(:created_at, :id).to_a
    applied = FinancialSettlement.advance_applications
                                 .where(funding_source_type: "PurchaseRequestAdvance", funding_source_id: @advances.map(&:id))
                                 .group(:funding_source_id).sum(:amount)
    @advance_applied_amounts = applied
    @advance_summary = {
      total:     @purchase_request.total_amount,
      advances:  @purchase_request.advances_total,
      remaining: @purchase_request.amount_remaining_after_advances,
      count:     @advances.count(&:confirmed?),
      unapplied: @purchase_request.advances_total - applied.values.sum
    }
    @new_advance = PurchaseRequestAdvance.new(business: @purchase_request.business, purchase_request: @purchase_request)
  end

  # Low Stock rows come from the same report the dashboard and Low Stock page
  # use — restricted to the warehouses this user may access — never recomputed.
  def load_new_form_options
    load_options
    @low_stock_rows = Inventory::Reports::LowStock.new(current_user.business, warehouse_ids: accessible_warehouse_ids).rows
  end
end
