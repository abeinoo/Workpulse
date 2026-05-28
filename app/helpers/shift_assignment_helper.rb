module ShiftAssignmentHelper
  # ── Status badge ─────────────────────────────────────────────────────────────

  # Returns the CSS badge class (badge-success / badge-accent / badge-neutral)
  # for a shift assignment based on its effective dates relative to today.
  def timeline_status_badge(assignment)
    if assignment.future?
      "badge-accent"
    elsif assignment.current?
      "badge-success"
    else
      "badge-neutral"
    end
  end

  # Returns the i18n label string for an assignment's status.
  def timeline_status_label(assignment)
    if assignment.future?
      t("shift_assignments.upcoming")
    elsif assignment.current?
      t("shift_assignments.active")
    else
      t("shift_assignments.ended")
    end
  end

  # Returns the CSS modifier key used on timeline markers and cards.
  # Values: "active" | "upcoming" | "ended"
  def timeline_status_modifier(assignment)
    if assignment.future?
      "upcoming"
    elsif assignment.current?
      "active"
    else
      "ended"
    end
  end

  # ── Period label ─────────────────────────────────────────────────────────────

  # Returns a human-readable period string:
  #   "15 May 2026 – 31 Dec 2026"   (closed assignment)
  #   "15 May 2026 – ongoing"        (open-ended)
  def timeline_period_label(assignment)
    from = local_date(assignment.effective_from)
    if assignment.effective_to.present?
      t("shift_timeline.period.closed", from: from,
          to: local_date(assignment.effective_to))
    else
      t("shift_timeline.period.open", from: from)
    end
  end

  # ── Relative date ────────────────────────────────────────────────────────────

  # Returns a contextual relative-date string for an assignment:
  #   future  → "Starts in 3 days"  /  "Starts today"
  #   current → "Active for 45 days"  /  "Started today"
  #   ended   → "Ended 12 days ago"   /  "Ended today"
  def timeline_relative_date(assignment)
    today = Date.current

    if assignment.future?
      # future? guarantees effective_from > today, so days >= 1.
      days = (assignment.effective_from - today).to_i
      t("shift_timeline.starts_in", count: days)

    elsif assignment.current?
      days = (today - assignment.effective_from).to_i
      days == 0 ? t("shift_timeline.started_today")
                : t("shift_timeline.active_for", count: days)

    else
      days = (today - assignment.effective_to).to_i
      days == 0 ? t("shift_timeline.ended_today")
                : t("shift_timeline.ended_ago", count: days)
    end
  end

  # ── Timeline progress percentage ─────────────────────────────────────────────

  # Returns the percentage of the assignment period that has elapsed (0–100).
  # Open-ended assignments always return 100 (the bar renders as "full / ongoing").
  # Uses the preloaded effective_from/effective_to from the assignment record.
  def timeline_pct(assignment)
    from = assignment.effective_from
    to   = assignment.effective_to
    return 100 if to.nil?

    total   = (to - from).to_i
    return 100 if total <= 0

    elapsed = (Date.current - from).to_i.clamp(0, total)
    ((elapsed.to_f / total) * 100).round
  end

  # ── Temporary assignment expiry label ────────────────────────────────────────

  # Returns a human-readable string describing how much time remains (or has
  # elapsed) relative to an assignment's effective_to date.
  # Returns nil when the assignment has no end date.
  #
  # Examples (EN):
  #   "Expires today"          — effective_to == today
  #   "Expires tomorrow"       — 1 day left
  #   "Ends in 5 days"         — 2–7 days left
  #   "Until 31 Mar 2026"      — 8+ days left
  #   "Expired 3 days ago"     — already ended
  def temporary_expiry_label(assignment)
    return nil unless assignment.effective_to.present?
    days = assignment.days_until_expiry
    if days < 0
      t("shift_assignments.temporary.expired_days_ago", count: days.abs)
    elsif days == 0
      t("shift_assignments.temporary.expires_today")
    elsif days == 1
      t("shift_assignments.temporary.expires_tomorrow")
    elsif days <= 7
      t("shift_assignments.temporary.expires_in_days", count: days)
    else
      t("shift_assignments.temporary.active_until", date: local_date(assignment.effective_to))
    end
  end

  # ── Assignment type label + badge ────────────────────────────────────────────

  # Returns a human-readable type label for an assignment:
  #   template-sourced → template name (e.g. "Ramadan", "Summer Coverage")
  #   manual temporary → "Temporary"
  #   permanent        → "Permanent"
  def assignment_type_label(assignment)
    if assignment.source_template.present?
      assignment.source_template.name
    elsif assignment.temporary?
      t("shift_assignments.type.temporary")
    else
      t("shift_assignments.type.permanent")
    end
  end

  # Returns the CSS class for the assignment type badge.
  def assignment_type_badge_class(assignment)
    if assignment.source_template.present?
      "badge-type-named"
    elsif assignment.temporary?
      "badge-type-temporary"
    else
      "badge-type-permanent"
    end
  end

  # ── Shift hours label ────────────────────────────────────────────────────────

  # "09:00 – 17:00" for fixed_time shifts (with overnight note when applicable).
  # "8h flexible"   for hour_based shifts.
  def timeline_shift_hours(shift)
    if shift.fixed_time?
      start_str = shift.start_time.strftime("%H:%M")
      end_str   = shift.end_time.strftime("%H:%M")
      base = "#{start_str} – #{end_str}"
      shift.overnight? ? "#{base} (#{t('shifts.overnight_badge').downcase})" : base
    else
      t("shift_timeline.flexible_hours", hours: shift.required_hours.to_i)
    end
  end
end
