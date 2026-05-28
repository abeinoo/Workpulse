class AddCalendarDatesToShiftTemplateEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :shift_template_entries, :starts_on, :date
    add_column :shift_template_entries, :ends_on,   :date

    # weekday is now optional — kept for future recurring scheduling support
    change_column_null :shift_template_entries, :weekday, true

    # effective_from_offset is now optional — kept for future recurring support
    change_column_default :shift_template_entries, :effective_from_offset, nil
    change_column_null    :shift_template_entries, :effective_from_offset, true
  end
end
