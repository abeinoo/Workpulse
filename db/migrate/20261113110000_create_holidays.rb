# R6 (attendance plan revision 19, §8, A10, D3): the Holiday Calendar — one
# business-wide calendar of approved public and company holidays, Workforce-
# owned, read by Attendance & Payroll from R7 (a holiday is never an absence;
# whether public holidays leave the deduction denominator is an AP setting,
# L28 / D11). No branch_id column: branch-specific calendars are out of scope (D3).
class CreateHolidays < ActiveRecord::Migration[8.1]
  def change
    create_table :holidays do |t|
      t.references :business,   null: false, foreign_key: true, index: false
      t.date       :date,       null: false
      t.string     :name,       null: false
      t.string     :kind,       null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :holidays, %i[business_id date], unique: true
    add_check_constraint :holidays, "kind IN ('public', 'company')", name: "holidays_kind_known"
  end
end
