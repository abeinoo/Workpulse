class Inventory::StockIssuesController < Inventory::BaseController
  def index
    authorize StockIssue
    # Drafts belong to an in-progress import (see Inventory::Imports) — they
    # aren't real documents yet, so they're reachable only from their batch
    # page, never from this list.
    base = policy_scope(StockIssue).posted
    @stock_issues = base
                    .for_warehouse(params[:warehouse_id])
                    .for_branch(params[:branch_id])
                    .on_or_after(params[:from])
                    .on_or_before(params[:to])
                    .search(params[:q])
                    .recent
                    .includes(:warehouse, :branch, :created_by, items: :product)
    @stock_issues = @stock_issues.where(created_by_id: params[:created_by_id]) if params[:created_by_id].present?
    @stock_issues = @stock_issues.active if params[:status] == "active"
    @stock_issues = @stock_issues.voided if params[:status] == "voided"

    @filter_warehouses   = accessible_warehouses
    @filter_branches     = current_user.business.branches.active.order(:name)
    @filter_creators     = User.where(
                              id: StockIssue.for_business(current_user.business).select(:created_by_id)
                            ).order(:first_name, :last_name)
    @active_filter_count = params.values_at(:q, :warehouse_id, :branch_id, :status, :created_by_id, :from, :to)
                                 .count(&:present?)

    # Summary bar figures — always scoped to the whole (unfiltered) accessible
    # set, so "Filtered Results" below reads as "N of the M total documents".
    @total_documents_count = base.count
    @total_value           = StockIssueItem.joins(:stock_issue).merge(base).sum(:total_cost)
    @filtered_count        = @stock_issues.count
  end

  def show
    @stock_issue = find_issue
    authorize @stock_issue
    @items = @stock_issue.items.includes(:product)
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

    result = Inventory::StockIssuePoster.new(@stock_issue).call
    if result.ok?
      redirect_to inventory_stock_issue_path(@stock_issue), notice: t("inventory.stock_issues.created")
    else
      load_options
      @stock_issue.items.build if @stock_issue.items.empty?
      render :new, status: :unprocessable_entity
    end
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

  def find_issue
    policy_scope(StockIssue).find(params[:id])
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
end
