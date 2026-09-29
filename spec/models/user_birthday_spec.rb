require "rails_helper"

RSpec.describe User, "birthdays" do
  let(:business) { create(:business) }
  let(:today)    { Date.new(2026, 9, 29) }

  def employee(dob)
    create(:user, business: business, date_of_birth: dob)
  end

  describe ".birthday_on / #birthday_on?" do
    it "matches an employee whose birthday is today" do
      user = employee(Date.new(1990, 9, 29))
      expect(User.birthday_on(today)).to contain_exactly(user)
      expect(user.birthday_on?(today)).to be true
    end

    it "does not match a birthday tomorrow" do
      user = employee(Date.new(1990, 9, 30))
      expect(User.birthday_on(today)).to be_empty
      expect(user.birthday_on?(today)).to be false
    end

    it "does not match a birthday yesterday" do
      user = employee(Date.new(1990, 9, 28))
      expect(User.birthday_on(today)).to be_empty
      expect(user.birthday_on?(today)).to be false
    end

    it "matches every employee with a birthday today, regardless of birth year" do
      a = employee(Date.new(1985, 9, 29))
      b = employee(Date.new(2001, 9, 29))
      employee(Date.new(2001, 8, 29)) # same day, other month
      employee(Date.new(2001, 9, 19)) # same month, other day
      expect(User.birthday_on(today)).to contain_exactly(a, b)
    end

    it "ignores employees without a birth date" do
      user = employee(nil)
      expect(User.birthday_on(today)).to be_empty
      expect(user.birthday_on?(today)).to be false
    end

    it "is eligible again on the next year's birthday" do
      user = employee(Date.new(1990, 9, 29))
      expect(User.birthday_on(today.next_year)).to contain_exactly(user)
      expect(user.birthday_on?(today.next_year)).to be true
    end

    context "with a 29 February birthday" do
      let!(:leapling) { employee(Date.new(2000, 2, 29)) }

      it "is celebrated on 28 February in a non-leap year" do
        expect(User.birthday_on(Date.new(2027, 2, 28))).to contain_exactly(leapling)
        expect(leapling.birthday_on?(Date.new(2027, 2, 28))).to be true
      end

      it "is celebrated only on 29 February in a leap year" do
        expect(User.birthday_on(Date.new(2028, 2, 28))).to be_empty
        expect(User.birthday_on(Date.new(2028, 2, 29))).to contain_exactly(leapling)
        expect(leapling.birthday_on?(Date.new(2028, 2, 28))).to be false
      end
    end
  end

  describe "date_of_birth validation" do
    it "is optional" do
      expect(build(:user, business: business, date_of_birth: nil)).to be_valid
    end

    it "rejects a date in the future" do
      user = build(:user, business: business, date_of_birth: BusinessDay.current(context: business) + 1)
      expect(user).not_to be_valid
      expect(user.errors[:date_of_birth]).to be_present
    end
  end
end
