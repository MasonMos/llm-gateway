-- test.sql — run AFTER schema.sql:
--   docker compose exec -T postgres psql -U gw -d gateway < test.sql
-- Fake data + checks that constraints work + the queries your gateway will need.

-- ---------- 1. Fake keys (hashes are placeholders, not real SHA-256) ----------
INSERT INTO api_keys (key_hash, key_prefix, owner) VALUES
  ('fakehash_aaa', 'gw_live_aaa', 'mason'),
  ('fakehash_bbb', 'gw_live_bbb', 'capstone-team');

-- ---------- 2. Fake usage rows ----------
-- No id / request_id / created_at listed -> defaults fill them in.
INSERT INTO usage_logs (api_key_id, provider, model, input_tokens, output_tokens, cost, latency_ms, status, cache_hit) VALUES
  (1, 'anthropic', 'claude-haiku',  1200, 300, 0.0006000000, 850,  'success',  false),
  (1, 'openai',    'gpt-mini',      800,  200, 0.0002400000, 620,  'success',  false),
  (1, 'anthropic', 'claude-haiku',  1200, 300, 0,            3,    'success',  true),   -- cache hit: $0, ~3ms
  (2, 'openai',    'gpt-mini',      500,  NULL, NULL,        30000,'error',    false),  -- timed out: no output, no cost
  (2, 'anthropic', 'claude-haiku',  500,  150, 0.0003000000, 1400, 'fallback', false);  -- openai failed, served by anthropic

SELECT * FROM usage_logs;

-- ---------- 3. These SHOULD fail. Each prints an ERROR — that's the test passing. ----------
-- (psql keeps going after errors by default, so the rest of the file still runs.)

-- negative tokens -> CHECK violation
INSERT INTO usage_logs (api_key_id, provider, model, input_tokens, latency_ms, status)
VALUES (1, 'openai', 'gpt-mini', -5, 100, 'success');

-- typo'd status -> CHECK violation
INSERT INTO usage_logs (api_key_id, provider, model, latency_ms, status)
VALUES (1, 'openai', 'gpt-mini', 100, 'failur');

-- key 999 doesn't exist -> foreign key violation
INSERT INTO usage_logs (api_key_id, provider, model, latency_ms, status)
VALUES (999, 'openai', 'gpt-mini', 100, 'success');

-- same request_id twice -> UNIQUE violation (this is your write-behind double-billing guard)
INSERT INTO usage_logs (request_id, api_key_id, provider, model, latency_ms, status)
VALUES ('11111111-1111-1111-1111-111111111111', 1, 'openai', 'gpt-mini', 100, 'success');
INSERT INTO usage_logs (request_id, api_key_id, provider, model, latency_ms, status)
VALUES ('11111111-1111-1111-1111-111111111111', 1, 'openai', 'gpt-mini', 100, 'success');

-- duplicate key hash -> UNIQUE violation
INSERT INTO api_keys (key_hash, key_prefix, owner) VALUES ('fakehash_aaa', 'gw_live_dup', 'someone');

-- ---------- 4. Queries your gateway / results section will need ----------

-- Spend per key this month (the budget check's source of truth)
SELECT k.key_prefix,
       COUNT(*)                     AS requests,
       SUM(u.cost)                  AS total_cost,
       SUM(u.input_tokens)          AS input_tokens,
       SUM(u.output_tokens)         AS output_tokens
FROM usage_logs u
JOIN api_keys k ON k.id = u.api_key_id
WHERE u.created_at >= date_trunc('month', now())
GROUP BY k.key_prefix;

-- Error / fallback rate by provider
SELECT provider,
       COUNT(*)                                        AS requests,
       COUNT(*) FILTER (WHERE status = 'error')        AS errors,
       COUNT(*) FILTER (WHERE status = 'fallback')     AS fallbacks
FROM usage_logs
GROUP BY provider;

-- Cache hit rate and money saved
SELECT ROUND(100.0 * AVG(cache_hit::int), 1)  AS cache_hit_pct
FROM usage_logs;

-- p50 / p95 latency, excluding cache hits
SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY latency_ms) AS p50_ms,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms) AS p95_ms
FROM usage_logs
WHERE NOT cache_hit;
