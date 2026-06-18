class Inventory::ProductsController < Inventory::BaseController
  def index
    authorize Product
    @products = policy_scope(Product).ordered.includes(:brand, :product_category, image_attachment: :blob)
    @products = @products.where(brand_id: params[:brand_id])               if params[:brand_id].present?
    @products = @products.where(product_category_id: params[:category_id]) if params[:category_id].present?
    if params[:q].present?
      term = "%#{params[:q].strip.downcase}%"
      @products = @products
        .left_joins(:product_barcodes, :product_variants)
        .where(
          "LOWER(products.name) LIKE :t OR LOWER(products.sku) LIKE :t OR " \
          "LOWER(product_barcodes.barcode) LIKE :t OR " \
          "LOWER(product_variants.name) LIKE :t OR LOWER(product_variants.sku) LIKE :t",
          t: term
        )
        .distinct
    end

    @stock_totals = Inventory::StockLevels.totals_for(current_user.business)
    @brands       = current_user.business.brands.ordered
    @categories   = current_user.business.product_categories.active.ordered
  end

  def show
    @product = policy_scope(Product)
                 .includes(:product_variants, product_barcodes: :product_variant)
                 .find(params[:id])
    authorize @product
    wh_ids = accessible_warehouse_ids   # nil = all warehouses
    @warehouses = current_user.business.warehouses.ordered.index_by(&:id)

    all_by_warehouse    = Inventory::StockLevels.new(@product).by_warehouse
    @stock_by_warehouse = wh_ids ? all_by_warehouse.slice(*wh_ids) : all_by_warehouse

    # Show every (accessible) warehouse that has stock OR a configured threshold —
    # so a configured branch at zero stock still appears.
    setting_warehouse_ids = @product.product_warehouse_settings.map(&:warehouse_id)
    setting_warehouse_ids &= wh_ids if wh_ids
    @warehouse_row_ids = (@stock_by_warehouse.keys + setting_warehouse_ids).uniq
                           .sort_by { |id| @warehouses[id]&.name.to_s }

    # Stock figures shown on the page reflect only the warehouses the user may see.
    @display_stock       = @stock_by_warehouse.values.sum
    @display_stock_value = @display_stock * @product.average_cost_price

    movements = @product.inventory_movements.includes(:warehouse)
    movements = movements.where(warehouse_id: wh_ids) if wh_ids
    @recent_movements = movements.order(occurred_on: :desc, id: :desc).limit(15)
  end

  def new
    @product = current_user.business.products.build
    @product.barcode = params[:barcode].presence if params[:barcode].present?
    @product.product_barcodes.build if @product.product_barcodes.empty?
    authorize @product
    load_options
  end

  def create
    @product = current_user.business.products.build(product_params)
    @product.average_cost_price = @product.initial_cost_price if @product.average_cost_price.to_d.zero?
    authorize @product
    if @product.save
      redirect_to inventory_product_path(@product), notice: t("inventory.products.created")
    else
      load_options
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @product = policy_scope(Product).includes(:product_variants, :product_barcodes).find(params[:id])
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
    if @product.destroy
      redirect_to inventory_products_path, notice: t("inventory.products.destroyed")
    else
      redirect_to inventory_products_path, alert: @product.errors.full_messages.to_sentence
    end
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
  # Atomically generates and saves a sequential internal barcode.
  # Accepts an optional variant_id param to assign the barcode directly to a variant.
  # Retries up to 5 times on uniqueness collision from concurrent requests.
  def generate_barcode
    @product = find_product
    authorize @product, :update?

    variant_id = resolve_generate_variant_id
    return if performed?   # rendered error inside resolve_generate_variant_id

    barcode = nil
    5.times do
      code = Inventory::BarcodeGenerator.next_code
      pb   = @product.product_barcodes.build(
        barcode:      code,
        barcode_type: "internal",
        variant_id:   variant_id,
        is_primary:   !@product.product_barcodes.where(variant_id: variant_id, is_primary: true).exists?
      )
      if pb.save
        barcode = pb
        break
      end
      # Retry only on uniqueness collision; other errors are terminal
      break unless pb.errors[:barcode].any? { |msg| msg.match?(/taken/i) }
    end

    if barcode&.persisted?
      render json: {
        id:           barcode.id,
        barcode:      barcode.barcode,
        barcode_type: barcode.barcode_type,
        is_primary:   barcode.is_primary,
        variant_id:   barcode.variant_id
      }
    else
      render json: { error: t("inventory.products.generate_barcode_failed") },
             status: :unprocessable_entity
    end
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
    else
      redirect_to import_inventory_products_path, alert: t("inventory.imports.invalid_headers")
    end
  end

  private

  def find_product
    policy_scope(Product).find(params[:id])
  end

  # Returns the variant_id to use for barcode generation, or nil for product-level.
  # Renders a 404 JSON error and returns :error if the supplied variant_id is invalid.
  def resolve_generate_variant_id
    return nil if params[:variant_id].blank?
    variant = @product.product_variants.find_by(id: params[:variant_id])
    unless variant
      render json: { error: t("inventory.products.variant_not_found") }, status: :not_found
      return :error
    end
    variant.id
  end

  def load_options
    @brands = current_user.business.brands.ordered
    # Only active categories are selectable, but keep the product's current
    # category in the list (even if since deactivated) so editing never silently
    # clears it.
    cats = current_user.business.product_categories
    @categories = cats.where(active: true)
                      .or(cats.where(id: @product&.product_category_id))
                      .ordered
    @warehouses = accessible_warehouses
    @suppliers  = current_user.business.suppliers.ordered
  end

  def product_params
    params.require(:product).permit(
      :name, :sku, :brand_id, :product_category_id, :default_supplier_id,
      :initial_cost_price, :low_stock_level, :reorder_quantity,
      :track_inventory, :receive_low_stock_notification, :reorder_level,
      :selling_markup_percentage, :notes, :image,
      product_warehouse_settings_attributes: [ :id, :warehouse_id, :low_stock_level, :reorder_quantity, :_destroy ],
      product_barcodes_attributes:           [ :id, :barcode, :barcode_type, :is_primary, :variant_id, :_destroy ],
      product_variants_attributes:           [ :id, :name, :sku, :active, :position, :_destroy ]
    )
  end
end
