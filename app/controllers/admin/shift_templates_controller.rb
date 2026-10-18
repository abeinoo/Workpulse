class Admin::ShiftTemplatesController < Admin::BaseController
  # ── Index ────────────────────────────────────────────────────────────────────

  def index
    authorize ShiftTemplate, :index?
    @tab       = params[:tab].presence_in(%w[active archived]) || "active"
    base_scope = policy_scope(ShiftTemplate)
    @templates = (@tab == "archived" ? base_scope.archived : base_scope.active)
                 .includes(:created_by, :entries)
                 .order(:name)
  end

  # ── Show ─────────────────────────────────────────────────────────────────────

  def show
    @template = find_template
    authorize @template
    @entries  = @template.entries.includes(:shift, :rule_profile).order(:starts_on)

    generated = @template.generated_assignments
    @analytics = {
      total:              generated.count,
      active_count:       generated.current.count,
      employees_affected: generated.select(:user_id).distinct.count,
      last_applied_at:    generated.maximum(:created_at)
    }
  end

  # ── New / Create ─────────────────────────────────────────────────────────────

  def new
    @template = ShiftTemplate.new
    @template.entries.build
    authorize @template
    load_form_data
  end

  def create
    @template             = ShiftTemplate.new(template_params)
    @template.business    = current_user.business
    @template.created_by  = current_user
    authorize @template

    if @template.save
      redirect_to admin_shift_template_path(@template),
                  notice: t("flash.shift_template_created")
    else
      load_form_data
      render :new, status: :unprocessable_entity
    end
  end

  # ── Edit / Update ─────────────────────────────────────────────────────────────

  def edit
    @template = find_template
    authorize @template
    load_form_data
  end

  def update
    @template = find_template
    authorize @template

    if @template.update(template_params)
      redirect_to admin_shift_template_path(@template),
                  notice: t("flash.shift_template_updated")
    else
      load_form_data
      render :edit, status: :unprocessable_entity
    end
  end

  # ── Archive / Unarchive ──────────────────────────────────────────────────────

  def archive
    @template = find_template
    authorize @template
    @template.archive!
    redirect_to admin_shift_templates_path,
                notice: t("flash.shift_template_archived")
  end

  def unarchive
    @template = find_template
    authorize @template
    @template.unarchive!
    redirect_to admin_shift_templates_path(tab: "archived"),
                notice: t("flash.shift_template_unarchived")
  end

  # ── Apply flow ───────────────────────────────────────────────────────────────

  def apply
    @template = find_template
    authorize @template
    load_apply_data
  end

  def preview_apply
    @template = find_template
    authorize @template, :apply?

    employee_ids = selected_employee_ids
    @employees   = scoped_employees.where(id: employee_ids)

    if @template.entries.empty?
      flash.now[:alert] = t("shift_templates.apply.no_entries")
      load_apply_data
      render :apply, status: :unprocessable_entity and return
    end

    if employee_ids.empty?
      flash.now[:alert] = t("shift_templates.apply.no_employees_selected")
      load_apply_data
      render :apply, status: :unprocessable_entity and return
    end

    unless all_selected_in_scope?(@employees, employee_ids)
      flash.now[:alert] = t("shift_templates.apply.employees_not_allowed")
      load_apply_data
      render :apply, status: :unprocessable_entity and return
    end

    @branch = selected_branch
    unless @branch
      flash.now[:alert] = branch_error_message
      load_apply_data
      render :apply, status: :unprocessable_entity and return
    end

    @preview_rows = Scheduling::TemplatePreviewer.call(
      template:  @template,
      employees: @employees,
      branch:    @branch
    )
  end

  def apply_confirm
    @template    = find_template
    authorize @template, :apply?

    employee_ids = selected_employee_ids
    employees    = scoped_employees.where(id: employee_ids)

    if employee_ids.empty?
      redirect_to apply_admin_shift_template_path(@template),
                  alert: t("shift_templates.apply.no_employees_selected") and return
    end

    # Any selected employee outside the actor's scope refuses the whole
    # application before anything is written — never a silent partial apply.
    unless all_selected_in_scope?(employees, employee_ids)
      redirect_to apply_admin_shift_template_path(@template),
                  alert: t("shift_templates.apply.employees_not_allowed") and return
    end

    # Resolved before anything is written: a missing, foreign or out-of-scope
    # branch creates no assignments at all.
    branch = selected_branch
    unless branch
      redirect_to apply_admin_shift_template_path(@template), alert: branch_error_message and return
    end

    result = Scheduling::TemplateApplier.call(
      template:   @template,
      employees:  employees,
      branch:     branch,
      created_by: current_user
    )

    if result.row_errors.any?
      redirect_to admin_shift_template_path(@template),
                  alert: t("shift_templates.apply.partial_success",
                           created: result.created, skipped: result.skipped,
                           errors:  result.row_errors.size)
    else
      redirect_to admin_shift_template_path(@template),
                  notice: t("shift_templates.apply.success",
                            created: result.created, skipped: result.skipped)
    end
  end

  private

  def find_template
    policy_scope(ShiftTemplate).find(params[:id])
  end

  def load_form_data
    @shifts        = Shift.where(business: current_user.business).active.order(:name)
    @rule_profiles = ShiftRuleProfile.for_business(current_user.business).active.order(:name)
  end

  def load_apply_data
    @all_employees = scoped_employees.order(:first_name, :last_name)
    @branches      = assignable_branches.order(:name)
  end

  # The branch every assignment of this application is created at. Only a
  # branch the actor may assign shifts to resolves; a blank, foreign,
  # inactive or out-of-scope id resolves to nil.
  def selected_branch
    id = params[:branch_id].presence
    id && assignable_branches.find_by(id: id)
  end

  def branch_error_message
    key = params[:branch_id].present? ? "branch_not_allowed" : "branch_required"
    t("shift_templates.apply.#{key}")
  end

  # Branches the actor may assign shifts to — the same set the Assign Shift form
  # offers (ShiftAssignmentsController#load_form_data): every active branch for a
  # business-wide scope, otherwise the branches they manage, area-manage or
  # currently belong to.
  def assignable_branches
    business = current_user.business
    scope = current_user.scope_for(:assign_shifts) ||
            current_user.scope_for(:view_shifts) ||
            current_user.scope_for(:view_employees)
    return Branch.for_business(business).active if scope == "business"

    branch_ids = current_user.managed_branch_ids +
                 current_user.area_managed_branch_ids +
                 BranchMembership.current_branch_ids(current_user)
    Branch.for_business(business).active.where(id: branch_ids.uniq)
  end

  # The employees this user may apply a template to — the same pool the Assign
  # Shift form uses (ShiftAssignmentsController#scoped_employees): the first
  # explicitly configured data scope among assign_shifts / view_shifts /
  # view_employees, otherwise the hierarchy (owner → whole business; managers →
  # the branches they manage or area-manage).
  def scoped_employees
    EmployeeScope.new(current_user)
                 .for_permissions(:assign_shifts, :view_shifts, :view_employees)
                 .active
  end

  def selected_employee_ids
    Array(params[:employee_ids]).map(&:to_i).reject(&:zero?).uniq
  end

  def all_selected_in_scope?(employees, employee_ids)
    employees.count == employee_ids.size
  end

  def template_params
    params.require(:shift_template).permit(
      :name, :description, :active,
      entries_attributes: [
        :id, :shift_id, :starts_on, :ends_on,
        :shift_rule_profile_id, :_destroy
      ]
    )
  end
end
