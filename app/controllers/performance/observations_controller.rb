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

  private

  def set_observation
    @observation = policy_scope(PerformanceObservation).find(params[:id])
  end

  def load_form_data
    @employees = selectable_employees
    @criteria  = criteria_for(@observation.employee)
  end

  # Active criteria from the employee's department template; falls back to all
  # active criteria in the business when the employee has no department yet.
  def criteria_for(employee)
    template = employee&.department&.evaluation_templates&.active&.ordered&.first
    if template
      template.active_criteria
    else
      EvaluationCriterion.active.ordered
        .joins(:evaluation_template)
        .where(evaluation_templates: { business_id: current_user.business_id })
    end
  end

  def observation_params
    params.require(:performance_observation).permit(
      :employee_id, :evaluation_criterion_id, :observation_date, :observation_type, :note
    )
  end
end
