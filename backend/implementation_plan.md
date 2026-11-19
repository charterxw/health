# Sleep Analysis Implementation

This feature is implemented.

- `google_health.py` fetches paginated sleep records, parses stages, removes known duplicates, and assigns each main sleep to its local wake date.
- `GET /api/health/sleep` returns recent detailed sleep sessions.
- `openai_service.py` uses the OpenAI Responses API to generate a Chinese recovery-focused sleep analysis from the latest non-nap record.
- `SleepTab.jsx` renders the stage timeline, duration summaries, and the current OpenAI analysis.

The service does not generate substitute or mock analysis when Google Health or OpenAI is unavailable. The API returns an explicit error and leaves stored analysis unchanged.
