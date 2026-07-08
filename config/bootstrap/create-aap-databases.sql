-- AAP 2.6 database bootstrap for EDB Postgres Advanced Server.
-- Run on the primary (pg-dc1) as the enterprisedb superuser.
-- Databases replicate automatically to pg-dc2 via streaming replication.

CREATE ROLE aap LOGIN PASSWORD 'RedHatEDB2026!';

CREATE DATABASE awx OWNER aap;
CREATE DATABASE automationhub OWNER aap;
CREATE DATABASE automationedacontroller OWNER aap;
CREATE DATABASE automationgateway OWNER aap;

\c automationhub
CREATE EXTENSION IF NOT EXISTS hstore;
