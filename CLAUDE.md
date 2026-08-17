# SYNAPSE AUTO — Development Guidelines

## 1. Project Overview

Synapse Auto is a Flutter application that turns an Android smartphone into a car dashboard: real-time telemetry (speed, altitude, inclination, G-force), a windshield HUD, driving session recording and history, sensor/GNSS diagnostics, and a dashcam feature that records video synchronized with telemetry.

Real hardware validation matters for this project. Several features depend on live sensors, camera hardware, and GNSS — automated tests alone do not prove they work correctly on a real device. See §8.

## 2. Technology Stack

- Flutter 3.x / Dart 3.x
- Android is the platform currently validated on real hardware.
- iOS and Windows are present as build targets but are **not** validated in production — do not assume they work without checking.
- Hive is used for local persistence.
- Camera recording uses the `camera` package; video playback uses `video_player`; location uses `geolocator`; motion sensors use `sensors_plus`.

Do not pin exact package/SDK versions here — check `pubspec.yaml` for the current, authoritative versions.

## 3. Architecture

```
lib/
├── main.dart      — app composition root: MaterialApp + top-level InheritedNotifier scopes
├── models/        — plain data types, including Hive-persisted models (paired with generated .g.dart files)
├── services/       — business logic: sensors, filters, telemetry/event/alert engines, persistence
├── screens/        — one subfolder per functional area (dashboard, hud, onboarding, sessions, settings)
└── widgets/        — reusable UI components, organized by domain (dashboard, dashcam, sensors, telemetry)
```

## 4. Critical Telemetry Pipeline

```
SensorService                          (single source of the physical sensors)
   → TelemetryEngine                   (consumes the shared SensorService instance;
                                          produces filtered/fused signals — speed,
                                          altitude, altitude trend, heading, GNSS
                                          quality, g-force filtering — but does NOT
                                          build TelemetrySnapshot itself)
   → DashboardSensorStreams            (combines TelemetryEngine's signals with
                                          geometry-derived signals taken directly from
                                          SensorService — e.g. pitch/roll, g-force
                                          vehicle-axis mapping — plus any other raw
                                          fields the snapshot needs; this is the class
                                          that constructs TelemetrySnapshot)
   → DashboardSensorStreams.snapshot   (single shared broadcast Stream<TelemetrySnapshot>)
   → consumers:
        - DrivingSessionRecorder
        - EventDetectionEngine
        - AlertEngine
        - DashcamSessionController
```

**Critical rule:** new *functional* telemetry consumers must listen to the existing shared `DashboardSensorStreams.snapshot` stream. Do **not** create a new, independent connection to `SensorService` to obtain the same data.

**Deliberate, diagnostics-only exception:** `DiagnosticsScreen` observes a few raw shared streams (accelerometer/gyroscope/position) alongside `snapshot`, solely to display sensor sample-rate/age/health that the throttled snapshot doesn't carry. It reuses the same `SensorService`/`DashboardSensorStreams` instance passed to it — it does not create its own `SensorService` and does not open a parallel pipeline. This exception is not a pattern to replicate for new features; any new functional consumer follows the critical rule above.

**Known bypass surface:** `DashboardSensorStreams.engine` (the `TelemetryEngine` instance) is currently a public field with no known external consumers. Reaching into it directly would bypass the central `snapshot` stream. No code change is tracked for this yet — flag it if a change proposes consuming `.engine` directly instead of `.snapshot`.

`EventDetectionEngine` is the single, central event detector. Do not duplicate detection logic elsewhere. `AlertEngine` must not take over `EventDetectionEngine`'s role — it presents/gates alerts, it does not independently re-detect the same phenomena.

## 5. Reuse and Architectural Rules

- Do not introduce Provider, Riverpod, Bloc, or any other external state management library without an explicit decision to do so.
- The current pattern is `ChangeNotifier` + `InheritedNotifier` "Scope" widgets for app-wide singletons, with screen-scoped services built manually in `initState`/`didChangeDependencies`/`dispose`.
- Prefer reusing existing components over duplicating them.
- The fullscreen mechanism must remain centralized (one implementation, reused by every instrument).
- The dashboard's tile context menu must remain centralized (one implementation, reused everywhere it's needed).
- Do not duplicate sensor pipelines, telemetry pipelines, or event-detection pipelines.
- Comments should explain non-obvious decisions — especially decisions related to physical bugs, synchronization, sensors, or hardware behavior discovered through real-device testing.

## 6. Persistence — Hive

