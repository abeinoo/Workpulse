module FinanceHelper
  SETTLEMENT_TYPE_BADGES = {
    "cash"    => "badge-info",
    "card"    => "badge-primary",
    "ewallet" => "badge-warning",
    "voucher" => "badge-secondary",
    "other"   => ""
  }.freeze

  def settlement_type_badge_class(type)
    SETTLEMENT_TYPE_BADGES.fetch(type.to_s, "")
  end
end
