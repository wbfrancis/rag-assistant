# Deploying to Fly.io

A runbook for putting the RAG Assistant on a live, clickable URL. The **app** runs
on Fly.io (reusing the repo `Dockerfile`); **Postgres** is a managed instance with
`pgvector` available. We use [Neon](https://neon.tech) for the database because its
free tier includes `pgvector`, is stable (unlike free tiers that expire), and keeps
the vector store off the app host. Fly's own Postgres works too if its image has
pgvector — see the note at the end.

The web process runs **Solid Queue inside Puma** (`SOLID_QUEUE_IN_PUMA=true` in
`fly.toml`), so a single machine serves both web requests and background jobs — no
separate worker to provision.

> Prerequisite: install and log in to the Fly CLI — `flyctl` (`brew install flyctl`,
> then `fly auth login`). All steps below run from `rag-assistant/rag-assistant/`.

## 1. Provision Postgres (Neon) with pgvector

1. Create a Neon project (any region near your Fly region).
2. In the Neon SQL editor, create the four databases Rails 8 expects in production
   (primary + cache + queue + cable):

   ```sql
   CREATE DATABASE rag_assistant_production;
   CREATE DATABASE rag_assistant_production_cache;
   CREATE DATABASE rag_assistant_production_queue;
   CREATE DATABASE rag_assistant_production_cable;
   ```

3. Enable pgvector on the **primary** database (the `db:prepare` migration also does
   this, but enabling it once up front avoids a first-deploy surprise):

   ```sql
   \c rag_assistant_production
   CREATE EXTENSION IF NOT EXISTS vector;
   ```

4. Note the connection string from the Neon dashboard. It looks like:
   `postgresql://USER:PASSWORD@HOST/rag_assistant_production?sslmode=require`
   You'll reuse the same host/credentials, swapping only the database name, for the
   other three.

## 2. Create the Fly app

```bash
fly launch --no-deploy --copy-config --name <your-unique-app-name>
```

`--copy-config` uses the committed `fly.toml`; `--no-deploy` holds off until secrets
are set. Edit `app = "..."` in `fly.toml` if you chose a different name.

## 3. Set secrets

```bash
fly secrets set \
  RAILS_MASTER_KEY="$(cat config/master.key)" \
  OPENAI_API_KEY="sk-..." \
  DATABASE_URL="postgresql://USER:PASSWORD@HOST/rag_assistant_production?sslmode=require" \
  CACHE_DATABASE_URL="postgresql://USER:PASSWORD@HOST/rag_assistant_production_cache?sslmode=require" \
  QUEUE_DATABASE_URL="postgresql://USER:PASSWORD@HOST/rag_assistant_production_queue?sslmode=require" \
  CABLE_DATABASE_URL="postgresql://USER:PASSWORD@HOST/rag_assistant_production_cable?sslmode=require"
```

Rails merges `DATABASE_URL` onto the primary connection and the matching
`*_DATABASE_URL` vars onto the cache/queue/cable connections, overriding the
placeholder username/password/database in `config/database.yml`.

## 4. Deploy

```bash
fly deploy
```

The `release_command` (`bin/rails db:prepare`) runs migrations against all four
databases — enabling pgvector and creating the Solid Queue / Cache / Cable tables —
before the new release goes live.

## 5. Verify the live URL

```bash
fly open        # opens https://<app>.fly.dev
fly logs        # watch boot + the structured retrieval log lines
```

Smoke-test the happy path against the live URL: **sign up → upload a document →
wait for ingestion → ask a question → watch the grounded, streamed answer with
citations appear.** Then check `/dashboard` for token/cost tracking.

## Operating notes

- **Scale to zero.** `fly.toml` sets `min_machines_running = 0`, so the machine
  sleeps when idle (≈ free). A request wakes it; because the worker runs in Puma,
  queued jobs drain once it's awake. If you'd rather jobs run while no one is
  visiting, set `min_machines_running = 1`.
- **Re-indexing / one-off tasks.** Run rake tasks on the live app with
  `fly ssh console -C "bin/rails reindex:status"` (or `reindex:backfill`).
- **Cost.** App on Fly `shared-cpu-1x`/1 GB with scale-to-zero plus Neon's free
  Postgres keeps a portfolio deploy at roughly no cost.

## Alternative: Fly Postgres instead of Neon

If you prefer to keep the database on Fly, you can `fly pg create` and
`fly pg attach` (which sets `DATABASE_URL` for you), then create the three extra
databases on that cluster and set the `*_DATABASE_URL` secrets as above. The catch
is **pgvector**: confirm your Postgres image provides the `vector` extension before
deploying (Fly's default `postgres-flex` image does not always include it). If it
doesn't, run Postgres from the `pgvector/pgvector:pg16` image with a volume, or stay
on a managed pgvector provider like Neon or Supabase.
