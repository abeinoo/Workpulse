# Presentation helpers for the Inventory Products index (filters, active
# filter chips, stock state). Display only — the figures come from
# Inventory::ProductsController#index.
module ProductsIndexHelper
  PRODUCTS_INDEX_FILTERS = %i[q category_id brand_id stock_status].freeze

  # The index's current query (status tab + filters), with overrides; blank
  # values dropped so links stay clean.
  def products_index_query(overrides = {})
    params.permit(:status, *PRODUCTS_INDEX_FILTERS).to_h.symbolize_keys.merge(overrides).compact_blank
  end

  def products_index_filtered?
    PRODUCTS_INDEX_FILTERS.any? { |key| params[key].present? }
  end

  # [[label, url_without_that_filter], ...] for the active-filter chips.
  def products_index_filter_chips(categories:, brands:)
    chips = []
    chips << [ t("inventory.products.index.chip_search", term: params[:q]), :q ] if params[:q].present?
    if (category = params[:category_id].presence && categories.find { |c| c.id.to_s == params[:category_id].to_s })
      chips << [ "#{t("inventory.products.category")}: #{category.name}", :category_id ]
    end
    if (brand = params[:brand_id].presence && brands.find { |b| b.id.to_s == params[:brand_id].to_s })
      chips << [ "#{t("inventory.products.brand")}: #{brand.name}", :brand_id ]
    end
    if (status = params[:stock_status].presence_in(Inventory::ProductsController::STOCK_STATUSES))
      chips << [ t("inventory.products.index.stock_status.#{status}"), :stock_status ]
    end
    chips.map { |label, key| [ label, inventory_products_path(products_index_query.except(key)) ] }
  end

  # :untracked, :out (on-hand <= 0 — the Current Stock report's rule), :low
  # (the list's per-warehouse low-stock badge) or :in.
  def product_stock_state(product, stock, low_stock)
    return :untracked unless product.track_inventory?
    return :out if stock.to_d <= 0
    return :low if low_stock

    :in
  end
end
