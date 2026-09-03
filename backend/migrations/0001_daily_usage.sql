CREATE TABLE daily_usage (
  user_id TEXT NOT NULL,
  usage_day TEXT NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0 CHECK (request_count >= 0),
  PRIMARY KEY (user_id, usage_day)
);
