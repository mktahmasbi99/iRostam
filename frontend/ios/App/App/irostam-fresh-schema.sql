-- Generated from backend/app/database.py at schema version 17; refresh when the ledger schema changes.
-- Keep profile_settings idempotent for earlier iRostam installs with the starter-only schema.
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE activities (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        name TEXT NOT NULL,
                        normalized_name TEXT NOT NULL UNIQUE,
                        archived_at TEXT,
                        created_at TEXT NOT NULL
                    );
CREATE TABLE activity_entries (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        activity_id INTEGER NOT NULL REFERENCES activities(id) ON DELETE RESTRICT,
                        started_at TEXT NOT NULL,
                        ended_at TEXT,
                        note TEXT NOT NULL DEFAULT '',
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL
                    );
CREATE TABLE backup_metadata (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    app_id TEXT NOT NULL,
                    format_version INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    category TEXT NOT NULL
                );
INSERT INTO "backup_metadata" VALUES(1,'rostam',1,'__IROSTAM_BOOTSTRAP_NOW__','live');
CREATE TABLE backup_runs (
                    category TEXT PRIMARY KEY,
                    last_scheduled_date TEXT NOT NULL
                );
CREATE TABLE backup_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    daily_enabled INTEGER NOT NULL DEFAULT 1 CHECK (daily_enabled IN (0, 1)),
                    daily_time TEXT NOT NULL DEFAULT '01:00',
                    daily_retention INTEGER NOT NULL DEFAULT 7 CHECK (daily_retention BETWEEN 1 AND 365),
                    weekly_enabled INTEGER NOT NULL DEFAULT 1 CHECK (weekly_enabled IN (0, 1)),
                    weekly_weekday INTEGER NOT NULL DEFAULT 6 CHECK (weekly_weekday BETWEEN 0 AND 6),
                    weekly_time TEXT NOT NULL DEFAULT '01:00',
                    weekly_retention INTEGER NOT NULL DEFAULT 8 CHECK (weekly_retention BETWEEN 1 AND 365),
                    safety_retention INTEGER NOT NULL DEFAULT 8 CHECK (safety_retention BETWEEN 1 AND 365)
                );
INSERT INTO "backup_settings" VALUES(1,1,'01:00',7,1,6,'01:00',8,8);
CREATE TABLE "body_measurements" (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        entry_date TEXT NOT NULL,
                        measurement_type TEXT NOT NULL CHECK (measurement_type IN ('weight', 'waist')),
                        weight_grams INTEGER CHECK (weight_grams > 0),
                        waist_mm INTEGER CHECK (waist_mm > 0),
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL,
                        UNIQUE(entry_date, measurement_type),
                        CHECK (
                            (measurement_type = 'weight' AND weight_grams IS NOT NULL AND waist_mm IS NULL)
                            OR (measurement_type = 'waist' AND waist_mm IS NOT NULL AND weight_grams IS NULL)
                        )
                    );
CREATE TABLE daily_notes (
                        entry_date TEXT PRIMARY KEY,
                        body TEXT NOT NULL,
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL
                    );
CREATE TABLE daily_photos (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        entry_date TEXT NOT NULL,
                        display_order INTEGER NOT NULL,
                        jpeg BLOB NOT NULL,
                        thumbnail_jpeg BLOB NOT NULL,
                        width INTEGER NOT NULL,
                        height INTEGER NOT NULL,
                        created_at TEXT NOT NULL,
                        UNIQUE(entry_date, display_order)
                    );
CREATE TABLE day_exercises (
                    entry_date TEXT NOT NULL,
                    exercise_id INTEGER NOT NULL,
                    display_order INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (entry_date, exercise_id),
                    UNIQUE (entry_date, display_order),
                    FOREIGN KEY (exercise_id) REFERENCES exercises(id) ON DELETE RESTRICT
                );
CREATE TABLE exercise_images (
                        image_key TEXT PRIMARY KEY,
                        jpeg BLOB NOT NULL,
                        created_at TEXT NOT NULL
                    );
