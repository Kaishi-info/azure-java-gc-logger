-- SYNTHETIC LMS-style schema and data. Generated values only; no real people,
-- courses or organisations. Loaded automatically by the postgres container.

CREATE TABLE users (
  id         integer PRIMARY KEY,
  login      text NOT NULL UNIQUE,
  role       text NOT NULL CHECK (role IN ('student', 'teacher'))
);

CREATE TABLE courses (
  id    integer PRIMARY KEY,
  code  text NOT NULL UNIQUE,
  title text NOT NULL
);

CREATE TABLE enrollments (
  user_id   integer NOT NULL REFERENCES users(id),
  course_id integer NOT NULL REFERENCES courses(id),
  role      text NOT NULL,
  PRIMARY KEY (user_id, course_id)
);

CREATE TABLE assignments (
  id        integer PRIMARY KEY,
  course_id integer NOT NULL REFERENCES courses(id),
  title     text NOT NULL,
  due_at    timestamptz NOT NULL
);
CREATE INDEX assignments_course_due ON assignments(course_id, due_at);

CREATE TABLE grades (
  assignment_id integer NOT NULL REFERENCES assignments(id),
  user_id       integer NOT NULL REFERENCES users(id),
  score         integer NOT NULL CHECK (score BETWEEN 0 AND 100),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (assignment_id, user_id)
);
CREATE INDEX grades_user ON grades(user_id);

CREATE TABLE calendar_events (
  id          bigserial PRIMARY KEY,
  course_id   integer NOT NULL REFERENCES courses(id),
  title       text NOT NULL,
  description text NOT NULL,
  starts_at   timestamptz NOT NULL
);
CREATE INDEX calendar_course_start ON calendar_events(course_id, starts_at);

CREATE TABLE todos (
  id      bigserial PRIMARY KEY,
  user_id integer NOT NULL REFERENCES users(id),
  title   text NOT NULL,
  due_at  timestamptz NOT NULL,
  done    boolean NOT NULL DEFAULT false
);
CREATE INDEX todos_user ON todos(user_id) WHERE NOT done;

-- 2,000 students (ids 1..2000) and 50 teachers (2001..2050)
INSERT INTO users
SELECT g, 'student' || lpad(g::text, 4, '0'), 'student' FROM generate_series(1, 2000) g
UNION ALL
SELECT g, 'teacher' || lpad((g - 2000)::text, 2, '0'), 'teacher' FROM generate_series(2001, 2050) g;

-- 40 courses
INSERT INTO courses
SELECT g, 'CRS-' || lpad(g::text, 3, '0'), 'Synthetic course ' || g FROM generate_series(1, 40) g;

-- every student takes 5 courses; every teacher teaches courses
INSERT INTO enrollments
SELECT u, ((u * 7 + k * 13) % 40) + 1, 'student'
FROM generate_series(1, 2000) u, generate_series(0, 4) k
ON CONFLICT DO NOTHING;
INSERT INTO enrollments
SELECT 2001 + (c - 1) % 50, c, 'teacher' FROM generate_series(1, 40) c
ON CONFLICT DO NOTHING;

-- 20 assignments per course, due dates spread over -30..+30 days (ids 1..800)
INSERT INTO assignments
SELECT (c - 1) * 20 + a, c, 'Assignment ' || a, now() + ((a * 3 - 30) || ' days')::interval + (c || ' hours')::interval
FROM generate_series(1, 40) c, generate_series(1, 20) a;

-- 3 calendar events per course per day over -30..+30 days, with realistic text length
INSERT INTO calendar_events(course_id, title, description, starts_at)
SELECT c, 'Session ' || d || '-' || s,
       repeat('Synthetic calendar entry for load testing. ', 6),
       date_trunc('day', now()) + (d || ' days')::interval + ((9 + s * 3) || ' hours')::interval
FROM generate_series(1, 40) c, generate_series(-30, 30) d, generate_series(0, 2) s;

-- 8 personal to-dos per student
INSERT INTO todos(user_id, title, due_at, done)
SELECT u, 'Personal task ' || k, now() + ((k * 2) || ' days')::interval, k % 4 = 0
FROM generate_series(1, 2000) u, generate_series(1, 8) k;

-- grades for assignments already due
INSERT INTO grades(assignment_id, user_id, score)
SELECT a.id, e.user_id, (e.user_id * 31 + a.id * 17) % 101
FROM assignments a JOIN enrollments e ON e.course_id = a.course_id AND e.role = 'student'
WHERE a.due_at < now();

ANALYZE;
