module Inventory
  # A product's packaging chain (docs/inventory/multi_unit_nested_packaging_design.md §4): shown and
  # saved here, written only by Inventory::Packaging::Configurator.
  class ProductPackagingsController < BaseController
    def edit
      @product = find_product
      authorize @product, :configure_packaging?
      @levels = @product.active_packaging_levels.to_a
    end

    def update
      @product = find_product
      authorize @product, :configure_packaging?
      result = Inventory::Packaging::Configurator.new(product_id: @product.id, actor: current_user, levels: level_params).call
      if result.ok?
        redirect_to inventory_product_path(@product), notice: t("inventory.packaging.saved")
      else
        @levels = submitted_levels
        flash.now[:alert] = result.error
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def find_product
      policy_scope(Product).find(params[:id])
    end

    def level_params
      raw = params.fetch(:packaging, {}).permit(levels: %i[package_unit contains_quantity])[:levels] || {}
      raw.respond_to?(:values) ? raw.to_h.sort_by { |key, _| key.to_i }.map(&:last) : Array(raw)
    end

    # Re-renders exactly what was submitted.
    def submitted_levels
      level_params.each_with_index.map do |level, index|
        ProductPackagingLevel.new(position: index + 1, package_unit: level["package_unit"], contains_quantity: level["contains_quantity"])
      end
    end
  end
end
