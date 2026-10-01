class ShiftAssignmentsController < ApplicationController
  before_action :authenticate_user!

  PER_PAGE = 25

  # ── Index (tabs + filters + pagination) ────────────────────────────────────

  def index
    authorize ShiftAssignment, :index?

    full_scope = policy_scope(ShiftAssignment)

    # ── Summary counts — single SQL round-trip using conditional aggregation ──
    # Uses PG's FILTER aggregate instead of 4 separate COUNT queries.
    today = Date.current
    q_today = ActiveRecord::Base.connection.quote(today)
    stats_row = full_scope.unscope(:order).pick(Arel.sql(<<~SQL.squish))
      COUNT(*),
      COUNT(*) FILTER (WHERE effective_from <= #{q_today}
                       AND   (effective_to IS NULL OR effective_to >= #{q_today})),
      COUNT(*) FILTER (WHERE effective_from > #{q_today}),
      COUNT(*) FILTER (WHERE effective_to IS NOT NULL AND effective_to < #{q_today})
    SQL
    @stats = {
      total:    stats_row[0].to_i,
      active:   stats_row[1].to_i,
      upcoming: stats_row[2].to_i,
      expired:  stats_row[3].to_i
    }

    # ── Tab filter ────────────────────────────────────────────────────────────
    @tab = params[:tab].presence_in(%w[active upcoming expired all]) || "active"
    base = case @tab
           when "active"   then full_scope.current
           when "upcoming" then full_scope.upcoming
           when "expired"  then full_scope.expired
           else                 full_scope
           end

    # ── Column filters ────────────────────────────────────────────────────────
    if params[:q].present?
      q = "%#{params[:q]}%"
      base = base.joins(:user)
                 .where("users.first_name ILIKE :q OR users.last_name ILIKE :q " \
                        "OR users.employee_code ILIKE :q", q: q)
    end
    base = base.where(branch_id: params[:branch_id]) if params[:branch_id].present?
    if params[:shift_type].present?
      base = base.joins(:shift).where(shifts: { shift_type: params[:shift_type] })
    end
    base = base.where("effective_from >= ?", params[:from]) if params[:from].present?
    base = base.where("effective_from <= ?", params[:to])   if params[:to].present?
    base = base.from_template                               if params[:source] == "template"
    base = base.manual                                      if params[:source] == "manual"
    base = base.for_template(params[:template_id])          if params[:template_id].present?
    case params[:assignment_type]
    when "permanent"
      base = base.manual.where(effective_to: nil)
    when "temporary"
      base = base.where("effective_to IS NOT NULL OR source_template_id IS NOT NULL")
    end

    @active_filter_count = [ params[:q], params[:branch_id], params[:shift_type],
                              params[:from], params[:to],
                              params[:source], params[:template_id],
                              params[:assignment_type] ]
                             .count(&:present?)

    # ── Filter drop-down data ─────────────────────────────────────────────────
    @filter_branches  = Branch.for_business(current_user.business).active.order(:name)
    @filter_shifts    = Shift.for_business(current_user.business).active.order(:name)
    @filter_templates = ShiftTemplate.for_business(current_user.business).order(:name)

    # ── Pagination ────────────────────────────────────────────────────────────
    @page        = [ params[:page].to_i, 1 ].max
    @total_count = base.count
    @total_pages = [ (@total_count.to_f / PER_PAGE).ceil, 1 ].max
    @page        = [ @page, @total_pages ].min

    # Includes for eager loading.
    # SELECT also inlines a sub-exists for has_attendance so that
    # policy(a).destroy? / a.deletable? never fires per-row queries.
    @assignments = base
      .includes(:user, :shift, :branch, :created_by, :source_template)
      .select(
        "shift_assignments.*",
        Arel.sql(
          "EXISTS(SELECT 1 FROM attendance_records ar " \
          "WHERE ar.shift_assignment_id = shift_assignments.id LIMIT 1) AS has_attendance"
        )
      )
      .order(effective_from: :desc)
      .offset((@page - 1) * PER_PAGE)
      .limit(PER_PAGE)
  end

  # ── New / Create ────────────────────────────────────────────────────────────

  def new
    @assignment = ShiftAssignment.new(effective_from: Date.current)
    authorize @assignment
    load_form_data
  end

  def create
    @assignment = ShiftAssignment.new(assignment_params)
    @assignment.created_by = current_user
    authorize @assignment
    if assignment_resources_in_business? && assignment_employee_available? &&
       coverage_branch_allowed? && @assignment.save
      redirect_to shift_assignments_path, notice: t("flash.shift_assigned")
    else
      load_form_data
      render :new, status: :unprocessable_entity
    end
  end

  # ── Edit / Update ───────────────────────────────────────────────────────────

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

  # ── End assignment (set effective_to) ───────────────────────────────────────

  def confirm_end
    @assignment = policy_scope(ShiftAssignment).find(params[:id])
    authorize @assignment, :end_assignment?
  end

  def end
    @assignment = policy_scope(ShiftAssignment).find(params[:id])
    authorize @assignment, :end_assignment?

    ended_on_str = params.dig(:shift_assignment, :ended_on)
    end_date     = ended_on_str.present? ? Date.parse(ended_on_str) : nil

    if end_date.nil?
      @assignment.errors.add(:effective_to, :blank)
      render :confirm_end, status: :unprocessable_entity and return
    end

    if @assignment.update(effective_to: end_date, ended_by: current_user)
      redirect_to shift_assignments_path, notice: t("flash.assignment_ended")
    else
      render :confirm_end, status: :unprocessable_entity
    end
  rescue Date::Error
    @assignment.errors.add(:effective_to, :invalid)
    render :confirm_end, status: :unprocessable_entity
  end

  # ── Delete (hard-delete — only for assignments without attendance records) ──

  def confirm_delete
    @assignment = policy_scope(ShiftAssignment).find(params[:id])
    authorize @assignment, :destroy?
  end

  def destroy
    @assignment = policy_scope(ShiftAssignment).find(params[:id])
    authorize @assignment
    @assignment.destroy!
    redirect_to shift_assignments_path(tab: params[:return_tab].presence || "upcoming"),
                notice: t("flash.assignment_deleted")
  rescue ActiveRecord::InvalidForeignKey
    redirect_to shift_assignments_path,
                alert: t("shift_assignments.errors.cannot_delete_with_records")
  end

  # ── Bulk assign preview (JSON) ───────────────────────────────────────────────
  #
  # Called by the Stimulus controller before showing the bulk-assign modal.
  # Returns { valid: [...], conflicting: [...] } without persisting anything.

  def bulk_assign_preview
    authorize ShiftAssignment, :bulk_assign?

    ids      = Array(params[:employee_ids]).map(&:to_i).reject(&:zero?)
    shift_id = params[:shift_id].presence
    from_str = params[:effective_from].presence

    if ids.blank? || shift_id.blank? || from_str.blank?
      return render json: { error: "missing_params" }, status: :unprocessable_entity
    end

    from_date = Date.parse(from_str) rescue nil
    return render json: { error: "invalid_date" }, status: :unprocessable_entity if from_date.nil?

    shift = Shift.for_business(current_user.business).find_by(id: shift_id)
    return render json: { error: "shift_not_found" }, status: :not_found unless shift

    valid       = []
    conflicting = []

    policy_scope(User).where(id: ids).each do |user|
      test = ShiftAssignment.new(user: user, shift: shift, effective_from: from_date)
      if test.valid?
        valid << { id: user.id, name: user.full_name }
      else
        conflicting << {
          id:     user.id,
          name:   user.full_name,
          reason: test.errors.full_messages.first
        }
      end
    end

    render json: { valid: valid, conflicting: conflicting, total: ids.size }
  end

  # ── Bulk end (set effective_to = chosen date for multiple active records) ───

  def bulk_end
    authorize ShiftAssignment, :bulk_end?

    ids      = Array(params[:assignment_ids]).map(&:to_i).reject(&:zero?)
    end_date = parse_bulk_end_date

    if end_date.nil? || ids.empty?
      redirect_to shift_assignments_path,
                  alert: t("shift_assignments.bulk.end_date_required") and return
    end

    assignments = policy_scope(ShiftAssignment)
                    .where(id: ids)
                    .reject(&:future?)

    updated = 0
    assignments.each do |a|
      updated += 1 if a.update(effective_to: end_date, ended_by: current_user)
    end

    redirect_to shift_assignments_path(tab: "active"),
                notice: t("flash.assignments_bulk_ended", count: updated)
  end

  # ── Bulk assign (create new assignments for selected employees) ─────────────

  def bulk_assign
    authorize ShiftAssignment, :bulk_assign?

    ids      = Array(params[:employee_ids]).map(&:to_i).reject(&:zero?)
    shift_id = params.dig(:shift_assignment, :shift_id).presence
    branch_id = params.dig(:shift_assignment, :branch_id).presence
    from_str = params.dig(:shift_assignment, :effective_from).presence

    if ids.empty? || shift_id.nil? || from_str.nil?
      redirect_to shift_assignments_path,
                  alert: t("shift_assignments.bulk.assign_params_required") and return
    end

    from_date = Date.parse(from_str) rescue nil
    if from_date.nil?
      redirect_to shift_assignments_path,
                  alert: t("shift_assignments.bulk.assign_params_required") and return
    end

    # Both are resolved inside the current user's business: a foreign or
    # non-existent id is a 404, never a cross-business assignment.
    shift  = Shift.for_business(current_user.business).find(shift_id)
    branch = branch_id ? Branch.for_business(current_user.business).find(branch_id) : nil

    created = 0
    failed  = 0

    policy_scope(User).where(id: ids).each do |user|
      assignment = ShiftAssignment.new(
        user:           user,
        shift:          shift,
        branch:         branch,
        effective_from: from_date,
        created_by:     current_user
      )
      if assignment.save
        created += 1
      else
        failed += 1
        Rails.logger.info(
          "[ShiftAssignments#bulk_assign] Skipped user=#{user.id}: " \
          "#{assignment.errors.full_messages.join(', ')}"
        )
      end
    end

    notice = if failed.zero?
               t("flash.assignments_bulk_created", count: created)
             else
               t("flash.assignments_bulk_created_with_errors", count: created, failed: failed)
             end

    redirect_to shift_assignments_path, notice: notice
  end

  # ── Bulk delete (hard-delete only for deletable future assignments) ──────────

  def bulk_delete
    authorize ShiftAssignment, :bulk_delete?

    ids = Array(params[:assignment_ids]).map(&:to_i).reject(&:zero?)
    redirect_to shift_assignments_path and return if ids.empty?

    candidates = policy_scope(ShiftAssignment).where(id: ids).select(&:deletable?)
    deleted    = candidates.count
    candidates.each(&:destroy!)

    redirect_to shift_assignments_path(tab: "upcoming"),
                notice: t("flash.assignments_bulk_deleted", count: deleted)
  end

  private

  def parse_bulk_end_date
    str = params.dig(:shift_assignment, :ended_on).presence ||
          params[:ended_on].presence
    str ? Date.parse(str) : nil
  rescue Date::Error
    nil
  end

  def load_form_data
    @shifts        = Shift.for_business(current_user.business).active.order(:name)
    @rule_profiles = ShiftRuleProfile.for_business(current_user.business).active.order(:name)

    # Temporary coverage runs alongside the employee's regular assignment, so it
    # keeps picking from the manager's scoped employees.
    @employees = scoped_employees.order(:first_name, :last_name)

    # Regular assignments pick only from employees available for a new
    # assignment (see Shifts::AssignmentEligibility). Temporary coverage sends
    # an employee from their current branch to another one.
    if @assignment.new_record?
      @regular_candidates       = assignment_eligibility.candidates(regular_employee_pool)
      @availability_window_days = assignment_eligibility.window_days
      @coverage_branches        = coverage_target_branches.order(:name)
      @employee_current_branches = Shifts::AssignmentResolver
                                     .for_many(users: @employees)
                                     .transform_values { |a| a&.branch_name }
    end

    if effective_employee_scope == "business"
      @branches = Branch.for_business(current_user.business).active.order(:name)
    else
      branch_ids = current_user.managed_branch_ids +
                   current_user.area_managed_branch_ids +
                   BranchMembership.current_branch_ids(current_user)
      @branches = Branch.where(id: branch_ids.uniq).active.order(:name)
    end
  end

  # Every resource id supplied for a new assignment must resolve inside the
  # current user's business — an id is never trusted just because the record
  # exists (same rule as Shifts::Assigner on the API). A foreign id and a
  # non-existent id get the same error; blank ids are left to the model's own
  # validation.
  def assignment_resources_in_business?
    business = current_user.business
    {
      user_id:               [ business.users,                          :employee_not_in_business ],
      shift_id:              [ Shift.for_business(business),            :shift_not_in_business ],
      branch_id:             [ Branch.for_business(business),           :branch_not_in_business ],
      shift_rule_profile_id: [ ShiftRuleProfile.for_business(business), :shift_rule_profile_not_in_business ]
    }.each do |param, (scope, error)|
      id = assignment_params[param]
      @assignment.errors.add(:base, error) if id.present? && !scope.exists?(id: id)
    end

    @assignment.errors.empty?
  end

  # Server-side twin of the regular employee picker: a regular assignment may
  # only be created for an employee who is both selectable by this user and
  # available (no active assignment, or one ending within the window).
  # Temporary coverage keeps its existing rules.
  def assignment_employee_available?
    return true unless @assignment.regular?
    return true if @assignment.user_id.blank?
    return true if assignment_eligibility.eligible_users(regular_employee_pool)
                                         .exists?(id: @assignment.user_id)

    @assignment.errors.add(:base, :employee_not_available_for_assignment,
                           count: assignment_eligibility.window_days)
    false
  end

  # Temporary coverage stores its target in the assignment's own branch_id —
  # the employee's home branch stays on their untouched regular assignment. The
  # target may be any active branch in the business except the manager's own.
  def coverage_branch_allowed?
    return true unless @assignment.temporary_coverage?
    return true if @assignment.branch_id.blank? # model reports the missing branch
    return true if coverage_target_branches.exists?(id: @assignment.branch_id)

    @assignment.errors.add(:base, :coverage_branch_not_allowed)
    false
  end

  def coverage_target_branches
    own_branch_ids = current_user.managed_branch_ids +
                     BranchMembership.current_branch_ids(current_user)
    Branch.for_business(current_user.business).active.where.not(id: own_branch_ids)
  end

  # Resolve scope most-specific-first (assign_shifts → view_shifts → view_employees)
  # so a business-wide manager sees every employee and branch, not just their hierarchy.
  def effective_employee_scope
    current_user.scope_for(:assign_shifts) ||
      current_user.scope_for(:view_shifts) ||
      current_user.scope_for(:view_employees)
  end

  def scoped_employees
    EmployeeScope.new(current_user)
                 .for_permissions(:assign_shifts, :view_shifts, :view_employees)
                 .active
  end

  # Who a regular assignment may be created for, before eligibility. Employees
  # without an active assignment belong to no branch and employees transferring
  # in are still assigned elsewhere, so a manager's branch/area scope would hide
  # exactly the people they need — the pool is the business's active employees
  # and eligibility does the narrowing. A self-scoped user stays self-scoped.
  def regular_employee_pool
    return scoped_employees if effective_employee_scope == "self"

    current_user.business.users.active.where.not(id: current_user.id)
  end

  def assignment_eligibility
    @assignment_eligibility ||= Shifts::AssignmentEligibility.new(business: current_user.business)
  end

  def assignment_params
    params.require(:shift_assignment)
          .permit(:user_id, :shift_id, :branch_id, :effective_from, :effective_to,
                  :shift_rule_profile_id, :assignment_kind, :reason)
  end

  def update_params
    params.require(:shift_assignment).permit(:effective_to)
  end
end
