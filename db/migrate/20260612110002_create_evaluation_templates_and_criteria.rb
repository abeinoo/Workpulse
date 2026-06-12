class CreateEvaluationTemplatesAndCriteria < ActiveRecord::Migration[8.1]
  def change
    create_table :evaluation_templates do |t|
      t.references :business,   null: false, foreign_key: true
      t.references :department, null: false, foreign_key: true
      t.string  :name,   null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :evaluation_templates, [ :department_id, :active ]

    create_table :evaluation_criteria do |t|
      t.references :evaluation_template, null: false, foreign_key: true
      t.string  :name,        null: false
      t.text    :description
      t.integer :sort_order,  null: false, default: 0
      t.boolean :active,      null: false, default: true
      t.timestamps
    end
    add_index :evaluation_criteria, [ :evaluation_template_id, :sort_order ]
  end
end
