-- Lingua Database
-- Schema + seed data for local/dev/demo usage.
--
-- Notes:
-- - This file is intended to be run by a Postgres container init mechanism
--   (e.g., docker-entrypoint-initdb.d) or manually via psql.
-- - It is written to be idempotent where practical (CREATE IF NOT EXISTS / ON CONFLICT DO NOTHING).
-- - For production, prefer a formal migration tool (Alembic/Flyway), but this is enough
--   to unblock backend development in this repository.

BEGIN;

-- -----------------------------
-- Extensions
-- -----------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------
-- Enums
-- -----------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'exercise_type') THEN
    CREATE TYPE exercise_type AS ENUM ('mcq', 'fill_blank', 'listening', 'speaking');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'attempt_status') THEN
    CREATE TYPE attempt_status AS ENUM ('started', 'submitted', 'graded');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'purchase_status') THEN
    CREATE TYPE purchase_status AS ENUM ('pending', 'paid', 'failed', 'refunded');
  END IF;
END $$;

-- -----------------------------
-- Core tables
-- -----------------------------

-- Users
CREATE TABLE IF NOT EXISTS app_user (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL UNIQUE,
  display_name text NOT NULL,
  password_hash text NULL, -- MVP: backend may manage hashing; can be NULL for OAuth/supabase later.
  is_admin boolean NOT NULL DEFAULT false,
  is_premium boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_app_user_created_at ON app_user (created_at);

-- Lessons
CREATE TABLE IF NOT EXISTS lesson (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  level text NOT NULL DEFAULT 'beginner', -- simple text for MVP
  language text NOT NULL DEFAULT 'en',     -- target language code
  order_index integer NOT NULL DEFAULT 0,
  is_published boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_lesson_language_level ON lesson (language, level);
CREATE INDEX IF NOT EXISTS idx_lesson_order ON lesson (order_index);

-- Exercises
CREATE TABLE IF NOT EXISTS exercise (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lesson_id uuid NOT NULL REFERENCES lesson(id) ON DELETE CASCADE,
  slug text NOT NULL,
  title text NOT NULL,
  prompt text NOT NULL DEFAULT '',
  exercise_type exercise_type NOT NULL,
  -- Storing content as jsonb keeps MVP flexible (choices, correct answer, audio url, rubric, etc.)
  content jsonb NOT NULL DEFAULT '{}'::jsonb,
  order_index integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lesson_id, slug)
);

CREATE INDEX IF NOT EXISTS idx_exercise_lesson_order ON exercise (lesson_id, order_index);
CREATE INDEX IF NOT EXISTS idx_exercise_type ON exercise (exercise_type);

-- Attempts / submissions
CREATE TABLE IF NOT EXISTS exercise_attempt (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  exercise_id uuid NOT NULL REFERENCES exercise(id) ON DELETE CASCADE,
  status attempt_status NOT NULL DEFAULT 'started',
  answer jsonb NOT NULL DEFAULT '{}'::jsonb, -- user's response (text, selected choices, etc.)
  score numeric(5,2) NULL,                   -- 0.00 - 100.00
  feedback text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  submitted_at timestamptz NULL,
  graded_at timestamptz NULL
);

CREATE INDEX IF NOT EXISTS idx_attempt_user_created ON exercise_attempt (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_attempt_exercise_created ON exercise_attempt (exercise_id, created_at DESC);

-- Progress tracking (per user per lesson)
CREATE TABLE IF NOT EXISTS user_lesson_progress (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  lesson_id uuid NOT NULL REFERENCES lesson(id) ON DELETE CASCADE,
  progress_pct numeric(5,2) NOT NULL DEFAULT 0.00, -- 0..100
  completed_at timestamptz NULL,
  last_activity_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, lesson_id)
);

CREATE INDEX IF NOT EXISTS idx_progress_last_activity ON user_lesson_progress (last_activity_at DESC);

-- Analytics event stream (lightweight)
CREATE TABLE IF NOT EXISTS analytics_event (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NULL REFERENCES app_user(id) ON DELETE SET NULL,
  event_name text NOT NULL,
  properties jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_analytics_event_name_time ON analytics_event (event_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_analytics_event_user_time ON analytics_event (user_id, created_at DESC);

-- Daily aggregates (optional; can be backfilled by backend jobs later)
CREATE TABLE IF NOT EXISTS analytics_daily_aggregate (
  day date NOT NULL,
  metric_name text NOT NULL,
  metric_value numeric(14,2) NOT NULL DEFAULT 0,
  dimensions jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (day, metric_name, dimensions)
);

-- Notification settings
CREATE TABLE IF NOT EXISTS notification_settings (
  user_id uuid PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  email_notifications boolean NOT NULL DEFAULT true,
  push_notifications boolean NOT NULL DEFAULT true,
  weekly_digest boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- In-app notifications
CREATE TABLE IF NOT EXISTS notification (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  title text NOT NULL,
  body text NOT NULL DEFAULT '',
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notification_user_time ON notification (user_id, created_at DESC);

-- Purchases / premium entitlements
CREATE TABLE IF NOT EXISTS purchase (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  provider text NOT NULL DEFAULT 'internal',  -- 'stripe' later
  provider_ref text NULL,                    -- external id
  status purchase_status NOT NULL DEFAULT 'pending',
  amount_cents integer NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_purchase_user_time ON purchase (user_id, created_at DESC);

-- -----------------------------
-- Seed data (safe re-runs)
-- -----------------------------

-- Demo users
INSERT INTO app_user (email, display_name, password_hash, is_admin, is_premium)
VALUES
  ('admin@lingua.local', 'Admin', NULL, true, true),
  ('demo@lingua.local', 'Demo Learner', NULL, false, false)
ON CONFLICT (email) DO NOTHING;

-- Lessons
INSERT INTO lesson (slug, title, description, level, language, order_index, is_published)
VALUES
  ('basics-1', 'Basics 1', 'Greetings, introductions, and simple phrases.', 'beginner', 'en', 1, true),
  ('basics-2', 'Basics 2', 'Everyday questions and short dialogues.', 'beginner', 'en', 2, true),
  ('travel-1', 'Travel 1', 'Common travel scenarios and vocabulary.', 'intermediate', 'en', 3, true)
ON CONFLICT (slug) DO NOTHING;

-- Exercises: we lookup lessons by slug to remain stable across runs.
WITH l AS (
  SELECT id, slug FROM lesson WHERE slug IN ('basics-1','basics-2','travel-1')
)
INSERT INTO exercise (lesson_id, slug, title, prompt, exercise_type, content, order_index)
SELECT
  l.id,
  e.slug,
  e.title,
  e.prompt,
  e.exercise_type::exercise_type,
  e.content::jsonb,
  e.order_index
FROM l
JOIN (
  VALUES
    ('basics-1', 'greetings-mcq', 'Greetings (MCQ)', 'Choose the best greeting:', 'mcq',
      '{"choices":["Hello","Goodbye","Thanks"],"correctIndex":0}'::jsonb, 1),
    ('basics-1', 'introduce-fill', 'Introduce Yourself', 'Fill in the blank: My name __ Alex.', 'fill_blank',
      '{"correctText":"is"}'::jsonb, 2),
    ('basics-2', 'short-dialogue', 'Short Dialogue', 'Complete the dialogue with a suitable phrase.', 'fill_blank',
      '{"correctText":"How are you?"}'::jsonb, 1),
    ('travel-1', 'airport-listening', 'At the Airport (Listening)', 'Listen and answer the question.', 'listening',
      '{"audioUrl":null,"question":"Where is the gate?","expectedKeywords":["gate","terminal"]}'::jsonb, 1),
    ('travel-1', 'speaking-check', 'Pronunciation Check', 'Say: \"Where is the train station?\"', 'speaking',
      '{"targetText":"Where is the train station?","rubric":{"clarity":0.4,"accuracy":0.6}}'::jsonb, 2)
) AS e(lesson_slug, slug, title, prompt, exercise_type, content, order_index)
  ON e.lesson_slug = l.slug
ON CONFLICT (lesson_id, slug) DO NOTHING;

-- Seed notification settings for demo users
INSERT INTO notification_settings (user_id, email_notifications, push_notifications, weekly_digest)
SELECT u.id, true, true, true
FROM app_user u
WHERE u.email IN ('admin@lingua.local', 'demo@lingua.local')
ON CONFLICT (user_id) DO NOTHING;

-- Seed a couple of notifications
INSERT INTO notification (user_id, title, body, is_read)
SELECT u.id, 'Welcome to Lingua', 'Start with Basics 1 to build momentum.', false
FROM app_user u
WHERE u.email = 'demo@lingua.local'
ON CONFLICT DO NOTHING;

INSERT INTO notification (user_id, title, body, is_read)
SELECT u.id, 'Admin Notice', 'Remember to review analytics weekly.', false
FROM app_user u
WHERE u.email = 'admin@lingua.local'
ON CONFLICT DO NOTHING;

COMMIT;
