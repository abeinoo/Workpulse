class Performance::ObservationsController < Performance::BaseController
  before_action :set_observation, only: [ :show, :edit, :update, :destroy ]

  def index
    authorize PerformanceObservation
    @observations = policy_scope(PerformanceObservation)
                      .includes(:employee, :observed_by, evaluation_criterion: :evaluation_template)
                      .recent_first

    @observations = @observations.for_employee(params[:employee_id]) if params[:employee_id].present?
    @observations = @observations.where(observation_type: params[:type]) if params[:type].present?
    @observations = @observations.page(params[:page]) if @observations.respond_to?(:page)
  end

  def show
    authorize @observation
  end

  def new
    @observation = current_user.business.performance_observations.new(
      observation_date: Date.current,
      employee_id:      params[:employee_id]
    )
    authorize @observation
    load_form_data
  end

  def create
    @observation = current_user.business.performance_observations.new(observation_params)
    @observation.observed_by = current_user
    authorize @observation

    if @observation.save
      redirect_to performance_observations_path, notice: t("performance.observations.created")
    else
      load_form_data
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @observation
    load_form_data
  end

  def update
    authorize @observation
    if @observation.update(observation_params)
      redirect_to performance_observations_path, notice: t("performance.observations.updated")
    else
      load_form_data
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @observation
    @observation.destroy
    redirect_to performance_observations_path, notice: t("performance.observations.destroyed")
  end

  # JSON used by the form's Stimulus controller to refresh the department display
  # and criteria dropdown the moment an employee is picked.
  def criteria_options
    authorize PerformanceObservation, :new?
    employee   = selectable_employees.find_by(id: params[:employee_id])
    department = employee&.department

    render json: {
      employee_selected: employee.present?,
      has_department:    department.present?,
      department:        department && { id: department.id, name: department.name },
      criteria:          criteria_for(employee).map { |c| { id: c.id, name: c.name } }
    }
  end

  private

  def set_observation
    @observation = policy_scope(PerformanceObservation).find(params[:id])
  end

  def load_form_data
    @employees  = selectable_employees
    @department = @observation.employee&.department
    @criteria   = criteria_for(@observation.employee).to_a

    # On edit, keep the already-attached criterion selectable even if it has since
    # been deactivated or belongs to a historical template, so saving an existing
    # observation never silently drops its criterion.
    current = @observation.evaluation_criterion
    @criteria << current if current && @criteria.exclude?(current)
  end

  # Active criteria from the active evaluation template of the employee's
  # department — nothing else. No cross-department fallback: an employee with no
  # department (or no active template) gets an empty list, and the form blocks
  # creation rather than offering criteria from unrelated departments.
  def criteria_for(employee)
    template = employee&.department&.evaluation_templates&.active&.ordered&.first
    template ? template.active_criteria : EvaluationCriterion.none
  end

  def observation_params
    params.require(:performance_observation).permit(
      :employee_id, :evaluation_criterion_id, :observation_date, :observation_type, :note
    )
  end
end
