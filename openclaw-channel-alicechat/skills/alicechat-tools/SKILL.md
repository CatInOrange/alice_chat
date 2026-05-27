---
name: alicechat-tools
description: "Use AliceChat music, todo, and habit tools through the AliceChat bridge."
---

# AliceChat Tools

Use this skill when an AliceChat conversation needs music playback, AI playlist recommendations, todo changes, todo lookup, habit check-ins, habit edits, or habit stats.

## Music

- Use `music_action` when the user clearly asks to play, pause, resume, skip, queue, or reorder music.
- Use `music_action` with `type: "save_ai_playlist"` when the user wants recommendations saved to AliceChat's home card without interrupting playback.
- Use `get_latest_ai_playlist` to inspect the latest saved recommendation.
- Do not invent action types. Ask briefly if the track, playlist, or desired playback action is missing.

## Todo

- Use `get_todo_snapshot` before editing an existing task or project unless the user supplied a precise id.
- Use `todo_action` directly for clear new-task requests.
- Prefer a matching existing project by `projectId` or `projectName`; otherwise let the backend use the inbox fallback.
- Do not default tasks to `工作` unless the task clearly belongs there.
- For exact due/reminder times, pass `dueAt` or `reminderAt` as ISO 8601 with offset.
- For relative phrases such as `明晚`, `明天 10:00`, `下周四`, or `tomorrow night`, pass `dueDateText` or `reminderDateText`. The tool resolves these using Asia/Shanghai runtime time.
- If an existing task reference is ambiguous, ask one concise follow-up instead of guessing.

## Habits

- Use `get_habit_snapshot` before updating, deleting, pausing, resuming, or checking an ambiguous existing habit.
- Use `habit_action` directly for clear new-habit requests.
- `frequency` is `daily` or `weekly`.
- Weekly `weekdays` uses ISO weekdays: 1=Monday, 7=Sunday.
- `reminderTime` is local `HH:mm`; pass an empty string to clear it.
- Use `active: false` to pause and `active: true` to resume.
- Do not invent habit actions.
