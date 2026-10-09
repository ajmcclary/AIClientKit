# Catalog characterization

CuratedAPIBaseline.json records all 47 curated API identities, model names,
display labels, providers, and default reasoning labels from RepoPrompt before
migration (2026-10-09). The baseline run passed 75 focused app tests. It reads
metadata without clearing or replacing user preferences.

The metadata preserves legacy gpt5/gpt54 slot mappings and provider aliases;
this extraction is not a model-version upgrade. Never rewrite the fixture to
accept a changed model identity or label without an explicit behavior decision.
