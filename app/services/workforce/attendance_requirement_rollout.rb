module Workforce
  # The per-business switch of the attendance requirement rollout (R3.2;
  # attendance plan revision 19, OD-2, OD-5). While it is off — always, in R3.2 —
  # employee creation behaves exactly as before and the HR requirement change
  # screen is refused. R3.3 turns it on, through an audited operational task,
  # after the backfill; nothing in R3.2 writes it.
  #
  # Stored in businesses.settings (an Organization & Access column that holds
  # other domains' settings, module-boundaries §11) as the date the rollout
  # starts, compared with the business day.
  module AttendanceRequirementRollout
    SETTING = "attendance_requirements_enabled_on".freeze

    module_function

    def active?(business, on: BusinessDay.current(context: business))
      starts_on = enabled_on(business)
      starts_on.present? && starts_on <= on
    end

    def enabled_on(business)
      value = (business.settings || {})[SETTING]
      value.present? ? Date.iso8601(value.to_s) : nil
    rescue Date::Error
      nil
    end
  end
end
