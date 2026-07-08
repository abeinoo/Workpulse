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


  # Colored status badge for an employee/user. Reusable across index/show
  # pages. The model only tracks an `active` boolean today; suspended/terminated
  # are not modelled, so we map active → green, inactive → red.
  def user_status_badge(user)
    css, key = user.active? ? ["badge-success", "active"] : ["badge-danger", "inactive"]
    content_tag(:span, t("admin.users.#{key}"), class: "badge #{css}")
  end

  # Registration status badge — distinct from active/inactive. Indicates whether
  # the employee has completed account registration (set a password). Mirrors the
  # `encrypted_password` check already used on the employee show page. The column
  # is already loaded by the index scope, so this introduces no N+1 query.
  def registration_status_badge(user)
    if user.encrypted_password.present?
      content_tag(:span, t("admin.users.registered"), class: "badge badge-success")
    else
      content_tag(:span, t("admin.users.pending_registration"), class: "badge badge-warning")
    end
  end

  # "Quick call" phone button for an employee row. When a phone number exists it
  # becomes a tel: link that dials on mobile; otherwise it renders disabled with
  # an explanatory tooltip.
  def quick_call_button(user)
    icon = tag.svg(
      tag.path(d: "M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.9.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92z"),
      width: "15", height: "15", viewBox: "0 0 24 24", fill: "none",
      stroke: "currentColor", "stroke-width": "2", "stroke-linecap": "round",
      "stroke-linejoin": "round", "aria-hidden": "true"
    )

    if user.phone_number.present?
      label = t("admin.users.call_employee", name: user.full_name)
      link_to "tel:#{user.phone_number}", class: "btn btn-icon btn-ghost btn-sm",
              title: label, "aria-label": label do
        icon
      end
    else
      content_tag(:span, icon, class: "btn btn-icon btn-ghost btn-sm",
                  "aria-disabled": "true", title: t("admin.users.no_phone"),
                  "aria-label": t("admin.users.no_phone"))
    end
  end

  # Summarises a permission request (early_leave / late_permission) for display:
  #   { minutes: Integer, time: "HH:MM" or nil }
  # For early_leave the time is the requested departure (shift end − duration);
  # for late_permission it's the requested arrival (shift start + duration).
  # `time` is nil when the employee has no fixed-time shift on that date.
  def requested_permission_summary(request)
    minutes = request.duration_minutes.to_i
    shift   = ShiftAssignment.active_on(request.requested_for_date)
                             .find_by(user_id: request.user_id)&.shift
    base = nil
    if shift&.fixed_time?
      base = shift.end_time   - minutes.minutes if request.early_leave?
      base = shift.start_time + minutes.minutes if request.late_permission?
    end
    { minutes: minutes, time: base&.strftime("%H:%M") }
  end

  def request_status_badge_class(request)
    return "badge-warning" if employee_request_awaiting_payment?(request)

    case request.status
    when "pending"    then "badge-warning"
    when "approved"   then "badge-success"
    when "rejected"   then "badge-danger"
    when "paid"       then "badge-success"
    when "cancelled"  then "badge-neutral"
    else                   "badge-neutral"
    end
  end

  def request_status_label(request)
    if employee_request_awaiting_payment?(request)
      t("requests.statuses.approved_awaiting_payment")
    else
      t("requests.statuses.#{request.status}")
    end
  end

  def employee_request_awaiting_payment?(request)
    request.respond_to?(:salary_advance?) &&
      request.approved? &&
      request.salary_advance? &&
      request.advance.nil?
  end

  def period_status_badge_class(period_or_status)
    status = period_or_status.respond_to?(:status) ? period_or_status.status : period_or_status.to_s
    case status
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

  SOURCE_ICONS = {
    "mobile"           => "📱",
    "biometric_device" => "🖐️",
    "import"           => "📥",
    "admin_manual"     => "✍️",
    "api"              => "⚙️"
  }.freeze

  def attendance_source_badge(source, html_class: "attn-source-badge")
    return "" if source.blank?
    icon  = SOURCE_ICONS.fetch(source, "•")
    label = t("attendance.sources.#{source}", default: source.humanize)
    content_tag(:span, "#{icon} #{label}".html_safe,
                class: "#{html_class} attn-source-badge--#{source.tr('_', '-')}")
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

  # ── Centralized time/date display ─────────────────────────────────────────
  # All attendance/payroll times must go through these helpers so timezone
  # conversions are consistent and format changes only need to happen here.

  def current_business_timezone
    @_biz_tz ||= current_user&.business&.timezone_object || Time.zone
  end

  # "14:30"  (locale-neutral: HH:MM is universal)
  def local_time(value, fallback: "—")
    return fallback if value.nil?
    value.in_time_zone(current_business_timezone).strftime("%H:%M")
  end

  # Locale-aware datetime: "Jun 5, 2026 14:30" / "5 يونيو 2026 14:30"
  def local_datetime(value, fallback: "—")
    return fallback if value.nil?
    I18n.l(value.in_time_zone(current_business_timezone))
  rescue StandardError
    fallback
  end

  # Locale-aware date: "Jun 5, 2026" / "5 يونيو 2026"
  def local_date(value, fallback: "—")
    return fallback if value.nil?
    d = value.respond_to?(:in_time_zone) ? value.in_time_zone(current_business_timezone).to_date : value
    I18n.l(d)
  rescue StandardError
    fallback
  end

  # Short locale-aware date: "5 Jun" / "5 يون"
  def local_short_date(value, fallback: "—")
    return fallback if value.nil?
    d = value.respond_to?(:in_time_zone) ? value.in_time_zone(current_business_timezone).to_date : value
    I18n.l(d, format: :short)
  rescue StandardError
    fallback
  end

  # For datetime-local HTML inputs — must show local time, not UTC
  def local_datetime_input(value, default: nil)
    t = value || default || Time.current
    t.in_time_zone(current_business_timezone).strftime("%Y-%m-%dT%H:%M")
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

  # Same figures as format_currency, split so a caller can stack them (small
  # currency code above/below a large bold amount) instead of one inline string.
  # Returns [currency_symbol, formatted_amount].
  def format_currency_parts(amount, precision: 2)
    return [ nil, "—" ] if amount.nil?
    business = current_user&.business
    code     = business&.currency.presence || "SAR"
    info     = Business::CURRENCIES[code] || Business::CURRENCIES["SAR"]
    num      = number_with_precision(amount.to_f, precision: precision, delimiter: ",", separator: ".")
    symbol   = I18n.locale.to_s == "ar" ? info[:symbol] : info[:symbol_en]
    [ symbol, num ]
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

  # Renders the "OT Override" badge for an entry whose payable overtime has been
  # overridden, or nil otherwise. `stale: true` adds a re-review hint after a
  # regeneration changed the calculated value underneath the override.
  def overtime_override_badge(entry)
    return unless entry.overtime_overridden?

    classes = "payroll-entry-badge payroll-entry-badge--info"
    classes += " payroll-entry-badge--stale" if entry.overtime_override_stale?
    label = entry.overtime_override_stale? ? t("payroll.overtime_override.badge_stale")
                                           : t("payroll.overtime_override.badge")
    content_tag(:span, label, class: classes,
                title: t("payroll.overtime_override.badge_title",
                         calculated: format_minutes(entry.calculated_overtime_minutes),
                         approved:   format_minutes(entry.payable_overtime_minutes)))
  end

  # Returns a CSS modifier key for a branch health score (0–100).
  def branch_health_grade(score)
    case score
    when 85..100 then "excellent"
    when 65..84  then "good"
    when 45..64  then "fair"
    else              "poor"
    end
  end

  # Returns a CSS modifier for a performance grade symbol.
  def performance_grade_class(grade)
    { excellent: "success", good: "accent", fair: "warning", poor: "danger" }
      .fetch(grade.to_sym, "neutral")
  end
end
