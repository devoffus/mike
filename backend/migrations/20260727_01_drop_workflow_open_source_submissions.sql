-- Migration date: 2026-07-27

-- Drops the open-source workflow submission queue. Courier is no longer an
-- open-source project, so the public-submission pipeline is retired. Any
-- pending rows are intentionally dropped along with the table; users will
-- see no submissions tab and have no recourse via this path.

drop table if exists public.workflow_open_source_submissions cascade;
