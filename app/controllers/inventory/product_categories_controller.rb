class Inventory::ProductCategoriesController < Inventory::BaseController
  def index
    authorize ProductCategory
    @categories = policy_scope(ProductCategory).ordered.left_joins(:products)
                                               .select("product_categories.*, COUNT(products.id) AS products_count")
                                               .group("product_categories.id")
  end

  def new
    @category = current_user.business.product_categories.build
    authorize @category
  end

  def create
    @category = current_user.business.product_categories.build(category_params)
    authorize @category
    if @category.save
      redirect_to inventory_product_categories_path, notice: t("inventory.product_categories.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @category = find_category
    authorize @category
  end

  def update
    @category = find_category
    authorize @category
    if @category.update(category_params)
      redirect_to inventory_product_categories_path, notice: t("inventory.product_categories.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @category = find_category
    authorize @category
    if @category.destroy
      redirect_to inventory_product_categories_path, notice: t("inventory.product_categories.destroyed")
    else
      redirect_to inventory_product_categories_path, alert: @category.errors.full_messages.to_sentence
    end
  end

  private

  def find_category
    policy_scope(ProductCategory).find(params[:id])
  end

  def category_params
    params.require(:product_category).permit(:name)
  end
end
