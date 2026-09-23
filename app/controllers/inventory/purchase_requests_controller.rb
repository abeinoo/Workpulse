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
  end

  def create
    authorize PurchaseRequest

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

  private

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
end
