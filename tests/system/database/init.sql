-- Disposable fixture: intentionally public local-only credentials.
CREATE ROLE assessment_app LOGIN PASSWORD 'local-test-only';
GRANT CONNECT ON DATABASE assessment TO assessment_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO assessment_app;
ALTER ROLE assessment_app SET default_transaction_read_only = on;
