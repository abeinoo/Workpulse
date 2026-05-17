class AttendanceController < ApplicationController
  before_action :authenticate_user!

  def check_in
    branch = resolve_checkin_branch
    return redirect_to(root_path, alert: t("flash.branch_not_found")) if params[:branch_id].present? && branch.nil?

    result = Attendance::CheckInService.call(
      user:      current_user,
      branch:    branch,
      latitude:  params[:latitude].presence,
      longitude: params[:longitude].presence
    )

    if result.success?
      redirect_to root_path, notice: t("flash.checked_in", time: result.record.check_in_at.strftime("%H:%M"))
    else
      redirect_to root_path, alert: result.error
    end
  end

  def check_out
    branch = resolve_checkout_branch

    result = Attendance::CheckOutService.call(
      user:      current_user,
      branch:    branch,
      latitude:  params[:latitude].presence,
      longitude: params[:longitude].presence
    )

    if result.success?
      redirect_to root_path, notice: t("flash.checked_out", time: result.record.check_out_at.strftime("%H:%M"), minutes: result.record.worked_minutes)
    else
      redirect_to root_path, alert: result.error
    end
  end

  private

  # Branch eligibility at check-in must come from an active ShiftAssignment.
  # Permanent user_branches are not used — branch context is shift-driven.
  def resolve_checkin_branch
    return nil unless params[:branch_id].present?

    ShiftAssignment.current
                   .where(user: current_user, branch_id: params[:branch_id])
                   .first&.branch
  end

  # At check-out the shift assignment was already validated at check-in time.
  # We only need the branch object for geolocation validation, so look it up directly.
  def resolve_checkout_branch
    return nil unless params[:branch_id].present?

    Branch.active.find_by(id: params[:branch_id], business: current_user.business)
  end
end
