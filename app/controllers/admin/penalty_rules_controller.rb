class Admin::PenaltyRulesController < Admin::BaseController
  before_action :set_shift

  def new
    @rule = @shift.penalty_rules.build
  end

  def create
    @rule = @shift.penalty_rules.build(rule_params)
    if @rule.save
      redirect_to admin_shift_path(@shift), notice: t("flash.penalty_rule_added")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @rule = find_rule
  end

  def update
    @rule = find_rule
    if @rule.update(rule_params)
      redirect_to admin_shift_path(@shift), notice: t("flash.penalty_rule_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    find_rule.destroy
    redirect_to admin_shift_path(@shift), notice: t("flash.penalty_rule_removed")
  end

  private

  def set_shift
    @shift = Shift.find_by!(business_id: current_user.business_id, id: params[:shift_id])
  end

  def find_rule
    @shift.penalty_rules.find(params[:id])
  end

  def rule_params
    params.require(:penalty_rule).permit(:rule_type, :threshold_minutes, :deduction_type, :deduction_value)
  end
end
