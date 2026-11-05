-- Mafia Night update 2: profile photos, images in private chats, blocking and reports.
-- Safe to run on the existing database: it only ADDS columns, tables and a bucket (nothing is deleted).
-- Supabase -> SQL Editor -> New query -> paste -> Run.

alter table players add column if not exists photo text not null default '';
alter table messages add column if not exists image text;

create table if not exists blocks (
  blocker uuid not null references players(id) on delete cascade,
  blocked uuid not null references players(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (blocker, blocked)
);

create table if not exists reports (
  id bigserial primary key,
  reporter uuid not null references players(id) on delete cascade,
  target uuid not null references players(id) on delete cascade,
  reason text not null default '' check (char_length(reason) <= 300),
  created_at timestamptz default now()
);

-- Only the game server (service key) touches these: row level security on, no policies,
-- so the public/anon key can read or change nothing.
alter table blocks enable row level security;
alter table reports enable row level security;

-- Private bucket for profile photos (photos/<account>/<version>.jpg) and chat images
-- (chat/<a>_<b>/<name>.jpg). Not public: files are only handed out by the server after it checks
-- who is asking. 1 MB limit, JPEG/PNG only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', false, 1048576, array['image/jpeg', 'image/png'])
on conflict (id) do update set public = false, file_size_limit = 1048576,
  allowed_mime_types = array['image/jpeg', 'image/png'];