CREATE TABLE exercise_muscles (
                        exercise_id INTEGER NOT NULL REFERENCES exercises(id) ON DELETE CASCADE,
                        muscle_slug TEXT NOT NULL REFERENCES muscle_groups(slug) ON DELETE RESTRICT,
                        role TEXT NOT NULL CHECK (role IN ('primary', 'secondary')),
                        PRIMARY KEY (exercise_id, muscle_slug)
                    );
INSERT INTO "exercise_muscles" VALUES(5,'back','primary');
INSERT INTO "exercise_muscles" VALUES(5,'shoulders','secondary');
INSERT INTO "exercise_muscles" VALUES(4,'biceps','primary');
INSERT INTO "exercise_muscles" VALUES(4,'forearms','secondary');
INSERT INTO "exercise_muscles" VALUES(6,'hamstrings','primary');
INSERT INTO "exercise_muscles" VALUES(6,'glutes','secondary');
INSERT INTO "exercise_muscles" VALUES(6,'back','secondary');
INSERT INTO "exercise_muscles" VALUES(6,'forearms','secondary');
INSERT INTO "exercise_muscles" VALUES(8,'abs','primary');
INSERT INTO "exercise_muscles" VALUES(8,'hip_flexors','secondary');
INSERT INTO "exercise_muscles" VALUES(7,'abs','primary');
INSERT INTO "exercise_muscles" VALUES(7,'shoulders','secondary');
INSERT INTO "exercise_muscles" VALUES(7,'glutes','secondary');
INSERT INTO "exercise_muscles" VALUES(3,'back','primary');
INSERT INTO "exercise_muscles" VALUES(3,'biceps','secondary');
INSERT INTO "exercise_muscles" VALUES(3,'forearms','secondary');
INSERT INTO "exercise_muscles" VALUES(2,'chest','primary');
INSERT INTO "exercise_muscles" VALUES(2,'triceps','secondary');
INSERT INTO "exercise_muscles" VALUES(2,'shoulders','secondary');
INSERT INTO "exercise_muscles" VALUES(2,'abs','secondary');
INSERT INTO "exercise_muscles" VALUES(1,'quadriceps','primary');
INSERT INTO "exercise_muscles" VALUES(1,'glutes','secondary');
INSERT INTO "exercise_muscles" VALUES(1,'hamstrings','secondary');
INSERT INTO "exercise_muscles" VALUES(1,'abs','secondary');
CREATE TABLE "exercise_sets" (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        exercise_id INTEGER NOT NULL,
                        entry_date TEXT NOT NULL,
                        occurred_at TEXT NOT NULL,
                        repetitions INTEGER CHECK (repetitions > 0),
                        duration_seconds INTEGER CHECK (duration_seconds > 0),
                        hold_seconds INTEGER CHECK (hold_seconds > 0),
                        resistance_kind TEXT NOT NULL
                            CHECK (resistance_kind IN ('bodyweight', 'external')),
                        weight_grams INTEGER CHECK (weight_grams > 0),
                        equipment TEXT,
                        custom_equipment TEXT,
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL, workout_exercise_id INTEGER
                        REFERENCES workout_exercises(id) ON DELETE CASCADE,
                        CHECK (
                            (repetitions IS NOT NULL AND duration_seconds IS NULL)
                            OR (
                                repetitions IS NULL AND duration_seconds IS NOT NULL
                                AND hold_seconds IS NULL
                            )
                        ),
                        FOREIGN KEY (exercise_id) REFERENCES exercises(id) ON DELETE RESTRICT
                    );
CREATE TABLE "exercises" (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        seed_key TEXT UNIQUE,
                        name TEXT NOT NULL,
                        normalized_name TEXT NOT NULL UNIQUE,
                        measurement_type TEXT NOT NULL CHECK (
                            measurement_type IN ('repetitions', 'duration', 'timed_repetitions')
                        ),
                        default_resistance_kind TEXT NOT NULL
                            CHECK (default_resistance_kind IN ('bodyweight', 'external')),
                        default_equipment TEXT,
                        default_custom_equipment TEXT,
                        default_weight_grams INTEGER CHECK (default_weight_grams > 0),
                        image_key TEXT,
                        archived_at TEXT,
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL,
                        base_name TEXT,
                        equipment TEXT,
                        custom_equipment TEXT,
                        allow_bodyweight INTEGER NOT NULL DEFAULT 0
                            CHECK (allow_bodyweight IN (0, 1)),
                        exercise_note TEXT
                    , recommendation_paused_until TEXT, recommendation_paused_forever INTEGER NOT NULL DEFAULT 0 CHECK (recommendation_paused_forever IN (0, 1)));
