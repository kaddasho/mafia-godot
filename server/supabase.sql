-- Mafia Night: tables for accounts, friendships and messages.
-- Paste this whole file into Supabase -> SQL Editor -> New query, then press Run.
-- Only the game server reads and writes these tables (with the service_role key);
-- row level security is on with no policies, so the public anon key can't touch them.

create table if not exists players (
  id uuid primary key,
  secret_hash text not null,
  name text not null,
  gender text,
  country text,
  tag int not null,
  last_seen timestamptz default now()
);

create table if not exists friendships (
  a uuid not null references players(id) on delete cascade,
  b uuid not null references players(id) on delete cascade,
  status text not null check (status in ('pending', 'accepted')),
  requester uuid not null,
  created_at timestamptz default now(),
  primary key (a, b)
);

create table if not exists messages (
  id bigserial primary key,
  sender uuid not null references players(id) on delete cascade,
  receiver uuid not null references players(id) on delete cascade,
  body text not null check (char_length(body) <= 500),
  read boolean not null default false,
  created_at timestamptz default now()
);

create index if not exists players_name_idx on players (lower(name));
create index if not exists messages_unread_idx on messages (receiver, read);
create index if not exists messages_pair_idx on messages (sender, receiver, id);

alter table players enable row level security;
alter table friendships enable row level security;
alter table messages enable row level security;
