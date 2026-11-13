# Holiday Calendar (R6; attendance plan revision 19, A10, D3): the business's
# public and company holidays. Thin: authorise, call Scheduling::HolidayCalendar
# (the audited write path), redirect or render.
class HolidaysController < ApplicationController
  before_action :authenticate_user!

  def index
    authorize Holiday
    @year     = (params[:year].presence || BusinessDay.current(context: current_user.business).year).to_i
    @holidays = policy_scope(Holiday).in_year(@year).ordered
  end

  def new
    @holiday = Holiday.new(kind: "public")
    authorize @holiday
  end

  def create
    authorize Holiday
    result = calendar.create(holiday_params)
    if result.ok?
      redirect_to holidays_path(year: result.record.date.year), notice: t("holidays.created")
    else
      @holiday = result.record
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @holiday = policy_scope(Holiday).find(params[:id])
    authorize @holiday
  end

  def update
    @holiday = policy_scope(Holiday).find(params[:id])
    authorize @holiday
    result = calendar.update(@holiday.id, holiday_params)
    if result.ok?
      redirect_to holidays_path(year: result.record.date.year), notice: t("holidays.updated")
    elsif result.error == :audit_failed
      redirect_to holidays_path, alert: t("holidays.audit_failed")
    else
      @holiday = result.record
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    holiday = policy_scope(Holiday).find(params[:id])
    authorize holiday
    result = calendar.destroy(holiday.id)
    if result.ok?
      redirect_to holidays_path(year: holiday.date.year), notice: t("holidays.deleted")
    else
      redirect_to holidays_path(year: holiday.date.year), alert: t("holidays.audit_failed")
    end
  end

  private

  def calendar = Scheduling::HolidayCalendar.new(actor: current_user)

  def holiday_params
    params.require(:holiday).permit(:date, :name, :kind)
  end
end
