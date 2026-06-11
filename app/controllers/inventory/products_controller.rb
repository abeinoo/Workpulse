class Inventory::ProductsController < Inventory::BaseController
  def index
    authorize Product
    @products = policy_scope(Product).ordered.includes(:brand, :product_category, image_attachment: :blob)
    @products = @products.where(brand_id: params[:brand_id])            if params[:brand_id].present?
    @products = @products.where(product_category_id: params[:category_id]) if params[:category_id].present?
    if params[:q].present?
      term = "%#{params[:q].strip.downcase}%"
      @products = @products.where("LOWER(name) LIKE :t OR LOWER(sku) LIKE :t OR LOWER(barcode) LIKE :t", t: term)
    end

    @stock_totals = Inventory::StockLevels.totals_for(current_user.business)
    @brands       = current_user.business.brands.ordered
    @categories   = current_user.business.product_categories.active.ordered
  end

  def show
    @product = find_product
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
    @product = find_product
    authorize @product
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
      :name, :sku, :barcode, :brand_id, :product_category_id, :default_supplier_id,
      :initial_cost_price, :low_stock_level, :reorder_quantity,
      :selling_markup_percentage, :notes, :image,
      product_warehouse_settings_attributes: [ :id, :warehouse_id, :low_stock_level, :reorder_quantity, :_destroy ]
    )
  end
end
