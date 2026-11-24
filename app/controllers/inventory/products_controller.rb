class Inventory::ProductsController < Inventory::BaseController
  # Stock-status filter of the index. in_stock / out_of_stock are the Current
  # Stock report's definitions (Inventory::Reports::CurrentStock: on-hand > 0
  # vs <= 0, inventory-tracked products only); low_stock is the list's own
  # low-stock badge (Inventory::LowStockQuery, per-warehouse thresholds).
  STOCK_STATUSES = %w[in_stock low_stock out_of_stock].freeze

  def index
    authorize Product
    wh_ids = accessible_warehouse_ids

    # ── Status tab (active / archived / all) — default: active ─────────────
    @status_filter = params[:status].presence&.inquiry || "active"
    base = policy_scope(Product)
    base = case @status_filter.to_s
    when "archived" then base.archived
    when "all"      then base
    else                 base.active
    end

    # ── Stock totals (warehouse-scoped) ─────────────────────────────────────
    @stock_totals = Inventory::StockLevels.totals_for(current_user.business,
                                                       warehouse_ids: wh_ids)
    @low_stock_product_ids = low_stock_product_ids(warehouse_ids: wh_ids)
    in_stock_ids = @stock_totals.select { |_, quantity| quantity.to_d.positive? }.keys

    # ── Summary — on the tab's base set, before search / filters, so the
    #    header always reflects the whole (authorized, warehouse-scoped)
    #    catalogue. Three COUNT queries; no product is loaded for them.
    @summary = {
      total:        base.count,
      low_stock:    base.where(id: @low_stock_product_ids.to_a).count,
      out_of_stock: base.inventory_tracked.where.not(id: in_stock_ids).count
    }

    @products = base.ordered.includes(:brand, :product_category, Product::IMAGE_PRELOAD)

    # ── Attribute filters ───────────────────────────────────────────────────
    @products = @products.where(brand_id: params[:brand_id])               if params[:brand_id].present?
    @products = @products.where(product_category_id: params[:category_id]) if params[:category_id].present?

    # ── Stock status ────────────────────────────────────────────────────────
    @stock_status = params[:stock_status].presence_in(STOCK_STATUSES)
    @products = case @stock_status
    when "in_stock"     then @products.inventory_tracked.where(id: in_stock_ids)
    when "low_stock"    then @products.where(id: @low_stock_product_ids.to_a)
    when "out_of_stock" then @products.inventory_tracked.where.not(id: in_stock_ids)
    else                     @products
    end

    # ── Text / barcode search: name, SKU or any barcode ─────────────────────
    if params[:q].present?
      @products = @products.where(
        "LOWER(products.name) LIKE :t OR LOWER(products.sku) LIKE :t OR " \
        "EXISTS (SELECT 1 FROM product_barcodes pb2 WHERE pb2.product_id = products.id AND LOWER(pb2.barcode) LIKE :t)",
        t: "%#{ProductBarcode.normalize(params[:q]).to_s.downcase}%"
      )
    end

    @brands     = current_user.business.brands.ordered
    @categories = current_user.business.product_categories.active.ordered
  end

  def show
    @product = policy_scope(Product)
                 .includes(:product_barcodes, Product::IMAGE_PRELOAD)
                 .find(params[:id])
    authorize @product
    wh_ids      = accessible_warehouse_ids
    @warehouses = current_user.business.warehouses.ordered.index_by(&:id)

    all_by_warehouse    = Inventory::StockLevels.new(@product).by_warehouse
    @stock_by_warehouse = wh_ids ? all_by_warehouse.slice(*wh_ids) : all_by_warehouse

    load_warehouse_availability
    @low_stock_warehouse = @availability_pairs.any?(&:low_stock?)

    @display_stock       = @stock_by_warehouse.values.sum
    @display_stock_value = @display_stock * @product.average_cost_price

    movements = @product.inventory_movements.includes(:warehouse, :source)
    movements = movements.where(warehouse_id: wh_ids) if wh_ids
    @recent_movements = Inventory::Reports::Movements.preload_stock_counts(
      movements.order(occurred_on: :desc, id: :desc).limit(15).to_a
    )

    load_purchase_history
    load_consumption_stats
    load_recent_documents
  end

  def new
    @product = current_user.business.products.build
    @product.sku = params[:sku].presence if params[:sku].present?
    @product.barcode = params[:barcode].presence if params[:barcode].present?
    @product.product_barcodes.build if @product.product_barcodes.empty?
    authorize @product
    load_options
    render :new_modal if params[:return_to_import_row_id].present?
  end

  def create
    refuse_nested_warehouse_settings!
    @product = current_user.business.products.build(product_params)
    @product.average_cost_price = @product.initial_cost_price if @product.average_cost_price.to_d.zero?
    authorize @product

    if save_with_gallery { @product.save }
      if params[:return_to_import_row_id].present?
        resolve_import_row_and_respond
      else
        redirect_to inventory_product_path(@product), notice: t("inventory.products.created")
      end
    else
      load_options
      render params[:return_to_import_row_id].present? ? :new_modal : :new, status: :unprocessable_entity
    end
  end

  def edit
    @product = policy_scope(Product)
                 .includes(:product_barcodes)
                 .find(params[:id])
    authorize @product
    # Barcodes are optional: a product without any shows the empty state (and
    # "Add barcode"), never a spare blank row that looks like a barcode.
    load_edit_sections
  end

  # The availability section on its own page — for users who manage
  # availability but may not edit the product's details.
  def availability
    @product = find_product
    authorize @product, :show?

    @availability = Inventory::ProductAvailabilityOverview.new(@product, user: current_user)
  end

  # The Edit page's one Save: product details, gallery and the warehouse
  # availability cards in ONE transaction (Inventory::ProductEditor) — all
  # saved, or nothing.
  def update
    @product = find_product
    authorize @product
    refuse_nested_warehouse_settings!
    result = Inventory::ProductEditor.new(
      actor: current_user, product_id: @product.id, attributes: product_params,
      gallery: (gallery_entries if gallery_submitted?),
      availability: availability_param
    ).call
    if result.ok?
      redirect_to inventory_product_path(@product), notice: t("inventory.products.all_saved")
    else
      @product = result.product
      load_edit_sections(result)
      flash.now[:alert] = t("inventory.products.nothing_saved")
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @product = find_product
    authorize @product
    result = Inventory::ProductDeletion.new(actor: current_user).call(product_id: @product.id)
    if result.ok?
      redirect_to inventory_products_path, notice: t("inventory.products.destroyed")
    else
      redirect_to inventory_product_path(@product), alert: deletion_refusal_message(result)
    end
  end

  def archive
    @product = find_product
    authorize @product
    @product.archive!
    redirect_to inventory_product_path(@product), notice: t("inventory.products.archived")
  rescue ActiveRecord::RecordInvalid
    redirect_to inventory_product_path(@product), alert: @product.errors.full_messages.to_sentence
  end

  def restore
    @product = find_product
    authorize @product
    @product.restore!
    redirect_to inventory_product_path(@product), notice: t("inventory.products.restored")
  end

  def import
    authorize Product, :create?
    @warehouses = accessible_warehouses
  end

  def import_template
    authorize Product, :create?
    send_data Inventory::Imports::ProductImporter.sample_csv,
              filename: "products_import_sample.csv", type: "text/csv"
  end

  def next_barcode_code
    authorize Product, :index?
    render json: { code: Inventory::BarcodeGenerator.next_code }
  end

  def run_import
    authorize Product, :create?
    file = params[:file]
    if file.blank?
      redirect_to import_inventory_products_path, alert: t("inventory.imports.no_file") and return
    end

    warehouse = accessible_warehouses.find_by(id: params[:warehouse_id])
    @result = Inventory::Imports::ProductImporter.new(
      current_user.business, file.read, warehouse: warehouse, user: current_user
    ).call

    if @result.ok?
      @warehouses = accessible_warehouses
      render :import_result
    elsif @result.settings_error
      redirect_to import_inventory_products_path,
                  alert: t("inventory.imports.central_settings.#{@result.settings_error}",
                           default: t("inventory.imports.central_settings.refused", reason: @result.settings_error.to_s.humanize),
                           warehouse: @result.central_warehouse&.name)
    elsif @result.opening_errors.present?
      redirect_to import_inventory_products_path,
                  alert: t("inventory.imports.opening_balance_refused",
                           warehouse: warehouse.name, errors: @result.opening_errors.to_sentence)
    elsif @result.header_error == :malformed_csv
      err = @result.parse_error
      redirect_to import_inventory_products_path,
                  alert: t("inventory.imports.malformed_csv",
                            line: err.line_number, content: err.raw_line)
    else
      redirect_to import_inventory_products_path, alert: t("inventory.imports.invalid_headers")
    end
  end

  private

  def load_purchase_history
    # Single query: all non-voided GR items for this product, newest first —
    # only receipts of warehouses the viewer can reach (D6): the supplier rows,
    # last price and quantities never reveal another warehouse's purchases.
    wh_ids   = accessible_warehouse_ids
    gr_items = GoodsReceiptItem
      .joins(:goods_receipt)
      .includes(goods_receipt: :supplier)
      .where(
        goods_receipts: {
          business_id: current_user.business.id,
          voided_at:   nil
        },
        product_id: @product.id
      )
      .then { |rel| wh_ids ? rel.where(goods_receipts: { warehouse_id: wh_ids }) : rel }
      .order("goods_receipts.received_on DESC, goods_receipts.id DESC")

    @last_gr_item = gr_items.first
    # Product#last_purchase_price is the latest receipt of ANY warehouse: a
    # viewer restricted to some warehouses gets the latest price among theirs.
    @last_purchase_price = wh_ids ? @last_gr_item&.unit_cost : @product.last_purchase_price

    # Group in Ruby — avoids N+1 and complex window-function SQL for catalog sizes.
    by_supplier = gr_items.group_by { |i| i.goods_receipt.supplier_id }
    @supplier_purchase_rows = by_supplier.map do |_supplier_id, items|
      latest     = items.first
      supplier   = latest.goods_receipt.supplier
      {
        supplier:            supplier,
        last_purchase_date:  latest.goods_receipt.received_on,
        last_purchase_price: latest.unit_cost,
        total_quantity:      items.sum(&:quantity),
        purchase_count:      items.size
      }
    end.sort_by { |r| r[:last_purchase_date] }.reverse
  end

  # Latest goods receipts / stock issues carrying this product. Policy-scoped
  # (business + accessible warehouses) so every linked document is one the
  # viewer can open; nil hides a section the viewer may not list at all.
  def load_recent_documents
    recent = Inventory::ProductRecentDocuments.new(
      @product,
      goods_receipts: policy_scope(GoodsReceipt),
      stock_issues:   policy_scope(StockIssue).excluding_incomplete_imports
    )
    @recent_goods_receipts = policy(GoodsReceipt).index? ? recent.goods_receipts : nil
    @recent_stock_issues   = policy(StockIssue).index?   ? recent.stock_issues   : nil
  end

  def load_consumption_stats
    # Net of voided issues — the same ConsumptionLedger Finance uses — limited
    # to the warehouses the viewer can reach (D6), like the stock figures above.
    wh_ids = accessible_warehouse_ids
    ledger = lambda do |**window|
      Inventory::ConsumptionLedger.new(@product.business, product_id: @product.id, warehouse_ids: wh_ids, **window)
    end

    @last_consumed_on = ledger.call.last_consumed_on

    month_start = Time.current.beginning_of_month.to_date
    month_end   = Time.current.end_of_month.to_date
    @consumed_this_month = ledger.call(from: month_start, to: month_end).net_quantity

    first_movement_date = @product.inventory_movements
                                  .then { |rel| wh_ids ? rel.where(warehouse_id: wh_ids) : rel }
                                  .minimum(:occurred_on)
    if first_movement_date
      months_elapsed = ((Date.current - first_movement_date).to_f / 30.44).ceil.clamp(1, Float::INFINITY)
      total_consumed = ledger.call.net_quantity
      @avg_monthly_consumption = (total_consumed.to_f / months_elapsed).round(1)
    else
      @avg_monthly_consumption = 0
    end

    if @avg_monthly_consumption > 0 && @display_stock > 0
      @estimated_days_remaining = (@display_stock / (@avg_monthly_consumption / 30.44)).round
    else
      @estimated_days_remaining = nil
    end
  end

  def find_product
    policy_scope(Product).find(params[:id])
  end

  # Everything the Edit page shows besides the product form: the options and
  # the warehouse availability cards (with each card's refusal and typed values).
  def load_edit_sections(result = nil)
    load_options
    @availability = Inventory::ProductAvailabilityOverview.new(@product, user: current_user)
    if result
      @availability_view = { row_errors: result.availability_errors, exclusion_errors: result.exclusion_errors,
                             row_values: availability_param.transform_keys(&:to_i)
                                                           .transform_values { |v| v.slice("low_stock_level", "reorder_quantity") },
                             exclusion_values: availability_param.transform_keys(&:to_i) }
    else
      @availability_view = {}
    end
  end

  # { "<warehouse id>" => { "low_stock_level", "reorder_quantity", "excluded", "reason" } } — the
  # warehouse ids are only candidates: Inventory::ProductAvailabilityManager
  # loads and authorizes each one.
  def availability_param
    raw = params[:availability]
    return {} unless raw.respond_to?(:each_pair)

    raw.to_unsafe_h.each_with_object({}) do |(warehouse_id, values), acc|
      next unless values.is_a?(Hash)

      acc[warehouse_id.to_s] = values.slice("low_stock_level", "reorder_quantity", "excluded", "reason").transform_values(&:to_s)
    end
  end

  # Products low in at least one of the viewer's warehouses, by each
  # warehouse's own threshold (never a product-level one) — the list badges.
  def low_stock_product_ids(warehouse_ids:)
    Inventory::LowStockQuery.new(current_user.business, warehouse_ids: warehouse_ids).alerts.to_set { |alert| alert.product.id }
  end

  # Saves the product (the block) and, when the form sent its image gallery,
  # applies it in the same transaction (Inventory::ProductGalleryUpdater):
  # both or neither. A form without the gallery leaves every image as it is.
  def save_with_gallery
    saved = false
    Product.transaction do
      raise ActiveRecord::Rollback unless yield

      if gallery_submitted?
        result = Inventory::ProductGalleryUpdater.new(actor: current_user, product_id: @product.id, entries: gallery_entries).call
        unless result.ok?
          @product.errors.add(:base, t("inventory.products.gallery.errors.#{result.error}", max: Attachable::DEFAULT_MAX_SIZE / 1.megabyte))
          raise ActiveRecord::Rollback
        end
      end
      saved = true
    end
    saved
  rescue ActiveRecord::RecordNotUnique => e
    # A concurrent save took the same barcode (or SKU) after validation: the
    # unique index refused it and the whole save was rolled back.
    if e.message.include?("product_barcodes")
      @product.errors.add(:base, :barcode_taken)
    else
      @product.errors.add(:sku, :taken)
    end
    false
  end

  def gallery_submitted? = params.dig(:product, :gallery_present) == "1"

  # ["image:<id>" | "upload:<signed id>", …] in display order (first = primary).
  def gallery_entries = Array(params.dig(:product, :gallery)).map(&:to_s)
  helper_method :gallery_entries, :gallery_submitted?

  # The product page's read-only Warehouse availability summary: every
  # reachable warehouse where this product has an availability row or stock,
  # with its state, on-hand, reserved and that warehouse's OWN settings (a
  # warehouse without a row shows Not Configured — there is no product-level
  # value to show). Managing happens in the Edit page's availability section
  # (or the standalone availability page).
  def load_warehouse_availability
    settings = policy_scope(ProductWarehouseSetting).where(product_id: @product.id).index_by(&:warehouse_id)
    shown_ids = (settings.keys + @stock_by_warehouse.reject { |_id, qty| qty.to_d.zero? }.keys).uniq
    warehouses = shown_ids.filter_map { |id| @warehouses[id] }.sort_by(&:name)
    @availability_pairs = Inventory::AvailabilityFigures.build(warehouses.map { |w| [ @product, w, settings[w.id] ] })
    @availability_manage_path = availability_manage_path
  end

  # Where "Manage availability" goes: the Edit page's section for users who
  # edit products, the standalone page for availability managers who don't;
  # nil when the user manages availability in none of their warehouses.
  def availability_manage_path
    overview = Inventory::ProductAvailabilityOverview.new(@product, user: current_user)
    return nil unless overview.any_manageable?

    policy(@product).update? ? edit_inventory_product_path(@product, anchor: "availability") : availability_inventory_product_path(@product)
  end

  def deletion_refusal_message(result)
    case result.error
    when :has_history  then t("inventory.products.has_history_cannot_delete")
    when :not_archived then t("inventory.products.delete_requires_archive")
    when :referenced   then t("inventory.products.delete_referenced")
    when :audit_failed then t("inventory.products.delete_audit_failed")
    else t("flash.not_authorized")
    end
  end

  # Quick-create-from-import-row flow: the newly created product resolves the
  # stock-issue import row that triggered the modal, and the response updates
  # that row (and the batch summary) in place instead of navigating away.
  def resolve_import_row_and_respond
    result = Inventory::Imports::StockIssueImportRowResolver.new(
      current_user.business, params[:return_to_import_row_id], user: current_user, product_id: @product.id
    ).call
    @row = result.row
    preload_product_images([ @row.product ]) # the re-rendered row's thumbnail
    @batch = @row.batch
    render :resolve_from_modal
  end

  def load_options
    @brands = current_user.business.brands.ordered
    cats = current_user.business.product_categories
    @categories = cats.where(active: true)
                      .or(cats.where(id: @product&.product_category_id))
                      .ordered
    @warehouses = accessible_warehouses
    @suppliers  = current_user.business.suppliers.ordered
  end

  # Availability rows (and their per-warehouse low-stock settings) are written
  # only by Inventory::ProductAvailabilityManager — audited, gated by
  # manage_product_availability and the warehouse scope — from the product
  # page's Warehouse Availability card and the warehouse Products tab. The
  # product form no longer carries them: a request that still does (crafted,
  # or a form left open from before) is refused before anything is assigned,
  # whatever warehouse or row it names.
  def refuse_nested_warehouse_settings!
    submitted = params[:product]
    raise Pundit::NotAuthorizedError if submitted.respond_to?(:key?) && submitted.key?(:product_warehouse_settings_attributes)
  end

  def product_params
    params.require(:product).permit(
      :name, :sku, :measure_amount, :unit_of_measure, :brand_id, :product_category_id, :default_supplier_id,
      # No low-stock / reorder fields: those are per warehouse only
      # (Inventory::ProductAvailabilityManager), never on the product.
      :initial_cost_price, :track_inventory,
      :selling_markup_percentage, :notes,
      product_barcodes_attributes:           [ :id, :barcode, :barcode_type, :is_primary, :_destroy ]
    )
  end
end
