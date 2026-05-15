class ShiftAssignmentsController < ApplicationController
  before_action :authenticate_user!

  def index
    @assignments = policy_scope(ShiftAssignment)
                     .includes(:user, :shift, :branch)
                     .order(effective_from: :desc)
  end

  def new
    @assignment = ShiftAssignment.new(effective_from: Date.current)
    authorize @assignment
    load_form_data
  end

  def create
    @assignment = ShiftAssignment.new(assignment_params)
    authorize @assignment
    if @assignment.save
      redirect_to shift_assignments_path, notice: t("flash.shift_assigned")
    else
      load_form_data
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @assignment = policy_scope(ShiftAssignment).find(params[:id])
    authorize @assignment
    load_form_data
  end

  def update
    @assignment = policy_scope(ShiftAssignment).find(params[:id])
    authorize @assignment
    if @assignment.update(update_params)
      redirect_to shift_assignments_path, notice: t("flash.assignment_updated")
    else
      load_form_data
      render :edit, status: :unprocessable_entity
    end
  end

  def confirm_end
    @assignment = policy_scope(ShiftAssignment).find(params[:id])
    authorize @assignment, :end_assignment?
  end

  def end
    @assignment = policy_scope(ShiftAssignment).find(params[:id])
    authorize @assignment, :end_assignment?

    ended_on_str = params.dig(:shift_assignment, :ended_on)
    end_date = ended_on_str.present? ? Date.parse(ended_on_str) : nil

    if end_date.nil?
      @assignment.errors.add(:effective_to, :blank)
      render :confirm_end, status: :unprocessable_entity and return
    end

    if @assignment.update(effective_to: end_date)
      redirect_to shift_assignments_path, notice: t("flash.assignment_ended")
    else
      render :confirm_end, status: :unprocessable_entity
    end
  rescue Date::Error
    @assignment.errors.add(:effective_to, :invalid)
    render :confirm_end, status: :unprocessable_entity
  end

  private

  def load_form_data
    @shifts = Shift.for_business(current_user.business).active.order(:name)
    if current_user.super_admin?
      @employees = User.where(business: current_user.business)
                       .where(role: %w[employee branch_manager])
                       .where(active: true)
                       .order(:first_name, :last_name)
      @branches = Branch.for_business(current_user.business).active.order(:name)
    else
      @employees = User.joins(:user_branches)
                       .where(user_branches: { branch_id: current_user.branch_ids })
                       .where(role: "employee")
                       .where(active: true)
                       .distinct
                       .order(:first_name, :last_name)
      @branches = current_user.branches.active.order(:name)
    end
  end

  def assignment_params
    params.require(:shift_assignment).permit(:user_id, :shift_id, :branch_id, :effective_from, :effective_to)
  end

  def update_params
    params.require(:shift_assignment).permit(:effective_to)
  end
end
