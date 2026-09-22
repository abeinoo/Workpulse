class Inventory::StockIssuesController < Inventory::BaseController
  def index
    authorize StockIssue
    base = policy_scope(StockIssue).excluding_incomplete_imports
    @stock_issues = base
                    .for_warehouse(params[:warehouse_id])
                    .for_branch(params[:branch_id])
                    .for_status(params[:workflow_status])
                    .for_creator(params[:created_by_id])
                    .for_approver(params[:approved_by_id])
                    .for_issuer(params[:issued_by_id])
                    .on_or_after(params[:from])
                    .on_or_before(params[:to])
                    .search(params[:q])
                    .recent
                    .includes(:warehouse, :branch, :created_by, :approved_by, :issued_by, items: :product)
    @stock_issues = @stock_issues.active if params[:status] == "active"
    @stock_issues = @stock_issues.voided if params[:status] == "voided"

    @filter_warehouses   = accessible_warehouses
    @filter_branches     = current_user.business.branches.active.order(:name)
    @filter_creators     = User.where(
                              id: StockIssue.for_business(current_user.business).select(:created_by_id)
                            ).order(:first_name, :last_name)
    @filter_approvers    = User.where(
                              id: StockIssue.for_business(current_user.business).select(:approved_by_id)
                            ).order(:first_name, :last_name)
    @filter_issuers      = User.where(
                              id: StockIssue.for_business(current_user.business).select(:issued_by_id)
                            ).order(:first_name, :last_name)
    @active_filter_count = params.values_at(:q, :warehouse_id, :branch_id, :status, :workflow_status,
                                             :created_by_id, :approved_by_id, :issued_by_id, :from, :to)
                                 .count(&:present?)

    # Summary bar figures — always scoped to the whole (unfiltered) accessible
    # set, so "Filtered Results" below reads as "N of the M total documents".
    # "Total Value" counts only actually-issued (physically deducted) stock —
    # never approved-but-not-yet-issued — so it never overstates real
    # inventory movement.
    @total_documents_count = base.count
    @total_value           = StockIssueItem.joins(:stock_issue).merge(base.issued.active).sum(:total_cost)
    @filtered_count        = @stock_issues.count
  end

  def show
    @stock_issue = find_issue(includes: [ :submitted_by, :approved_by, :rejected_by, :issued_by, :cancelled_by, :voided_by ])
    authorize @stock_issue
    @items           = @stock_issue.items.includes(:product)
    @audit_logs      = AuditLog.for_auditable(@stock_issue).recent.includes(:actor)
    @timeline_events = build_timeline_events
  end

  def new
    @stock_issue = current_user.business.stock_issues.build(issued_on: Date.current)
    @stock_issue.items.build
    authorize @stock_issue
    load_options
  end

  def create
    @stock_issue = current_user.business.stock_issues.build(issue_params)
    @stock_issue.created_by = current_user
    authorize @stock_issue
    ensure_warehouses_accessible!(@stock_issue.warehouse_id)

    result = Inventory::StockIssueDraftService.new(@stock_issue, actor: current_user).call
    if result.ok?
      redirect_to inventory_stock_issue_path(@stock_issue), notice: t("inventory.stock_issues.created")
    else
      load_options
      @stock_issue.items.build if @stock_issue.items.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @stock_issue = find_issue
    authorize @stock_issue
    load_options
  end

  def update
    @stock_issue = find_issue
    authorize @stock_issue
    @stock_issue.assign_attributes(issue_params)
    ensure_warehouses_accessible!(@stock_issue.warehouse_id)

    result = Inventory::StockIssueDraftService.new(@stock_issue, actor: current_user).call
    if result.ok?
      redirect_to inventory_stock_issue_path(@stock_issue), notice: t("inventory.stock_issues.updated")
    else
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def submit
    @stock_issue = find_issue
    authorize @stock_issue, :submit?
    result = Inventory::StockIssueSubmission.new(stock_issue_id: @stock_issue.id, actor: current_user).call
    redirect_with_result(result, ok_message: t("inventory.stock_issues.submitted"))
  end

  def approve
    @stock_issue = find_issue
    authorize @stock_issue, :approve?
    result = Inventory::StockIssueApproval.new(stock_issue_id: @stock_issue.id, actor: current_user).approve!
    redirect_with_result(result, ok_message: t("inventory.stock_issues.approved"))
  end

  def reject
    @stock_issue = find_issue
    authorize @stock_issue, :reject?
    result = Inventory::StockIssueApproval.new(stock_issue_id: @stock_issue.id, actor: current_user)
                                          .reject!(reason: params[:rejection_reason])
    redirect_with_result(result, ok_message: t("inventory.stock_issues.rejected"))
  end

  def confirm
    @stock_issue = find_issue
    authorize @stock_issue, :confirm?
    result = Inventory::StockIssueConfirmationService.new(stock_issue_id: @stock_issue.id, actor: current_user).call
    redirect_with_result(result, ok_message: t("inventory.stock_issues.confirmed"))
  end

  def cancel
    @stock_issue = find_issue
    authorize @stock_issue, :cancel?
    result = Inventory::StockIssueCancellation.new(stock_issue_id: @stock_issue.id, actor: current_user,
                                                   reason: params[:cancellation_reason]).call
    redirect_with_result(result, ok_message: t("inventory.stock_issues.cancelled"))
  end

  def destroy
    @stock_issue = find_issue
    authorize @stock_issue
    @stock_issue.destroy
    redirect_to inventory_stock_issues_path, notice: t("inventory.stock_issues.deleted")
  rescue ImmutableDocument::DeletionNotAllowedError
    redirect_to inventory_stock_issue_path(@stock_issue), alert: t("inventory.stock_issues.errors.cannot_delete")
  end

  def void
    @stock_issue = find_issue
    authorize @stock_issue, :void?
    result = Inventory::DocumentVoider.new(@stock_issue, user: current_user, reason: params[:void_reason]).call
    if result.ok?
      redirect_to inventory_stock_issue_path(@stock_issue), notice: t("inventory.stock_issues.voided")
    else
      redirect_to inventory_stock_issue_path(@stock_issue),
                  alert: @stock_issue.errors.full_messages.to_sentence.presence || t("inventory.void.failed")
    end
  end

  def import
    authorize StockIssue, :create?
    @warehouses = accessible_warehouses
    @branches   = current_user.business.branches.active.order(:name)
  end

  def import_template
    authorize StockIssue, :create?
    send_data Inventory::Imports::StockIssueImporter.sample_csv,
              filename: "stock_issue_import_sample.csv", type: "text/csv"
  end

  def run_import
    authorize StockIssue, :create?
    file      = params[:file]
    warehouse = accessible_warehouses.find_by(id: params[:warehouse_id])
    branch    = current_user.business.branches.find_by(id: params[:branch_id])
    if file.blank? || warehouse.nil? || branch.nil?
      redirect_to import_inventory_stock_issues_path, alert: t("inventory.imports.file_warehouse_and_branch_required") and return
    end

    result = Inventory::Imports::StockIssueImporter.new(
      current_user.business, file.read, warehouse: warehouse, branch: branch, user: current_user
    ).call

    unless result.ok?
      redirect_to import_inventory_stock_issues_path, alert: t("inventory.imports.invalid_headers") and return
    end

    if result.batch
      redirect_to inventory_stock_issue_import_batch_path(result.batch)
    else
      redirect_to inventory_stock_issue_path(result.issue), notice: t("inventory.imports.import_completed")
    end
  end

  private

  def find_issue(includes: [])
    policy_scope(StockIssue).includes(includes).find(params[:id])
  end

  def redirect_with_result(result, ok_message:)
    if result.ok?
      redirect_to inventory_stock_issue_path(@stock_issue), notice: ok_message
    else
      redirect_to inventory_stock_issue_path(@stock_issue), alert: result.error
    end
  end

  def load_options
    @warehouses = accessible_warehouses
    @branches   = current_user.business.branches.active.order(:name)
    @products   = current_user.business.products.transactable.ordered
  end

  def issue_params
    params.require(:stock_issue).permit(
      :warehouse_id, :branch_id, :issued_on, :notes,
      items_attributes: [ :id, :product_id, :quantity, :_destroy ]
    )
  end

  # Builds the show page's Activity Timeline: one entry per event that
  # actually happened, in chronological order. Sourced from @audit_logs
  # rather than the issue's own approved_by/rejected_by/etc. columns, since
  # those would lose history across any resubmission. A legacy issue posted
  # before this workflow existed has no audit trail at all (the old
  # StockIssuePoster never logged one) — it falls back to a single synthetic
  # "issued (legacy)" entry sourced from its issued_at/issued_by backfill
  # (see the AddApprovalWorkflowToStockIssues migration) so the timeline is
  # never silently empty for a real, physically-issued document. No queries
  # here — everything is already preloaded by #show.
  def build_timeline_events
    events = [ { type: :created, time: @stock_issue.created_at, actor: @stock_issue.created_by } ]

    @audit_logs.each do |log|
      case log.action
      when "submit_for_approval"
        events << { type: :submitted, time: log.created_at, actor: log.actor }
      when "approve"
        events << { type: :approved, time: log.created_at, actor: log.actor }
      when "reject"
        events << { type: :rejected, time: log.created_at, actor: log.actor, data: log.metadata["reason"] }
      when "confirm"
        events << { type: :issued, time: log.created_at, actor: log.actor }
      when "cancel"
        events << { type: :cancelled, time: log.created_at, actor: log.actor, data: log.metadata["reason"] }
      when "void"
        events << { type: :voided, time: log.created_at, actor: log.actor, data: log.metadata["reason"] }
      end
    end

    if @stock_issue.issued? && events.none? { |e| e[:type] == :issued }
      events << { type: :issued_legacy, time: @stock_issue.issued_at || @stock_issue.created_at, actor: @stock_issue.issued_by }
    end

    events.sort_by { |event| event[:time] }
  end
end
