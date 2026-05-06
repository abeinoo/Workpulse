class Admin::EmployeesController < Admin::BaseController
  before_action :set_employee, only: [:show, :edit, :update, :destroy]

  def index
    @employees = Employee.includes(:user).order(:full_name)
  end

  def show; end

  def new
    @employee = Employee.new
  end

  def create
    @employee = Employee.new(employee_params)

    if @employee.save
      redirect_to admin_employees_path, notice: "Employee created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @employee.update(employee_params)
      redirect_to admin_employees_path, notice: "Employee updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @employee.destroy
    redirect_to admin_employees_path, notice: "Employee removed."
  end

  private

  def set_employee
    @employee = Employee.find(params[:id])
  end

  def employee_params
    params.require(:employee).permit(
      :phone_number, :email, :employee_number,
      :full_name, :department, :job_title,
      :hire_date, :status, :manager_id
    )
  end
end