INSERT INTO "exercises" VALUES(1,'squats','Squats','squats','repetitions','bodyweight',NULL,NULL,NULL,'bodyweight-squat',NULL,'__IROSTAM_BOOTSTRAP_NOW__','__IROSTAM_BOOTSTRAP_NOW__','Squats',NULL,NULL,1,NULL,NULL,0);
INSERT INTO "exercises" VALUES(2,'push-ups','Push-ups','push-ups','repetitions','bodyweight',NULL,NULL,NULL,'push-up',NULL,'__IROSTAM_BOOTSTRAP_NOW__','__IROSTAM_BOOTSTRAP_NOW__','Push-ups',NULL,NULL,1,NULL,NULL,0);
INSERT INTO "exercises" VALUES(3,'pull-ups','Pull-ups','pull-ups','repetitions','bodyweight',NULL,NULL,NULL,'pull-up',NULL,'__IROSTAM_BOOTSTRAP_NOW__','__IROSTAM_BOOTSTRAP_NOW__','Pull-ups',NULL,NULL,1,NULL,NULL,0);
INSERT INTO "exercises" VALUES(4,'bicep-curls','Bicep curls','bicep curls','repetitions','external','dumbbell',NULL,NULL,'bicep-curl',NULL,'__IROSTAM_BOOTSTRAP_NOW__','__IROSTAM_BOOTSTRAP_NOW__','Bicep curls','dumbbell',NULL,0,NULL,NULL,0);
INSERT INTO "exercises" VALUES(5,'band-pull-aparts','Band pull-aparts','band pull-aparts','repetitions','external','resistance_band',NULL,NULL,'band-pull-apart',NULL,'__IROSTAM_BOOTSTRAP_NOW__','__IROSTAM_BOOTSTRAP_NOW__','Band pull-aparts','resistance_band',NULL,0,NULL,NULL,0);
INSERT INTO "exercises" VALUES(6,'deadlifts','Deadlifts','deadlifts','repetitions','external','barbell',NULL,NULL,'deadlift',NULL,'__IROSTAM_BOOTSTRAP_NOW__','__IROSTAM_BOOTSTRAP_NOW__','Deadlifts','barbell',NULL,0,NULL,NULL,0);
INSERT INTO "exercises" VALUES(7,'plank','Plank','plank','duration','bodyweight',NULL,NULL,NULL,'plank',NULL,'__IROSTAM_BOOTSTRAP_NOW__','__IROSTAM_BOOTSTRAP_NOW__','Plank',NULL,NULL,1,NULL,NULL,0);
INSERT INTO "exercises" VALUES(8,'hollow-body-hold','Hollow-body hold','hollow-body hold','duration','bodyweight',NULL,NULL,NULL,'hollow-body-hold',NULL,'__IROSTAM_BOOTSTRAP_NOW__','__IROSTAM_BOOTSTRAP_NOW__','Hollow-body hold',NULL,NULL,1,NULL,NULL,0);
CREATE TABLE muscle_groups (
                        slug TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        display_order INTEGER NOT NULL UNIQUE
                    );
INSERT INTO "muscle_groups" VALUES('abs','Abs',0);
INSERT INTO "muscle_groups" VALUES('back','Back',1);
INSERT INTO "muscle_groups" VALUES('biceps','Biceps',2);
INSERT INTO "muscle_groups" VALUES('calves','Calves',3);
INSERT INTO "muscle_groups" VALUES('chest','Chest',4);
INSERT INTO "muscle_groups" VALUES('forearms','Forearms',5);
INSERT INTO "muscle_groups" VALUES('glutes','Glutes',6);
INSERT INTO "muscle_groups" VALUES('hamstrings','Hamstrings',7);
INSERT INTO "muscle_groups" VALUES('hip_flexors','Hip Flexors',8);
INSERT INTO "muscle_groups" VALUES('quadriceps','Quadriceps',9);
INSERT INTO "muscle_groups" VALUES('shoulders','Shoulders',10);
INSERT INTO "muscle_groups" VALUES('triceps','Triceps',11);
CREATE TABLE IF NOT EXISTS profile_settings (
                        id INTEGER PRIMARY KEY CHECK (id = 1),
                        height_mm INTEGER CHECK (height_mm > 0),
                        date_of_birth TEXT
                    );
