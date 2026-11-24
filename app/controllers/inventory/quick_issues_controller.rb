# Quick Issue popup — ONE product per transaction, opened in the global modal
# (<turbo-frame id="modal">, layouts/application) from every entry point:
#
#   new?product_id=  the single-product popup: product, the warehouse (the
#                    only one the user may use is preselected; with several, a
#                    selector of exactly those — Inventory::IssueWarehouseReach),
#                    the quantity available there, quantity, reason;
#   new              (no product) a compact product-selection step that opens
#                    the same popup for the chosen product. Once the popup is
#                    open for a product it stays tied to it: there is no way
#                    to switch products, and an unusable product (invalid,
#                    archived, tampered id) shows an error state, not a picker.
#
# Opened outside the modal (a new tab, a bookmarked URL) the same content
# renders as a compact page. Orchestration only: authorize, build the options,
# call Inventory::StockIssueQuickIssue — which enforces every rule itself —
# then leave the popup (success) or re-render it with the errors and the
# values entered (failure).
class Inventory::QuickIssuesController < Inventory::BaseController
  # Any multi-line shape (the removed items_attributes contract, product
  # lists, a repeated product_id[] / quantity[]) is refused outright — one
  # Quick Issue is one product.
  MULTI_LINE_KEYS = %w[items_attributes items lines product_ids].freeze
  private_constant :MULTI_LINE_KEYS

  before_action :authorize_quick_issue

  def new
    if params[:product_id].present?
      @product       = find_product(params[:product_id])
      @product_error = t("inventory.quick_issue.errors.product_unavailable") if @product.nil?
      # Opened for a specific product (a product entry point): the popup stays
      # tied to it — an unusable product shows an error, never a picker for
      # another one. Only the product step itself (step=1) may re-offer it.
      @product_locked = params[:step].blank?
    end
    @form = { warehouse_id: warehouse_reach.default_warehouse_id, quantity: nil, issue_reason: nil, notes: nil }
    @field_errors = {}
    load_options
  end

  def create
    return rejected(several_products_refusal) if several_products_submitted?

    result = Inventory::StockIssueQuickIssue.new(
      actor: current_user, warehouse_id: form_params[:warehouse_id],
      product_id: form_params[:product_id], quantity: form_params[:quantity],
      reason: form_params[:issue_reason], notes: form_params[:notes]
    ).call
    result.ok? ? posted(result.issue) : rejected(result)
  end

  private

  def authorize_quick_issue
    authorize StockIssue, :quick_issue?
  end

  # quick_issue_stock is usable on its own (no view_inventory required).
  def admitted_without_inventory_view? = Inventory::StockIssueQuickIssue.permitted?(current_user)

  def warehouse_reach = @warehouse_reach ||= Inventory::IssueWarehouseReach.for(current_user)

  def find_product(id)
    policy_scope(Product).transactable.includes(:product_barcodes, Product::IMAGE_PRELOAD).find_by(id: id)
  end

  # quick_issue_stock does not include viewing Stock Issues: open the posted
  # issue only for someone who may see it, otherwise return to the page the
  # popup was opened from. Inside the modal the browser is told to visit that
  # page (the "visit" stream action, application.js) — the popup never
  # becomes a page of its own.
  def posted(issue)
    notice = t("inventory.quick_issue.success", number: issue.issue_number,
                                                 product: issue.items.first&.product&.name)
    target = policy(issue).show? ? inventory_stock_issue_path(issue) : return_path
    if turbo_frame_request?
      flash[:notice] = notice
      render turbo_stream: helpers.turbo_stream_action_tag(:visit, url: target)
    else
      redirect_to target, notice: notice
    end
  end

  # The popup again, with the product, every value entered and the error
  # beside its field (or at the top when it concerns the whole issue).
  def rejected(result)
    @product      = find_product(form_params[:product_id]) unless form_params[:product_id].respond_to?(:each)
    @product_locked = true # a submitted popup is tied to its product: never offer another
    @form         = form_params.to_h.symbolize_keys.slice(:warehouse_id, :quantity, :issue_reason, :notes)
    @field_errors = result.field_errors || {}
    @error        = result.error if @field_errors.empty? || @product.nil?
    load_options
    render :new, status: :unprocessable_entity
  end

  def load_options
    @warehouses        = warehouse_reach.warehouses.to_a
    @warehouse_message = warehouse_reach.message if @warehouses.empty?
    @availability      = warehouse_availability(@product) if @product
    @return_to      = return_path
  end

  # { warehouse_id => available quantity } for each warehouse the user may
  # issue from (Inventory::StockIssueQuickIssue.available_by — on hand minus
  # approved reservations, the figure the service pre-checks; re-checked
  # under lock when posting). Two aggregate queries.
  def warehouse_availability(product)
    available = Inventory::StockIssueQuickIssue.available_by(warehouse_ids: @warehouses.map(&:id), product_ids: [ product.id ])
    @warehouses.to_h { |warehouse| [ warehouse.id, available.fetch([ warehouse.id, product.id ], BigDecimal("0")) ] }
  end

  def form_params
    params.fetch(:quick_issue, {}).permit(:product_id, :quantity, :warehouse_id, :issue_reason, :notes)
  end

  def several_products_refusal
    message = t("inventory.quick_issue.errors.single_product_only")
    Inventory::StockIssueQuickIssue::Result.new(ok: false, error: message, field_errors: { product: message })
  end

  def several_products_submitted?
    raw = params[:quick_issue]
    return false unless raw.respond_to?(:key?)

    MULTI_LINE_KEYS.any? { |key| raw.key?(key) } ||
      raw[:product_id].respond_to?(:each) || raw[:quantity].respond_to?(:each)
  end

  # Where the popup returns after posting: the local page it was opened from
  # (carried by the form), else the standalone Quick Issue page.
  def return_path
    candidate = params[:return_to].presence || (request.referer if turbo_frame_request? && action_name == "new")
    path = local_path(candidate)
    path.nil? || path.start_with?(inventory_quick_issue_path) ? new_inventory_quick_issue_path : path
  end

  def local_path(url)
    return nil if url.blank?

    uri = URI.parse(url.to_s)
    return nil if uri.host.present? && uri.host != request.host
    return nil unless uri.path.to_s.start_with?("/") && !uri.path.start_with?("//")

    [ uri.path, uri.query ].compact_blank.join("?")
  rescue URI::InvalidURIError
    nil
  end
end