- Hive is used for local persistence.
- `HiveBoxes.init()` is the single, central place where adapters are registered and boxes are opened.
- A `typeId` registry is maintained as a doc comment in `lib/models/sensor_widget_config.dart` — check it for the current occupied range and the next free id before adding a new persisted type. Do not treat any specific number as fixed here; always verify against that live registry.
- When adding a new persisted model, update that registry comment.
- New fields on an already-persisted model must have a `defaultValue:` or be nullable, to stay backward-compatible with existing stored data.
- After changing a Hive model, regenerate adapters with:
  ```
  dart run build_runner build --delete-conflicting-outputs
  ```

## 7. Testing

- `flutter analyze` and `flutter test` are the standard verification commands.
- Tests use `flutter_test`.
- `test/support/` contains real fakes for relevant native platform interfaces (e.g. camera, video player) — these exercise the real controller classes against a fake platform implementation, not mocks of the app's own classes.
- When writing new tests that touch Hive or `path_provider`, follow the existing patterns already used in the test suite: a temporary directory with `Hive.init(path)` and an adapter-registration guard, opening/closing only the boxes needed; a mocked `MethodChannel` for `path_provider`.
- Do not mask known flakiness as if it were an absence of defects. When a failure is identified as a test-fragility issue (not a product defect), document the cause clearly rather than silently re-running until green.

## 8. Validation Philosophy

Automated tests do **not** substitute for real hardware validation when a feature depends on sensors, camera, GNSS, performance, memory, timing/synchronization, or other physical device behavior.

For that class of feature, consider all of the following as appropriate:
- automated tests
- static analysis
- on-device testing
- logs/evidence collected from the real device
- performance/robustness validation, when relevant

Do not declare a hardware-dependent feature validated without corresponding evidence.

## 9. Git Workflow

- `main` is the primary branch.
- Non-trivial development work should happen on `feature/*` branches.
- Before starting a task, check `git status` and the current branch.
- Before committing, review `git diff`.
- Run `flutter analyze` and `flutter test` before considering a task done.
- Do not `git push` without explicit authorization.
- Do not merge into `main` without explicit authorization.
- Do not use `reset --hard`, `clean -f`, force push, or other destructive operations without explicit, specific authorization.
- Use Conventional Commits, written in English.
- `CLAUDE.md` is part of this project's versioned documentation.

## 10. Security and Operational Boundaries

- Do not read or expose credential/secret files.
- Never expose the contents of `~/.claude/.credentials.json`.
- Do not version `.claude/settings.local.json`.
- Do not delete evidence under `docs/evidence/` without explicit authorization.
- Do not modify `.gitignore` without informing the user first.
- Do not install new dependencies without first proposing the change and explaining why.
- Work within the project workspace by default.
- Do not modify files outside the workspace without explicit authorization.

## 11. Definition of Done

A task is not done just because the code was changed. When applicable, completion should consider:

1. implementation
2. static analysis
3. tests
4. functional validation
5. real hardware validation, when relevant
6. diff review
7. documentation of relevant decisions
8. a coherent Git state

## 12. Multi-Agent Collaboration Protocol

This project follows a defined multi-agent workflow:

- **Codex** — architectural analysis, technical planning, and independent code review.
- **Claude Code** — implementation, running tests, and applying fixes.
- **Git** — history and reversibility.
- **User** — decisions on goals, scope, and architecturally-relevant changes.

**Task tiers:**
- Small: Claude Code → validation → commit.
- Medium: Codex (analysis) → Claude Code (implementation) → validation → commit.
- Critical: Codex (initial analysis) → Claude Code (implementation) → Codex (independent code review) → Claude Code (adjustments, if needed) → final validation → Git commit.

Treat a task as critical, when applicable, if it touches: telemetry; sensors/GNSS; filters/fusion; `DashboardSensorStreams`; `TelemetrySnapshot`; event detection; Hive persistence; camera/dashcam; video/telemetry synchronization; concurrency/lifecycle; performance/memory; architectural changes; or changes that could affect real-hardware validation.

**Operational rules:**
- Codex and Claude Code must not edit the same workspace at the same time — one agent finishes its step before the other starts the next one.
- For a critical task, the implementing agent must not be the sole reviewer of its own change.
- Independent code review is read-only.
- A commit must not bundle changes unrelated to the task at hand.
- Validate before committing, per §7/§8, and treat a task as done only per §11.
- Architecturally-relevant changes remain the user's decision to make.
- This protocol does not itself authorize push, remote creation, destructive resets, or dependency installation — §9 and §10 keep governing those regardless of which agent is acting.