CREATE TABLE "rotation_members" (
                        member_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        rotation_id INTEGER NOT NULL REFERENCES rotations(id) ON DELETE CASCADE,
                        exercise_id INTEGER NOT NULL REFERENCES exercises(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        enrolled_date TEXT,
                        enroll_sequence INTEGER,
                        auto_order INTEGER NOT NULL DEFAULT 0,
                        UNIQUE (rotation_id, position)
                    );
CREATE TABLE rotations (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        name TEXT NOT NULL,
                        active INTEGER NOT NULL DEFAULT 0 CHECK (active IN (0, 1)),
                        due_exercise_id INTEGER,
                        resolved_date TEXT,
                        resolved_kind TEXT CHECK (resolved_kind IN ('completed', 'skipped'))
                    , due_position INTEGER, archived_at TEXT);
CREATE TABLE schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
INSERT INTO "schema_migrations" VALUES(1,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(2,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(3,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(4,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(5,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(6,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(7,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(8,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(9,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(10,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(11,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(12,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(13,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(14,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(15,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(16,'__IROSTAM_BOOTSTRAP_NOW__');
INSERT INTO "schema_migrations" VALUES(17,'__IROSTAM_BOOTSTRAP_NOW__');
CREATE TABLE system_notifications (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    message TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
CREATE TABLE workout_exercises (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        workout_id INTEGER NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
                        exercise_id INTEGER NOT NULL REFERENCES exercises(id),
                        position INTEGER NOT NULL,
                        UNIQUE (workout_id, exercise_id)
                    );
CREATE TABLE workouts (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        name TEXT NOT NULL,
                        started_at TEXT NOT NULL,
                        ended_at TEXT,
                        CHECK (ended_at IS NULL OR ended_at >= started_at)
                    );
CREATE INDEX idx_daily_notes_date ON daily_notes(entry_date DESC);
CREATE INDEX idx_daily_photos_date_order
                        ON daily_photos(entry_date DESC, display_order ASC);
CREATE INDEX idx_body_measurements_date
                        ON body_measurements(entry_date DESC);
CREATE INDEX idx_sets_day_exercise_order
                        ON exercise_sets(entry_date, exercise_id, occurred_at, created_at, id);
CREATE INDEX idx_sets_exercise_order
                        ON exercise_sets(exercise_id, occurred_at, created_at, id);
CREATE INDEX idx_sets_day ON exercise_sets(entry_date);
CREATE UNIQUE INDEX idx_exercise_one_primary
                        ON exercise_muscles(exercise_id) WHERE role = 'primary';
CREATE INDEX idx_exercise_muscles_lookup
                        ON exercise_muscles(muscle_slug, role, exercise_id);
CREATE INDEX idx_activity_entries_start ON activity_entries(started_at, id);
CREATE INDEX idx_activity_entries_activity ON activity_entries(activity_id, started_at);
CREATE UNIQUE INDEX one_active_rotation ON rotations(active) WHERE active = 1;
CREATE INDEX idx_rotation_members_exercise
                        ON rotation_members(exercise_id, rotation_id);
CREATE UNIQUE INDEX idx_one_active_workout ON workouts((1))
                        WHERE ended_at IS NULL;
CREATE INDEX idx_sets_workout ON exercise_sets(workout_exercise_id, occurred_at);
CREATE INDEX idx_workouts_started ON workouts(started_at);
DELETE FROM "sqlite_sequence";
INSERT INTO "sqlite_sequence" VALUES('body_measurements',0);
INSERT INTO "sqlite_sequence" VALUES('exercises',8);
INSERT INTO "sqlite_sequence" VALUES('exercise_sets',0);
INSERT INTO "sqlite_sequence" VALUES('rotation_members',0);
COMMIT;
PRAGMA foreign_keys=ON;
