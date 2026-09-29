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

  # ?kind=xlsx serves the Excel version; both carry the same SKU/Quantity
  # columns and are only examples — any column names can be mapped.
  def import_template
    authorize StockIssue, :create?
    if params[:kind] == "xlsx"
      send_data Inventory::Imports::StockIssueImporter.sample_xlsx,
                filename: "stock_issue_import_sample.xlsx",
                type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    else
      send_data Inventory::Imports::StockIssueImporter.sample_csv,
                filename: "stock_issue_import_sample.csv", type: "text/csv"
    end
  end

  # Step 2 — Match Columns + Preview. Reached from the upload form (params[:file])
  # and re-submitted whenever the user changes a mapping (params[:csv_payload]).
  # Never writes anything.
  def preview_import
    authorize StockIssue, :create?
    return unless load_import_context

    @mapping = import_mapping
    render_import_preview
  end

  # Step 3 — Import with the confirmed mapping. A direct file upload (no
  # mapping) is auto-matched; if that can't satisfy the required fields the
  # user is sent to the mapping step instead of being rejected.
  #
  # Every row must pass the preview validation. The one exception is the
  # user's explicit "import and fix the rest" choice (allow_partial=1), which
  # hands the invalid rows to the existing Resolve Import Errors screen.
  #
  # An import never deducts stock: a clean import lands in pending_approval
  # (see Inventory::Imports::StockIssueImporter) and follows the normal
  # approve -> confirm workflow. params[:notes] is the form's document-level
  # "Stock Issue Notes", saved on the issue itself (never per line).
  def run_import
    authorize StockIssue, :create?
    return unless load_import_context

    @mapping = import_mapping
    unless @mapper.mapping_valid?(@mapping) && @mapper.data_row_count.positive?
      render_import_preview(status: :unprocessable_entity) and return
    end

    importer = Inventory::Imports::StockIssueImporter.new(
      current_user.business, @mapper.rows(@mapping), warehouse: @warehouse, branch: @branch, user: current_user,
      notes: params[:notes]
    )
    if params[:allow_partial] != "1" && importer.preview.any? { |row| !row.valid? }
      @import_blocked = true
      render_import_preview(status: :unprocessable_entity) and return
    end

    result = importer.call

    if result.batch
      redirect_to inventory_stock_issue_import_batch_path(result.batch)
    else
      redirect_to inventory_stock_issue_path(result.issue), notice: t("inventory.imports.submitted_for_approval")
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

  # Resolves warehouse/branch and the CSV (fresh upload or the payload carried
  # through the mapping step). Redirects back to the upload form and returns
  # false on anything unusable.
  def load_import_context
    @warehouse = accessible_warehouses.find_by(id: params[:warehouse_id])
    @branch    = current_user.business.branches.find_by(id: params[:branch_id])
    fields     = Inventory::Imports::StockIssueImporter::COLUMNS
    source     = params[:file].presence || params[:csv_payload].presence

    if source.nil? || @warehouse.nil? || @branch.nil?
      redirect_to import_inventory_stock_issues_path, alert: t("inventory.imports.file_warehouse_and_branch_required")
      return false
    end

    @file_name     = params[:file].respond_to?(:original_filename) ? params[:file].original_filename : params[:file_name].to_s
    @just_uploaded = params[:file].present?
    @mapper        = if params[:file].present?
      Inventory::Imports::CsvColumnMapper.from_upload(params[:file].read, filename: @file_name, fields: fields)
    else
      Inventory::Imports::CsvColumnMapper.from_payload(params[:csv_payload], fields: fields)
    end
    true
  rescue Inventory::Imports::CsvColumnMapper::ParseError => e
    redirect_to import_inventory_stock_issues_path, alert: t("inventory.imports.mapping.parse_errors.#{e.message}")
    false
  end

  # The user's confirmed mapping, or the auto-suggestion on first upload.
  def import_mapping
    return @mapper.suggested_mapping if params[:mapping].blank?

    keys = Inventory::Imports::StockIssueImporter::COLUMNS.map(&:key)
    @mapper.normalize_mapping(params.require(:mapping).permit(*keys))
  end

  def render_import_preview(status: :ok)
    @fields         = Inventory::Imports::StockIssueImporter::COLUMNS
    @mapping_errors = @mapper.mapping_errors(@mapping)
    if @mapping_errors.empty?
      @preview_rows = Inventory::Imports::StockIssueImporter.new(
        current_user.business, @mapper.rows(@mapping), warehouse: @warehouse, branch: @branch
      ).preview
      @invalid_rows = @preview_rows.reject(&:valid?)
    end
    render :import_preview, status: status
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
