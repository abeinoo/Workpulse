module ShiftTemplateHelper
  # Translates a conflict reason (symbol or error string) to a human-readable label.
  def conflict_reason_label(reason)
    return "" if reason.blank?

    key = "shift_templates.conflicts.#{reason}"
    I18n.exists?(key) ? t(key) : reason.to_s
  end
end
