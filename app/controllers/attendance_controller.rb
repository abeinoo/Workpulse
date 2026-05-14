class AttendanceController < ApplicationController
  before_action :authenticate_user!

  def check_in
    branch = resolve_branch
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
    branch = resolve_branch

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

  # Returns the branch when branch_id is supplied; nil for branchless employees.
  # Looks up via user_branches first, then falls back to an active ShiftAssignment
  # so that employees assigned via shift (no static user_branch row) can check in.
  def resolve_branch
    return nil unless params[:branch_id].present?

    current_user.branches.find_by(id: params[:branch_id]) ||
      ShiftAssignment.current
                     .where(user: current_user, branch_id: params[:branch_id])
                     .first&.branch
  end
end
