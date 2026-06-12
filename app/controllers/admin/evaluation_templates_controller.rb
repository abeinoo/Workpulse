class Admin::EvaluationTemplatesController < Admin::BaseController
  before_action :set_template, only: [ :show, :edit, :update, :destroy ]

  def index
    authorize EvaluationTemplate
    @templates = policy_scope(EvaluationTemplate)
                   .includes(:department)
                   .ordered
  end

  def show
    authorize @template
    @criteria = @template.evaluation_criteria.ordered
  end

  def new
    @template = current_user.business.evaluation_templates.new(active: true)
    @template.evaluation_criteria.build(sort_order: 0, active: true)
    authorize @template
    @departments = selectable_departments
  end

  def create
    @template = current_user.business.evaluation_templates.new(template_params)
    authorize @template
    if @template.save
      redirect_to admin_evaluation_template_path(@template), notice: t("admin.evaluation_templates.created")
    else
      @departments = selectable_departments
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @template
    @departments = selectable_departments
  end

  def update
    authorize @template
    if @template.update(template_params)
      redirect_to admin_evaluation_template_path(@template), notice: t("admin.evaluation_templates.updated")
    else
      @departments = selectable_departments
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @template
    if @template.destroy
      redirect_to admin_evaluation_templates_path, notice: t("admin.evaluation_templates.destroyed")
    else
      redirect_to admin_evaluation_templates_path, alert: @template.errors.full_messages.to_sentence
    end
  end

  private

  def set_template
    @template = policy_scope(EvaluationTemplate).find(params[:id])
  end

  # Active departments, plus the template's current one even if it was later
  # deactivated (so editing never silently drops the assignment).
  def selectable_departments
    active = current_user.business.departments.active.ordered.to_a
    current = @template&.department
    current && active.exclude?(current) ? active + [ current ] : active
  end

  def template_params
    params.require(:evaluation_template).permit(
      :name, :department_id, :active,
      evaluation_criteria_attributes: [ :id, :name, :description, :sort_order, :active, :_destroy ]
    )
  end
end
