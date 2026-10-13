-- Fresh Rails RDS database only; run interactively with psql as master postgres.
-- Does NOT touch the existing Praefect database and does NOT run Rails migrations.
\set ON_ERROR_STOP on
CREATE ROLE gitlab LOGIN;
\password gitlab
-- PostgreSQL 17 requires the creator to be able to SET ROLE to the owner.
GRANT gitlab TO postgres WITH SET TRUE;
CREATE DATABASE gitlabhq_production OWNER gitlab ENCODING 'UTF8';
REVOKE gitlab FROM postgres;
\connect gitlabhq_production
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS amcheck;
GRANT USAGE, CREATE ON SCHEMA public TO gitlab;
SELECT datname, pg_get_userbyid(datdba) AS owner
FROM pg_database WHERE datname = 'gitlabhq_production';
\dx
