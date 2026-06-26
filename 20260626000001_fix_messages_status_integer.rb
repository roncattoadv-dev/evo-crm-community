class FixMessagesStatusInteger < ActiveRecord::Migration[7.1]
  def up
    # Ensure messages.status is INTEGER, not TEXT.
    # The evoapicloud image sometimes recreates this column as TEXT, which
    # breaks Rails integer enum reverse-mapping (status returns nil).
    result = execute("SELECT data_type FROM information_schema.columns WHERE table_name='messages' AND column_name='status'")
    current_type = result.first&.fetch('data_type', nil)

    if current_type == 'text'
      execute("ALTER TABLE messages ALTER COLUMN status TYPE integer USING status::integer")
      execute("ALTER TABLE messages ALTER COLUMN status SET DEFAULT 0")
    end
  end

  def down
    # Intentionally a no-op — reverting to TEXT would break the app.
  end
end
