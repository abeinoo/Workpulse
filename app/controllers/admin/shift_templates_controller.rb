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

    employee_ids = Array(params[:employee_ids]).map(&:to_i).reject(&:zero?)
    @employees   = scoped_employees.where(id: employee_ids)

    if @template.entries.empty?
      flash.now[:alert] = t("shift_templates.apply.no_entries")
      load_apply_data
      render :apply, status: :unprocessable_entity and return
    end

    if @employees.empty?
      flash.now[:alert] = t("shift_templates.apply.no_employees_selected")
      load_apply_data
      render :apply, status: :unprocessable_entity and return
    end

    @preview_rows = Scheduling::TemplatePreviewer.call(
      template:  @template,
      employees: @employees
    )
  end

  def apply_confirm
    @template    = find_template
    authorize @template, :apply?

    employee_ids = Array(params[:employee_ids]).map(&:to_i).reject(&:zero?)
    employees    = scoped_employees.where(id: employee_ids)

    if employees.empty?
      redirect_to apply_admin_shift_template_path(@template),
                  alert: t("shift_templates.apply.no_employees_selected") and return
    end

    result = Scheduling::TemplateApplier.call(
      template:   @template,
      employees:  employees,
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
  end

  def scoped_employees
    User.where(business: current_user.business).active
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
