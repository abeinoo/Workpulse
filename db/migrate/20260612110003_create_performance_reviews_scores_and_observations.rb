class CreatePerformanceReviewsScoresAndObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :performance_reviews do |t|
      t.references :business,   null: false, foreign_key: true
      t.references :employee,   null: false, foreign_key: { to_table: :users }
      t.references :department, null: false, foreign_key: true
      t.references :reviewer,   null: false, foreign_key: { to_table: :users }
      t.integer :review_month,  null: false
      t.integer :review_year,   null: false
      # Flexible period label (e.g. "monthly", "mid-month", "probation").
      # Nullable so the common monthly case needs nothing; lets multiple reviews
      # coexist in the same month without a future schema change.
      t.string  :review_period
      t.string  :status, null: false, default: "draft"
      t.decimal :average_score, precision: 4, scale: 2
      t.text    :notes
      t.datetime :finalized_at
      t.timestamps
    end
    # NON-unique on purpose: multiple reviews per employee per month are allowed.
    add_index :performance_reviews, [ :employee_id, :review_year, :review_month ]
    # Report-tuned, business-scoped composite indexes.
    add_index :performance_reviews, [ :business_id, :review_year, :review_month ]
    add_index :performance_reviews, [ :business_id, :status ]
    add_index :performance_reviews, [ :department_id, :review_year, :review_month ]

    create_table :performance_review_scores do |t|
      t.references :performance_review,   null: false, foreign_key: true
      t.references :evaluation_criterion, null: false, foreign_key: { to_table: :evaluation_criteria }
      t.integer :score, null: false
      t.timestamps
    end
    add_index :performance_review_scores,
              [ :performance_review_id, :evaluation_criterion_id ],
              unique: true, name: "index_review_scores_on_review_and_criterion"

    create_table :performance_observations do |t|
      t.references :business,             null: false, foreign_key: true
      t.references :employee,             null: false, foreign_key: { to_table: :users }
      t.references :evaluation_criterion, null: false, foreign_key: { to_table: :evaluation_criteria }
      t.references :observed_by,          null: false, foreign_key: { to_table: :users }
      t.date    :observation_date, null: false
      t.string  :observation_type, null: false
      t.text    :note
      t.timestamps
    end
    add_index :performance_observations, [ :employee_id, :observation_date ]
    # Powers the "most common weak areas" report (negative counts per criterion).
    add_index :performance_observations,
              [ :business_id, :observation_type, :evaluation_criterion_id ],
              name: "index_observations_on_business_type_criterion"
  end
end
