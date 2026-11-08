-- schema.sql — run with:
--   docker compose exec -T postgres psql -U gw -d gateway < schema.sql
-- WARNING: drops and recreates the tables (fine while it's all practice data).

DROP TABLE IF EXISTS usage_logs;   -- drop the child table first (it references api_keys)
DROP TABLE IF EXISTS api_keys;

CREATE TABLE api_keys (
  id                BIGSERIAL PRIMARY KEY,           -- internal id; usage_logs points at this
  key_hash          TEXT NOT NULL UNIQUE,            -- SHA-256 of the real key; UNIQUE = fast lookup + no dupes
  key_prefix        TEXT NOT NULL,                   -- e.g. 'gw_live_ab12' — stored plain so you can tell keys apart
  owner             TEXT NOT NULL,
  req_per_min       INTEGER NOT NULL DEFAULT 60     CHECK (req_per_min > 0),
  tokens_per_day    INTEGER NOT NULL DEFAULT 100000 CHECK (tokens_per_day > 0),
  monthly_budget    NUMERIC(10, 2) NOT NULL DEFAULT 10.00 CHECK (monthly_budget >= 0),  -- dollars
  allowed_models    TEXT[] NOT NULL DEFAULT '{}',    -- Postgres array; empty = no restriction (your call)
  status            TEXT NOT NULL DEFAULT 'active'  CHECK (status IN ('active', 'revoked')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE usage_logs (
  id                BIGSERIAL PRIMARY KEY,
  request_id        UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                    -- one id per request. UNIQUE makes write-behind flushes safe to retry:
                    -- inserting the same request twice fails instead of double-billing.
  api_key_id        BIGINT NOT NULL REFERENCES api_keys(id),
                    -- foreign key: Postgres rejects rows pointing at a key that doesn't exist
  provider          TEXT NOT NULL CHECK (provider IN ('anthropic', 'openai', 'ollama')),
  model             TEXT NOT NULL,                   -- e.g. 'claude-haiku-...'; price depends on this
  input_tokens      INTEGER CHECK (input_tokens  >= 0),  -- NULL allowed = "provider never told us"
  output_tokens     INTEGER CHECK (output_tokens >= 0),  --   (e.g. request failed before a response)
  cost              NUMERIC(14, 10) CHECK (cost >= 0),
                    -- 14 digits total, 10 after the decimal. A cheap model can cost ~$0.0000001
                    -- per token, so you need ~7+ decimal places or small costs round to 0.
  latency_ms        INTEGER NOT NULL CHECK (latency_ms >= 0),  -- whole milliseconds, simplest
  status            TEXT NOT NULL CHECK (status IN ('success', 'error', 'fallback')),
  cache_hit         BOOLEAN NOT NULL DEFAULT false,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Your most common query is "usage for key X in time range Y". This index makes it fast
-- instead of scanning every row. (Try EXPLAIN on the queries in test.sql with and without it.)
CREATE INDEX usage_logs_key_time ON usage_logs (api_key_id, created_at);
