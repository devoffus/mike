# Courier

![Courier](https://app.courier.com/link-image.jpg)

Courier is a legal AI platform that is able to assist you with document review, drafting and legal research.

It has a Next.js frontend, an Express backend, Supabase Auth/Postgres, and Cloudflare R2-compatible object storage.

Website: [app.courier.com](https://app.courier.com)

## Contents

- `frontend/` - Next.js application
- `backend/` - Express API, Supabase access, document processing, and database schema
- `backend/schema.sql` - Supabase schema for fresh databases
- `backend/migrations/` - dated, incremental schema migrations; on an existing database, apply the files dated after the Courier version you deployed

## System Workflows

Courier's system assistant and tabular review workflows are maintained in the
[`Open-Legal-Products/courier-workflows`](https://github.com/Open-Legal-Products/courier-workflows)
repository.

## Prerequisites

- Node.js 20 or newer
- npm
- git
- A Supabase project
- A Cloudflare R2 bucket, MinIO bucket, or another S3-compatible bucket
- At least one supported model provider API key: Anthropic, Google Gemini, or OpenAI
- Optional: a CourtListener API token for case law lookup and citation verification
- LibreOffice installed locally if you need DOC/DOCX to PDF conversion

## Database Setup

For a new Supabase database, open the Supabase SQL editor and run:

```sql
-- copy and run the contents of:
-- backend/schema.sql
```

The schema file is for fresh deployments and already includes the latest database shape.

For an existing database, do not run the full schema file over production data. Instead, apply the incremental files in `backend/migrations/`: run the migrations dated **after** the version of Courier you currently have deployed, in filename order. Each file is named `YYYYMMDD_<name>.sql` (the date is also recorded in a comment at the top of the file) and is written to be safe to re-run, so when unsure you can re-apply the most recent migrations without harm.

## Upgrading from pre-rebrand Mike deploys

> Skip this section if you are installing Courier fresh against an empty database. It documents the manual operator steps required when upgrading an existing deployment that ran when the project was branded Mike or MikeOSS.

Two breaking changes from the rebrand require manual operator action against any existing production data.

### Encryption salts for stored secrets

The salts used to derive the per-row AES-GCM key for stored users' API keys and MCP connector tokens both changed:

| Table | Old salt | New salt |
| --- | --- | --- |
| `public.user_api_keys`         | `mike-user-api-keys-v1` | `courier-user-api-keys-v1` |
| `public.user_mcp_connectors`   | `mike-user-mcp-v1`      | `courier-user-mcp-v1`      |

The encrypted blob format does not carry a version prefix, so the new code **cannot decrypt values encrypted with the old salt**. The backend's `decrypt()` returns `null` on auth-tag failure rather than throwing, so upgraded installations will appear to silently lose every user's saved API key and MCP connection.

Two options, in order of operational difficulty:

1. **Wipe and re-add.** Surface a "please re-add your API keys and reconnect MCP servers" banner in your release notes, then truncate the two tables:

   ```sql
   delete from public.user_api_keys;
   delete from public.user_mcp_connectors;
   ```

2. **Re-encrypt in place** (preserves user data). Run a one-off Node script that reads each row, decrypts with the old salt, re-encrypts with the new salt, and UPSERTs back. The `USER_API_KEYS_ENCRYPTION_SECRET` env var must remain unchanged across the upgrade (it is the password input to `scryptSync`). Stop the backend before running the script to avoid races; restart on the new code afterwards. A reference implementation lives at `backend/scripts/migrate-rebrand-encryption.ts`; an ad-hoc script using `crypto.scryptSync` and `crypto.createDecipheriv` directly works equally well for small user counts.

### R2 object storage bucket

The default value of `R2_BUCKET_NAME` in `backend/.env.example` changed from `mike` to `courier`. Copy or rename the bucket before flipping the env var; otherwise leave `R2_BUCKET_NAME=mike` in your `.env` until ready.

R2 is S3-compatible, so the AWS CLI works with an `--endpoint-url`:

```bash
# Option A: copy (safer; the old bucket stays around as a rollback target)
aws s3 sync s3://mike s3://courier \
  --endpoint-url https://<account-id>.r2.cloudflarestorage.com

# Option B: move (cleaner blast radius once you have validated the copy)
aws s3 sync s3://mike s3://courier \
  --endpoint-url https://<account-id>.r2.cloudflarestorage.com
aws s3 rm s3://mike --recursive \
  --endpoint-url https://<account-id>.r2.cloudflarestorage.com
```

After the copy, flip `R2_BUCKET_NAME=courier` in `backend/.env` and restart the backend.

### Optional cleanup

Local Supabase instances used for e2e testing may still hold an `e2e@mike.local` user from before the rebrand. The new e2e setup uses `e2e@courier.local`. The two coexist harmlessly; no action required.

## Environment

Create local env files:

```bash
touch backend/.env
touch frontend/.env.local
```

Create `backend/.env`:

```bash
PORT=3001
FRONTEND_URL=http://localhost:3000
DOWNLOAD_SIGNING_SECRET=replace-with-a-random-32-byte-hex-string
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SECRET_KEY=your-supabase-service-role-key

R2_ENDPOINT_URL=https://your-account-id.r2.cloudflarestorage.com
R2_ACCESS_KEY_ID=your-r2-access-key
R2_SECRET_ACCESS_KEY=your-r2-secret-key
R2_BUCKET_NAME=courier

GEMINI_API_KEY=your-gemini-key
ANTHROPIC_API_KEY=your-anthropic-key
OPENAI_API_KEY=your-openai-key
RESEND_API_KEY=your-resend-key
USER_API_KEYS_ENCRYPTION_SECRET=your-long-random-secret

# Optional: enables CourtListener case law and citation tools.
COURTLISTENER_API_TOKEN=your-courtlistener-token

# Optional: use locally imported CourtListener bulk data for faster case reads.
COURTLISTENER_BULK_DATA_ENABLED=false
```

Create `frontend/.env.local`:

```bash
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY=your-supabase-anon-key
NEXT_PUBLIC_API_BASE_URL=http://localhost:3001
```

Supabase values come from the project dashboard. Use the project URL for `SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_URL`, the service role key for the backend `SUPABASE_SECRET_KEY`, and the anon/public key for `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY`. If your Supabase project shows multiple key formats, use the legacy JWT-style anon and service role keys expected by the Supabase client libraries.

Provider keys are only needed for the models, legal research, and email features you plan to use. Model provider keys and the CourtListener token can be configured in `backend/.env` for the whole instance, or per user in **Account > Models & API Keys**. If a provider key is present in `backend/.env`, that provider is available by default and the matching browser API key field is read-only.

## CourtListener Integration

Courier can use CourtListener for US case law citation verification, case fetching, targeted opinion search, and case-law panels in assistant responses.

To enable live CourtListener access, set `COURTLISTENER_API_TOKEN` in `backend/.env` and restart the backend. Users can also add their own CourtListener token from **Account > Models & API Keys** when the instance does not provide one globally.

Fresh databases created from `backend/schema.sql` already include the CourtListener support tables. Existing deployments should apply the matching dated migration in `backend/migrations/` before enabling the feature.

Bulk data is optional. When `COURTLISTENER_BULK_DATA_ENABLED=true`, Courier first tries local Supabase/R2 data before falling back to CourtListener's API:

- citation metadata is read from `public.courtlistener_citation_index`
- case cluster metadata is read from `public.courtlistener_opinion_cluster_index`
- cached opinion JSON is read from the R2 prefix `courtlistener/opinions/by-cluster/{clusterId}/{opinionId}.json`

If you do not import bulk data, leave `COURTLISTENER_BULK_DATA_ENABLED=false`; live CourtListener tools still work with a valid token, subject to CourtListener rate limits.

## Install

Install each app package:

```bash
npm install --prefix backend
npm install --prefix frontend
```

## Run Locally

Start the backend:

```bash
npm run dev --prefix backend
```

Start the main app:

```bash
npm run dev --prefix frontend
```

Open `http://localhost:3000`.

## First Run

1. Sign up in the app.
2. If you did not set provider keys in `backend/.env`, open **Account > Models & API Keys** and add an Anthropic, Gemini, or OpenAI API key.
3. To use legal research tools, add a CourtListener token in `backend/.env` or **Account > Models & API Keys**.
4. Create or open a project and start chatting with documents.

## Troubleshooting

**Sign-up confirmation email never arrives.** Confirmation emails are sent by Supabase Auth, not by Courier. For local development, the simplest fix is to disable email confirmation in **Supabase > Authentication > Providers > Email**. For production, configure custom SMTP in Supabase; the built-in mailer is heavily rate-limited and may be restricted on newer projects.

**The model picker shows a missing-key warning.** Add a key for that provider in **Account > Models & API Keys**, or configure the provider key in `backend/.env` and restart the backend.

**CourtListener tools say the API token is missing.** Set `COURTLISTENER_API_TOKEN` in `backend/.env`, or add a CourtListener token in **Account > Models & API Keys** for the signed-in user. Restart the backend after changing `.env`.

**CourtListener bulk lookup is not returning local results.** Confirm `COURTLISTENER_BULK_DATA_ENABLED=true`, the two CourtListener tables have been populated, and opinion JSON exists in R2 under `courtlistener/opinions/by-cluster/`. If bulk data is unavailable, Courier falls back to the live API when a token is configured.

**DOC or DOCX conversion fails.** Install LibreOffice locally and restart the backend so document conversion commands are available on the process path.

## Useful Checks

```bash
npm run build --prefix backend
npm run build --prefix frontend
npm run lint --prefix frontend
```
