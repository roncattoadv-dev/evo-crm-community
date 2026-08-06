conn = ActiveRecord::Base.connection
current_type = conn.select_value(
  "SELECT data_type FROM information_schema.columns WHERE table_name='messages' AND column_name='status'"
)

if current_type == "text"
  conn.execute("ALTER TABLE messages ALTER COLUMN status TYPE integer USING status::integer")
  conn.execute("ALTER TABLE messages ALTER COLUMN status SET DEFAULT 0")
  puts "[boot-check] messages.status was TEXT, converted to INTEGER"
else
  puts "[boot-check] messages.status is already #{current_type}, no action needed"
end
