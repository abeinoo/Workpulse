# Records that the signed-in employee has seen today's birthday celebration, so
# it is shown at most once per business day. Posted by the celebration dialog
# when it opens; self-only and a no-op on any day that isn't their birthday.
class BirthdayCelebrationsController < ApplicationController
  before_action :authenticate_user!

  def create
    today = BusinessDay.current(context: current_user.business)
    Dashboard::Birthdays::Celebration.mark_shown!(current_user, today) if current_user.birthday_on?(today)

    head :no_content
  end
end
