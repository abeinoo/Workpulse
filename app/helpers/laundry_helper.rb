module LaundryHelper
  TOWEL_BALANCE_STATUS_PRECEDENCE = %i[needs_attention low_stock in_transit good].freeze

  TOWEL_BALANCE_BADGE_CLASS = {
    good: "badge-success", low_stock: "badge-warning",
    in_transit: "badge-accent", needs_attention: "badge-danger"
  }.freeze

  # Presentational classification only — derived from the row's already-computed
  # figures (see Laundry::TowelBalances), never a stored value or a new query.
  def towel_balance_row_status(row)
    is_laundry = row[:branch].branch_type_laundry?
    unexpected = is_laundry ? row[:clean] : row[:dirty]

    return :needs_attention if unexpected.nonzero?
    return :low_stock if row[:operational] <= 0
    return :in_transit if row[:in_transit_out].positive?

    :good
  end

  def towel_balance_status_label(status)
    t("laundry.balances.status_#{status}")
  end

  def towel_balance_status_badge_class(status)
    TOWEL_BALANCE_BADGE_CLASS.fetch(status, "badge-neutral")
  end

  # Worst status across every branch row for a towel type — used by the
  # compact "All" overview, where one badge summarizes the whole type.
  def towel_balance_overview_status(rows)
    statuses = rows.map { |row| towel_balance_row_status(row) }
    TOWEL_BALANCE_STATUS_PRECEDENCE.find { |status| statuses.include?(status) } || :good
  end

  def towel_balance_total_quantity(rows)
    rows.sum { |row| row[:operational] }
  end

  def towel_balance_total_in_transit(rows)
    rows.sum { |row| row[:in_transit_out] }
  end

  def towel_balance_branches_with_issues(rows)
    rows.select { |row| %i[needs_attention low_stock].include?(towel_balance_row_status(row)) }
        .map { |row| row[:branch].id }.uniq.count
  end

  def towel_balance_rows_all_zero?(rows)
    rows.all? do |row|
      %i[operational in_transit_out clean dirty damaged disposed lost].all? { |key| row[key].zero? }
    end
  end
end
