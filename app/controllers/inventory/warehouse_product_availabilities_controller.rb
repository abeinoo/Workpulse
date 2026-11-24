# The warehouse page's Products tab: which products are used in this
# warehouse (Active / Inactive), and the explicit add / edit / deactivate /
# reactivate actions. Every change goes through
# Inventory::ProductAvailabilityManager, which loads the ids within the
# actor's business, authorizes (manage_product_availability + warehouse
# scope), locks and audits; this controller only orchestrates and renders.
#
# Not Configured products (no row) are never listed as configured: they
# appear only on the Add page, as candidates.
class Inventory::WarehouseProductAvailabilitiesController < Inventory::BaseController
  PER_PAGE        = 50
  STATUS_FILTERS  = %w[active inactive].freeze
  # Add page: "not_configured" (default) lists only products that can be
  # added; "all" also shows configured ones (disabled, with their state);
  # "with_stock" lists Not Configured products that hold stock here.
  CANDIDATE_FILTERS = %w[not_configured all with_stock].freeze

  PRODUCT_ACTIONS = %i[save_from_product exclusion_panel exclude_from_product include_from_product].freeze

  before_action :set_warehouse, except: PRODUCT_ACTIONS
  before_action :load_product_pair, only: PRODUCT_ACTIONS

  def index
    authorize @warehouse, :show?, policy_class: ProductWarehouseSettingPolicy
    @can_manage = availability_policy.manage?

    base = policy_scope(ProductWarehouseSetting).where(warehouse_id: @warehouse.id)
    by_status = base.group(:status).count
    @status_counts = { "all" => by_status.values.sum, "active" => by_status["active"].to_i,
                       "inactive" => by_status["inactive"].to_i }
    @status_filter = STATUS_FILTERS.include?(params[:status]) ? params[:status] : nil
    @query = params[:q].to_s.strip.presence

    rows = base.joins(:product)
    rows = rows.where(status: @status_filter) if @status_filter
    rows = search(rows, @query)

    @filtered_count = rows.count
    @total_pages = [ (@filtered_count.to_f / PER_PAGE).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @total_pages)
    settings = rows.includes(:status_changed_by, product: Product::IMAGE_PRELOAD)
                   .order("products.name", :id).limit(PER_PAGE).offset((@page - 1) * PER_PAGE).to_a
    @pairs = Inventory::AvailabilityFigures.build(settings.map { |s| [ s.product, @warehouse, s ] })
    @unconfigured_with_stock_count = unconfigured_with_stock_ids.size
  end

  def new
    authorize @warehouse, :manage?, policy_class: ProductWarehouseSettingPolicy
    load_candidates
  end

  # items: { "<product id>" => { selected: "1", low_stock_level:, reorder_quantity:,
  #                              receive_low_stock_notification: } }
  def create
    authorize @warehouse, :manage?, policy_class: ProductWarehouseSettingPolicy
    items = selected_items
    result = if items.empty?
      Inventory::ProductAvailabilityManager::Result.new(ok: false, error: :no_items)
    else
      manager.add_many(warehouse_id: @warehouse.id, items: items)
    end

    if result.ok?
      redirect_to inventory_warehouse_product_availabilities_path(@warehouse), notice: added_notice(result)
    else
      @error_message = error_message(result.error, result.record)
      load_candidates
      render :new, status: :unprocessable_entity
    end
  end

  # ── The product page's branch cards (one product, one warehouse each) ──
  # The warehouse id from the browser is only a candidate: the manager loads
  # it within the actor's business, authorizes, locks and audits.

  # Low-stock level / reorder quantity of one card (creates the row on the
  # first save of an Included-by-default sales branch pair).
  def save_from_product
    attrs = params[:product_warehouse_setting]
    attrs = ActionController::Parameters.new unless attrs.is_a?(ActionController::Parameters)
    result = manager.save_settings(product_id: @product.id, warehouse_id: @warehouse.id,
                                   low_stock_level: attrs[:low_stock_level], reorder_quantity: attrs[:reorder_quantity])
    if result.ok?
      redirect_after_change(@product.id, notice: t("product_availability.flash.updated", product: @product.name, warehouse: @warehouse.name))
    elsif result.error == :unchanged
      redirect_after_change(@product.id, notice: t("product_availability.flash.unchanged"))
    else
      render_product_availability(@product,
                                  row_errors: { @warehouse.id => error_message(result.error, @warehouse) },
                                  row_values: { @warehouse.id => attrs.permit(:low_stock_level, :reorder_quantity).to_h })
    end
  end

  # The exclusion confirmation (lazy Turbo Frame in the card): what changes,
  # the dependency summary and the reason — before anything is written.
  def exclusion_panel
    result = manager.pair_dependencies(product_id: @product.id, warehouse_id: @warehouse.id)
    raise Pundit::NotAuthorizedError unless result.ok?

    @dependencies = result.dependencies
    render :exclusion_frame, layout: false
  end

  def exclude_from_product
    result = manager.exclude(product_id: @product.id, warehouse_id: @warehouse.id, reason: params[:reason])
    if result.ok?
      redirect_after_change(@product.id, notice: t("product_availability.flash.excluded", product: @product.name, warehouse: @warehouse.name))
    else
      dependencies = manager.pair_dependencies(product_id: @product.id, warehouse_id: @warehouse.id).dependencies
      render_product_availability(@product, exclusion_errors: {
        @warehouse.id => { message: error_message(result.error, @warehouse), reason: params[:reason].to_s, dependencies: dependencies }
      })
    end
  end

  # Undo an exclusion: the Inactive row is reactivated with its kept settings.
  def include_from_product
    row = policy_scope(ProductWarehouseSetting).find_by(product_id: @product.id, warehouse_id: @warehouse.id)
    result = row ? manager.reactivate(setting_id: row.id) : Inventory::ProductAvailabilityManager::Result.new(ok: false, error: :already_active)
    if result.ok?
      redirect_after_change(@product.id, notice: t("product_availability.flash.included", product: @product.name, warehouse: @warehouse.name))
    else
      redirect_after_change(@product.id, alert: error_message(result.error, @warehouse))
    end
  end

  def edit
    @setting = find_setting
    authorize @setting, :manage?
    redirect_after_change(@setting.product_id, alert: error_message(:inactive, @setting.product)) unless @setting.status_active?
  end

  def update
    @setting = find_setting
    authorize @setting, :manage?
    attrs = params[:product_warehouse_setting]
    attrs = ActionController::Parameters.new unless attrs.is_a?(ActionController::Parameters)
    result = manager.update(setting_id: @setting.id,
                            low_stock_level: attrs[:low_stock_level], reorder_quantity: attrs[:reorder_quantity],
                            receive_low_stock_notification: attrs[:receive_low_stock_notification] == "1")
    if result.ok?
      redirect_after_change(@setting.product_id,
                            notice: t("product_availability.flash.updated", product: @setting.product.name, warehouse: @warehouse.name))
    elsif result.error == :unchanged
      redirect_after_change(@setting.product_id, notice: t("product_availability.flash.unchanged"))
    elsif return_to_product?
      redirect_after_change(@setting.product_id, alert: error_message(result.error, @warehouse))
    else
      @error_message = error_message(result.error, @setting.product)
      @setting.assign_attributes(attrs.permit(:low_stock_level, :reorder_quantity).to_h) if @setting.status_active?
      render :edit, status: :unprocessable_entity
    end
  end

  # Confirmation page: the dependency summary and the reason, BEFORE anything changes.
  def deactivation
    @setting = find_setting
    authorize @setting, :manage?
    unless @setting.status_active?
      @error_message = error_message(:already_inactive, @setting.product)
      return render(:deactivation_frame, layout: false) if turbo_frame_request?

      return redirect_after_change(@setting.product_id, alert: @error_message)
    end

    load_dependencies
    # The product Edit page loads the same panel inline (Turbo Frame).
    render :deactivation_frame, layout: false if turbo_frame_request?
  end

  def deactivate
    @setting = find_setting
    authorize @setting, :manage?
    result = manager.deactivate(setting_id: @setting.id, reason: params[:reason])
    if result.ok?
      redirect_after_change(@setting.product_id,
                            notice: t("product_availability.flash.deactivated", product: @setting.product.name, warehouse: @warehouse.name))
    else
      @error_message = error_message(result.error, @setting.product)
      @setting.reload
      # A row no longer Active: report it where the user came from.
      return redirect_after_change(@setting.product_id, alert: @error_message) unless @setting.status_active?

      return redirect_after_change(@setting.product_id, alert: @error_message) if return_to_product?

      load_dependencies
      render :deactivation, status: :unprocessable_entity
    end
  end

  def reactivate
    @setting = find_setting
    authorize @setting, :manage?
    result = manager.reactivate(setting_id: @setting.id, reason: params[:reason])
    if result.ok?
      redirect_after_change(@setting.product_id,
                            notice: t("product_availability.flash.reactivated", product: @setting.product.name, warehouse: @warehouse.name))
    else
      redirect_after_change(@setting.product_id, alert: error_message(result.error, @setting.product))
    end
  end

  private

  def set_warehouse
    @warehouse = policy_scope(Warehouse).find(params[:warehouse_id])
  end

  # Product-page actions: the product (params[:id]) and the card's warehouse,
  # both within the user's business and warehouse scope (404 otherwise); the
  # manager authorizes the change itself.
  def load_product_pair
    @product = policy_scope(Product).find(params[:id])
    authorize @product, :show?
    @warehouse = policy_scope(Warehouse).find(params[:warehouse_id])
    params[:return_to] = "product_availability" unless return_to_product?
  end

  def availability_policy = ProductWarehouseSettingPolicy.new(current_user, @warehouse)

  def manager = Inventory::ProductAvailabilityManager.new(actor: current_user)

  def find_setting
    policy_scope(ProductWarehouseSetting).where(warehouse_id: @warehouse.id).includes(:product).find(params[:id])
  end

  def load_dependencies
    result = manager.dependencies(setting_id: @setting.id)
    raise Pundit::NotAuthorizedError unless result.ok?

    @dependencies = result.dependencies
  end

  def search(relation, query)
    return relation if query.nil?

    term = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
    relation.where("LOWER(products.name) LIKE :t OR LOWER(products.sku) LIKE :t", t: term)
  end

  # Products of this business that hold stock in this warehouse (on-hand ≠ 0)
  # but have no availability row here.
  def unconfigured_with_stock_ids
    configured = ProductWarehouseSetting.where(warehouse_id: @warehouse.id).select(:product_id)
    InventoryMovement.where(business_id: current_user.business_id, warehouse_id: @warehouse.id)
                     .where.not(product_id: configured)
                     .group(:product_id)
                     .having("#{Inventory::StockLevels::SIGNED_SUM} <> 0")
                     .pluck(:product_id)
  end

  # The Add page's candidate list: transactable (active) products of the
  # business, searchable, one page at a time.
  def load_candidates
    @candidate_filter = CANDIDATE_FILTERS.include?(params[:filter]) ? params[:filter] : "not_configured"
    @query = params[:q].to_s.strip.presence
    @submitted = submitted_items

    products = Product.where(business_id: current_user.business_id).transactable
    configured_here = ProductWarehouseSetting.where(warehouse_id: @warehouse.id).select(:product_id)
    products = case @candidate_filter
    when "all"        then products
    when "with_stock" then products.where(id: unconfigured_with_stock_ids)
    else                   products.where.not(id: configured_here)
    end
    products = search(products, @query)

    @filtered_count = products.count
    @total_pages = [ (@filtered_count.to_f / PER_PAGE).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @total_pages)
    page = products.includes(Product::IMAGE_PRELOAD).order(:name, :id).limit(PER_PAGE).offset((@page - 1) * PER_PAGE).to_a
    settings = ProductWarehouseSetting.where(warehouse_id: @warehouse.id, product_id: page.map(&:id)).index_by(&:product_id)
    @candidates = Inventory::AvailabilityFigures.build(page.map { |p| [ p, @warehouse, settings[p.id] ] })
  end

  def submitted_items
    raw = params[:items]
    return {} unless raw.respond_to?(:to_unsafe_h)

    raw.to_unsafe_h.select { |_id, attrs| attrs.is_a?(Hash) }
  end

  def selected_items
    submitted_items.filter_map do |product_id, attrs|
      next unless attrs["selected"] == "1"

      item = { product_id: product_id, low_stock_level: attrs["low_stock_level"], reorder_quantity: attrs["reorder_quantity"] }
      item[:receive_low_stock_notification] = attrs["receive_low_stock_notification"] == "1" if attrs.key?("receive_low_stock_notification")
      item
    end
  end

  def added_notice(result)
    notice = t("product_availability.flash.added", count: result.records.size, warehouse: @warehouse.name)
    return notice if result.skipped.blank?

    skipped = result.skipped.map do |row|
      "#{row.product.name} (#{t("product_availability.states.#{row.status}")})"
    end
    "#{notice} #{t('product_availability.flash.skipped', count: skipped.size, products: skipped.to_sentence)}"
  end

  # Where a change returns to. Only these named targets are accepted (never a
  # URL from params):
  #   product_edit          the product Edit page's availability section
  #   product_availability  the standalone product availability page
  #   (anything else)       this warehouse's Products tab
  RETURN_TARGETS = %w[product_edit product_availability].freeze

  def return_to_product? = RETURN_TARGETS.include?(params[:return_to])
  helper_method :return_to_product?

  # Back on a product page, the feedback is shown inside the availability
  # section (flash[:availability_notice] / [:availability_alert]) so a Turbo
  # Frame update of that section carries it.
  def redirect_after_change(product_id, notice: nil, alert: nil)
    if return_to_product? && product_id.present?
      flash[:availability_notice] = notice if notice
      flash[:availability_alert]  = alert if alert
      path = if params[:return_to] == "product_edit"
        edit_inventory_product_path(product_id, anchor: "availability")
      else
        availability_inventory_product_path(product_id)
      end
      redirect_to path, status: :see_other
    else
      redirect_to inventory_warehouse_product_availabilities_path(@warehouse), notice: notice, alert: alert, status: :see_other
    end
  end

  # A refused action from the product page: re-render the availability
  # section (Turbo Frame) with the reason and what the user entered — no
  # redirect, so nothing is replayed and nothing was written.
  def render_product_availability(product, **section)
    @product = product
    @availability = Inventory::ProductAvailabilityOverview.new(product, user: current_user)
    @availability_section = section
    render "inventory/products/availability", status: :unprocessable_entity
  end

  # Cancel links on the warehouse-tab Edit / Deactivate pages.
  def cancel_path(product)
    case params[:return_to]
    when "product_edit"         then edit_inventory_product_path(product, anchor: "availability")
    when "product_availability" then availability_inventory_product_path(product)
    else inventory_warehouse_product_availabilities_path(@warehouse)
    end
  end
  helper_method :cancel_path

  # The reason, prefixed with the product or warehouse it concerns (record).
  def error_message(code, record = nil)
    return Inventory::ProductAvailabilityManager.message(code, record) if record.is_a?(Warehouse)

    name = record.respond_to?(:name) ? record.name : nil
    key  = "product_availability.errors.#{code}"
    warehouse = record.is_a?(Warehouse) ? record : @warehouse
    message = t(key, warehouse: warehouse&.name, default: t("product_availability.errors.invalid"))
    name ? t("product_availability.errors.for_product", product: name, message: message) : message
  end
end
