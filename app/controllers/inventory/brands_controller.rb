class Inventory::BrandsController < Inventory::BaseController
  def index
    authorize Brand
    @brands = policy_scope(Brand).ordered.left_joins(:products)
                                 .select("brands.*, COUNT(products.id) AS products_count")
                                 .group("brands.id")
  end

  def new
    @brand = current_user.business.brands.build
    authorize @brand
  end

  def create
    @brand = current_user.business.brands.build(brand_params)
    authorize @brand
    if @brand.save
      redirect_to inventory_brands_path, notice: t("inventory.brands.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @brand = find_brand
    authorize @brand
  end

  def update
    @brand = find_brand
    authorize @brand
    if @brand.update(brand_params)
      redirect_to inventory_brands_path, notice: t("inventory.brands.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @brand = find_brand
    authorize @brand
    if @brand.destroy
      redirect_to inventory_brands_path, notice: t("inventory.brands.destroyed")
    else
      redirect_to inventory_brands_path, alert: @brand.errors.full_messages.to_sentence
    end
  end

  private

  def find_brand
    policy_scope(Brand).find(params[:id])
  end

  def brand_params
    params.require(:brand).permit(:name)
  end
end
