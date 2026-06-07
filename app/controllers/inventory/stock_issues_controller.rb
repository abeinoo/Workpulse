class Inventory::StockIssuesController < Inventory::BaseController
  def index
    authorize StockIssue
    @stock_issues = policy_scope(StockIssue).recent.includes(:warehouse)
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
  end

  def run_import
    authorize StockIssue, :create?
    file      = params[:file]
    warehouse = accessible_warehouses.find_by(id: params[:warehouse_id])
    if file.blank? || warehouse.nil?
      redirect_to import_inventory_stock_issues_path, alert: t("inventory.imports.file_and_warehouse_required") and return
    end

    @result = Inventory::Imports::StockIssueImporter.new(
      current_user.business, file.read, warehouse: warehouse, user: current_user
    ).call

    if @result.ok?
      render :import_result
    else
      redirect_to import_inventory_stock_issues_path, alert: t("inventory.imports.invalid_headers")
    end
  end

  private

  def find_issue
    policy_scope(StockIssue).find(params[:id])
  end

  def load_options
    @warehouses = accessible_warehouses
    @products   = current_user.business.products.ordered
  end

  def issue_params
    params.require(:stock_issue).permit(
      :warehouse_id, :issued_on, :notes,
      items_attributes: [ :id, :product_id, :quantity, :_destroy ]
    )
  end
end
