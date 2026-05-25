module ApplicationHelper
  # IANA timezone identifiers pinned to the top of the timezone select.
  TIMEZONE_PRIORITY = %w[
    Asia/Riyadh Asia/Kuwait Asia/Bahrain Asia/Qatar Asia/Dubai Asia/Muscat
    Africa/Cairo Africa/Johannesburg
    Asia/Amman Asia/Beirut Asia/Jerusalem
    Europe/London Europe/Paris Europe/Berlin
    America/New_York America/Chicago America/Los_Angeles
    UTC
  ].freeze

  # Returns grouped_options_for_select with priority Middle East / common zones
  # first, then all zones. Values are always IANA identifiers so they match what
  # the database stores.
  def timezone_select_options(selected)
    priority = TIMEZONE_PRIORITY.filter_map do |iana|
      zone = ActiveSupport::TimeZone[iana]
      zone ? [zone.to_s, zone.tzinfo.identifier] : nil
    end

    all = ActiveSupport::TimeZone.all.map { |z| [z.to_s, z.tzinfo.identifier] }

    grouped_options_for_select(
      [["Common Timezones", priority], ["All Timezones", all]],
      selected
    )
  end


  def request_status_badge_class(request)
    case request.status
    when "approved" then "badge-success"
    when "rejected" then "badge-danger"
    when "paid"     then "badge-accent"
    else                 "badge-neutral"
    end
  end

  def period_status_badge_class(period)
    case period.status
    when "paid"                    then "badge-success"
    when "finalized"               then "badge-accent"
    when "branch_review_completed" then "badge-warning"
    when "under_review"            then "badge-warning"
    else                                "badge-neutral"
    end
  end

  # Generic line-item badge (used for additions/overtimes).
  def line_item_review_badge_class(line_item)
    case line_item.review_status
    when "approved" then "badge-success"
    when "rejected" then "badge-neutral"
    when "waived"   then "badge-accent"
    else                 "badge-warning"
    end
  end

  # Deduction-specific badge: waived and rejected shown differently so the
  # employee can clearly see when a penalty was excused.
  def deduction_status_badge_class(item)
    case item.review_status
    when "approved"       then "badge-danger"
    when "waived"         then "badge-success"
    when "rejected"       then "badge-neutral"
    when "pending_review" then "badge-warning"
    else                       "badge-warning"
    end
  end

  def adjustment_type_badge_class(adj)
    if PayrollAdjustment::POSITIVE_TYPES.include?(adj.adjustment_type)
      "badge-success"
    else
      "badge-danger"
    end
  end

  # Inline SVG icon for an adjustment type — used in the new adj-type-badge pill.
  def adj_type_icon(type)
    svg = case type.to_s
          when "cash_incentive"
            '<polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/>'
          when "commission"
            '<line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>'
          when "penalty"
            '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>'
          else
            '<polyline points="23 18 13.5 8.5 8.5 13.5 1 6"/><polyline points="17 18 23 18 23 12"/>'
          end
    raw(%(<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{svg}</svg>))
  end

  def adjustment_status_badge_class(adj)
    case adj.review_status
    when "approved"      then "badge-success"
    when "rejected"      then "badge-danger"
    when "pending_review" then "badge-warning"
    else                      "badge-neutral"
    end
  end

  def attendance_status_badge_class(record)
    case record.status
    when "present"     then "badge-success"
    when "late"        then "badge-warning"
    when "early_leave" then "badge-warning"
    when "absent"      then "badge-danger"
    else                    "badge-neutral"
    end
  end

  def punch_log_badge_class(action)
    case action
    when "check_in", "check_in_updated" then "badge-success"
    when "check_out"                    then "badge-accent"
    when "rejected_spam"                then "badge-neutral"
    when "rejected_no_assignment"       then "badge-warning"
    when "rejected_not_allowed"         then "badge-danger"
    when "error"                        then "badge-danger"
    else                                     "badge-neutral"
    end
  end

  def import_status_badge(status)
    case status.to_s
    when "completed" then "badge-success"
    when "pending"   then "badge-warning"
    when "failed"    then "badge-neutral"
    else                  "badge-neutral"
    end
  end

  def obligation_status_badge(status)
    case status.to_s
    when "active"    then "badge-success"
    when "paused"    then "badge-warning"
    when "completed" then "badge-accent"
    when "cancelled" then "badge-neutral"
    else                  "badge-neutral"
    end
  end

  # Formats a monetary amount using the current user's business currency.
  # In Arabic locale: "1,500 ر.س"; in English: "SAR 1,500.00"
  # precision: keyword controls decimal places (default 2; pass 0 for whole numbers).
  def format_currency(amount, precision: 2)
    return "—" if amount.nil?
    business = current_user&.business
    code     = business&.currency.presence || "SAR"
    info     = Business::CURRENCIES[code] || Business::CURRENCIES["SAR"]
    num      = number_with_precision(amount.to_f, precision: precision, delimiter: ",", separator: ".")
    I18n.locale.to_s == "ar" ? "#{num} #{info[:symbol]}" : "#{info[:symbol_en]} #{num}"
  end

  # Formats a minutes integer as "Xh Ym" (e.g. 90 → "1h 30m").
  # Returns "—" for nil/zero.
  def format_minutes(minutes)
    minutes = minutes.to_i
    return "—" if minutes <= 0

    hours = minutes / 60
    mins  = minutes % 60
    parts = []
    parts << "#{hours}h" if hours > 0
    parts << "#{mins}m"  if mins  > 0
    parts.join(" ")
  end
end
