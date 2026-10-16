class Inventory::ProductsController < Inventory::BaseController
  def index
    authorize Product
    wh_ids    = accessible_warehouse_ids
    @products = policy_scope(Product).ordered
                  .includes(:brand, :product_category, image_attachment: :blob)

    # ── Status filter (active / archived / all) — default: active ──────────
    @status_filter = params[:status].presence&.inquiry || "active"
    @products = case @status_filter.to_s
    when "archived" then @products.archived
    when "all"      then @products
    else                 @products.active
    end

    # ── Family-type filter ──────────────────────────────────────────────────
    @family_type = params[:family_type].presence
    @products = case @family_type
    when "root"       then @products.root_parents
    when "child"      then @products.children
    when "standalone" then @products.standalone
    else                   @products
    end

    # ── Attribute filters ───────────────────────────────────────────────────
    @products = @products.where(brand_id: params[:brand_id])               if params[:brand_id].present?
    @products = @products.where(product_category_id: params[:category_id]) if params[:category_id].present?

    # ── Text / barcode search ────────────────────────────────────────────────
    if params[:q].present?
      term = "%#{params[:q].strip.downcase}%"

      # Phase A: find directly matching IDs across name, SKU, and barcodes.
      # reorder(nil) strips the inherited ORDER BY name so that PostgreSQL does
      # not reject the query — SELECT DISTINCT id … ORDER BY name is invalid
      # because name is absent from the select list.  Ordering is irrelevant
      # here since we only need the ID set; duplicate IDs cannot arise because
      # the EXISTS subquery never joins product_barcodes into the outer row.
      matching_ids = @products.reorder(nil).where(
        "LOWER(products.name) LIKE :t OR LOWER(products.sku) LIKE :t OR " \
        "EXISTS (" \
          "SELECT 1 FROM product_barcodes pb2 " \
          "WHERE pb2.product_id = products.id " \
          "AND LOWER(pb2.barcode) LIKE :t" \
        ")",
        t: term
      ).pluck(:id)

      # Phase B: expand to full family so context is always visible.
      # Matched child  → pull in its parent and siblings.
      # Matched parent → pull in all its children.
      parent_ids  = Product.where(id: matching_ids).where.not(parent_product_id: nil)
                           .pluck(:parent_product_id)
      sibling_ids = Product.where(parent_product_id: matching_ids + parent_ids).pluck(:id)

      all_ids   = (matching_ids + parent_ids + sibling_ids).uniq
      @products = policy_scope(Product).where(id: all_ids).ordered
                    .includes(:brand, :product_category, image_attachment: :blob)
    end

    # ── Stock totals (warehouse-scoped) ─────────────────────────────────────
    @stock_totals = Inventory::StockLevels.totals_for(current_user.business,
                                                       warehouse_ids: wh_ids)

    # Derive family stock from the already-fetched totals (no extra query).
    # Inherits the same warehouse scope automatically.
    child_parent_pairs = current_user.business.products
      .where.not(parent_product_id: nil)
      .pluck(:id, :parent_product_id)
    @family_stock_totals = {}
    child_parent_pairs.each do |child_id, parent_id|
      @family_stock_totals[parent_id] = (@family_stock_totals[parent_id] || 0) +
                                        (@stock_totals[child_id] || 0)
    end

    # Child count per parent — one GROUP BY for the count badge in tree rows
    @child_counts = current_user.business.products
      .where.not(parent_product_id: nil)
      .group(:parent_product_id)
      .count

    # ── Tree structure ───────────────────────────────────────────────────────
    # Always build the tree so family context is clear in search results too.
    @root_products = @products.where(parent_product_id: nil)
                               .includes(:child_products)

    @brands     = current_user.business.brands.ordered
    @categories = current_user.business.product_categories.active.ordered
  end

  def show
    @product = policy_scope(Product)
                 .includes(:child_products, :product_barcodes)
                 .find(params[:id])
    authorize @product
    wh_ids      = accessible_warehouse_ids
    @warehouses = current_user.business.warehouses.ordered.index_by(&:id)

    if @product.parent?
      # Parent product: aggregate stock from children, warehouse-scoped.
      @family_stock = Inventory::StockLevels.family_total(@product,
                                                           warehouse_ids: wh_ids)
      child_ids = @product.child_products.map(&:id)
      @child_stock_totals = child_ids.any? ?
        InventoryMovement.where(product_id: child_ids)
                         .then { |r| wh_ids ? r.where(warehouse_id: wh_ids) : r }
                         .group(:product_id)
                         .sum(Arel.sql(Inventory::StockLevels::SIGNED_SUM))
        : {}
    else
      all_by_warehouse    = Inventory::StockLevels.new(@product).by_warehouse
      @stock_by_warehouse = wh_ids ? all_by_warehouse.slice(*wh_ids) : all_by_warehouse

      setting_warehouse_ids = @product.product_warehouse_settings.map(&:warehouse_id)
      setting_warehouse_ids &= wh_ids if wh_ids
      @warehouse_row_ids = (@stock_by_warehouse.keys + setting_warehouse_ids).uniq
                             .sort_by { |id| @warehouses[id]&.name.to_s }

      @display_stock       = @stock_by_warehouse.values.sum
      @display_stock_value = @display_stock * @product.average_cost_price

      movements = @product.inventory_movements.includes(:warehouse)
      movements = movements.where(warehouse_id: wh_ids) if wh_ids
      @recent_movements = movements.order(occurred_on: :desc, id: :desc).limit(15)

      load_purchase_history
      load_consumption_stats
      load_recent_documents
    end
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
    @product = current_user.business.products.build(product_params)
    @product.average_cost_price = @product.initial_cost_price if @product.average_cost_price.to_d.zero?
    authorize @product

    if @product.save
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
                 .includes(:child_products, :product_barcodes)
                 .find(params[:id])
    authorize @product
    @product.product_barcodes.build if @product.product_barcodes.empty?
    load_options
  end

  def update
    @product = find_product
    authorize @product
    if @product.update(product_params)
      redirect_to inventory_product_path(@product), notice: t("inventory.products.updated")
    else
      load_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @product = find_product
    authorize @product
    if @product.has_inventory_history?
      redirect_to inventory_product_path(@product),
                  alert: t("inventory.products.has_history_cannot_delete")
    elsif @product.destroy
      redirect_to inventory_products_path, notice: t("inventory.products.destroyed")
    else
      redirect_to inventory_product_path(@product),
                  alert: @product.errors.full_messages.to_sentence
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

  def archive_family
    @product = find_product
    authorize @product
    @product.archive_family!
    redirect_to inventory_product_path(@product), notice: t("inventory.products.family_archived")
  rescue ActiveRecord::RecordInvalid
    redirect_to inventory_product_path(@product), alert: @product.errors.full_messages.to_sentence
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

  # POST /inventory/products/:id/generate_barcode
  def generate_barcode
    @product = find_product
    authorize @product, :update?

    barcode = nil
    5.times do
      code = Inventory::BarcodeGenerator.next_code
      pb   = @product.product_barcodes.build(
        barcode:      code,
        barcode_type: "internal",
        is_primary:   !@product.product_barcodes.where(is_primary: true).exists?
      )
      if pb.save
        barcode = pb
        break
      end
      break unless pb.errors[:barcode].any? { |msg| msg.match?(/taken/i) }
    end

    if barcode&.persisted?
      render json: {
        id:           barcode.id,
        barcode:      barcode.barcode,
        barcode_type: barcode.barcode_type,
        is_primary:   barcode.is_primary
      }
    else
      render json: { error: t("inventory.products.generate_barcode_failed") },
             status: :unprocessable_entity
    end
  end

  # GET /inventory/products/:id/children
  # Returns the child product rows HTML for lazy-loading by the product-family
  # Stimulus controller. Warehouse-scoped like every other stock view.
  def children
    @product  = find_product
    authorize @product, :show?
    @children = @product.child_products.ordered
                        .includes(:brand, image_attachment: :blob)
    wh_ids    = accessible_warehouse_ids
    child_ids = @children.map(&:id)

    @child_stock_totals = child_ids.any? ?
      InventoryMovement.where(product_id: child_ids)
                       .then { |r| wh_ids ? r.where(warehouse_id: wh_ids) : r }
                       .group(:product_id)
                       .sum(Arel.sql(Inventory::StockLevels::SIGNED_SUM))
      : {}

    render partial: "child_rows",
           locals:  { children: @children, stock_totals: @child_stock_totals,
                      parent_product: @product }
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
    # Single query: all non-voided GR items for this product, newest first.
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
      .order("goods_receipts.received_on DESC, goods_receipts.id DESC")

    @last_gr_item = gr_items.first

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
    # Net of voided issues — the same ConsumptionLedger Finance uses.
    ledger = ->(**window) { Inventory::ConsumptionLedger.new(@product.business, product_id: @product.id, **window) }

    @last_consumed_on = ledger.call.last_consumed_on

    month_start = Time.current.beginning_of_month.to_date
    month_end   = Time.current.end_of_month.to_date
    @consumed_this_month = ledger.call(from: month_start, to: month_end).net_quantity

    first_movement_date = @product.inventory_movements.minimum(:occurred_on)
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

  # Quick-create-from-import-row flow: the newly created product resolves the
  # stock-issue import row that triggered the modal, and the response updates
  # that row (and the batch summary) in place instead of navigating away.
  def resolve_import_row_and_respond
    result = Inventory::Imports::StockIssueImportRowResolver.new(
      current_user.business, params[:return_to_import_row_id], product_id: @product.id
    ).call
    @row = result.row
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

    # Only active root-level products can become parents (max depth = 1).
    # Exclude the current product so it cannot assign itself as its own parent.
    @parent_product_options = current_user.business.products
      .active
      .where(parent_product_id: nil)
      .where.not(id: [ @product.id ].compact)
      .ordered
  end

  def product_params
    params.require(:product).permit(
      :name, :sku, :brand_id, :product_category_id, :default_supplier_id,
      :parent_product_id,
      :initial_cost_price, :low_stock_level, :reorder_quantity,
      :track_inventory, :receive_low_stock_notification, :reorder_level,
      :selling_markup_percentage, :notes, :image,
      product_warehouse_settings_attributes: [ :id, :warehouse_id, :low_stock_level, :reorder_quantity, :_destroy ],
      product_barcodes_attributes:           [ :id, :barcode, :barcode_type, :is_primary, :_destroy ]
    )
  end
end
