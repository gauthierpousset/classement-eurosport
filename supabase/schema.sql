-- =====================================================================
--  Classement Eurosport : base de données (Supabase / PostgreSQL)
--  À coller en une fois dans Supabase > SQL Editor > New query > Run.
--  Peut être relancé sans risque (les objets existants sont remplacés ;
--  les données déjà saisies sont conservées).
--
--  Principe : aucune table n'est accessible directement depuis l'application.
--  Tout passe par des fonctions qui vérifient qui est connecté (jeton de session),
--  son rôle, la date de clôture, etc. Les règles sont donc appliquées côté serveur.
-- =====================================================================

create extension if not exists unaccent with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- Nom « normalisé » : minuscules, sans accents, espaces uniques.
create or replace function public.norm_name(t text)
returns text language sql immutable parallel safe
set search_path = public, extensions
as $$
  select lower(btrim(regexp_replace(
           translate(extensions.unaccent('extensions.unaccent', coalesce(t, '')), '´’`', ''''''''),
           '\s+', ' ', 'g')))
$$;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.seasons (
  id           int primary key,
  label        text not null,
  closes_at    timestamptz not null,       -- clôture des pronos (heure de Paris = UTC+1 en décembre)
  first_reveal date,
  created_at   timestamptz not null default now()
);

create table if not exists public.accounts (
  id              uuid primary key default gen_random_uuid(),
  pseudo          text not null check (char_length(btrim(pseudo)) between 2 and 24),
  pass_hash       text not null,
  role            text not null default 'member' check (role in ('member', 'gamemaster')),
  failed_attempts int  not null default 0,
  locked_until    timestamptz,
  created_at      timestamptz not null default now()
);
create unique index if not exists accounts_pseudo_uq on public.accounts (public.norm_name(pseudo));

create table if not exists public.account_tokens (
  token_hash text primary key,
  account_id uuid not null references public.accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '120 days'
);
create index if not exists account_tokens_account_idx on public.account_tokens(account_id);

create table if not exists public.leagues (
  id         uuid primary key default gen_random_uuid(),
  season     int  not null references public.seasons(id),
  name       text not null check (char_length(btrim(name)) between 2 and 40),
  code       text not null unique,
  owner_id   uuid references public.accounts(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.league_members (
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id   uuid not null references public.accounts(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (league_id, user_id)
);
create index if not exists league_members_user_idx on public.league_members(user_id);

create table if not exists public.picks (
  season     int  not null references public.seasons(id),
  user_id    uuid not null references public.accounts(id) on delete cascade,
  classement text not null check (classement in ('monde', 'france')),
  pos        int  not null check (pos between 1 and 10),
  name       text not null check (char_length(btrim(name)) between 1 and 80),
  primary key (season, user_id, classement, pos)
);
create unique index if not exists picks_no_duplicate on public.picks (season, user_id, classement, public.norm_name(name));

create table if not exists public.pick_status (
  season     int  not null references public.seasons(id),
  user_id    uuid not null references public.accounts(id) on delete cascade,
  validated  boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (season, user_id)
);

create table if not exists public.reveals (
  season     int  not null references public.seasons(id),
  classement text not null check (classement in ('monde', 'france')),
  rank       int  not null check (rank between 1 and 10),
  name       text not null check (char_length(btrim(name)) between 1 and 80),
  updated_at timestamptz not null default now(),
  primary key (season, classement, rank)
);

create table if not exists public.athlete_sports (
  key        text primary key,
  sport      text not null check (sport in ('foot','tennis','basket','rugby','athle','nat','velo','auto','ski','nordic','judo','tt','voile','gym','golf','other')),
  set_by     uuid references public.accounts(id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Règles de rapprochement de noms décidées par les gamemasters.
-- kind = alias | distinct | notalias
create table if not exists public.name_rules (
  season int  not null references public.seasons(id),
  kind   text not null check (kind in ('alias', 'distinct', 'notalias')),
  k      text not null,
  v      text not null default '',
  primary key (season, kind, k)
);

-- Saison 2026 (la date de clôture peut être modifiée plus tard avec une requête UPDATE)
insert into public.seasons (id, label, closes_at, first_reveal)
values (2026, 'Top 10 athlètes 2026', '2026-12-20 23:59:59+01', '2026-12-22')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- Verrouillage : aucune lecture ni écriture directe des tables
-- ---------------------------------------------------------------------
alter table public.seasons        enable row level security;
alter table public.accounts       enable row level security;
alter table public.account_tokens enable row level security;
alter table public.leagues        enable row level security;
alter table public.league_members enable row level security;
alter table public.picks          enable row level security;
alter table public.pick_status    enable row level security;
alter table public.reveals        enable row level security;
alter table public.athlete_sports enable row level security;
alter table public.name_rules     enable row level security;
revoke all on all tables in schema public from anon, authenticated;

-- ---------------------------------------------------------------------
-- Fonctions internes
-- ---------------------------------------------------------------------
create or replace function public._me(p_token text)
returns public.accounts language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts;
begin
  select ac.* into a from public.account_tokens t join public.accounts ac on ac.id = t.account_id
   where t.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') and t.expires_at > now();
  if not found then raise exception 'not_authenticated'; end if;
  return a;
end $$;

create or replace function public._is_closed(p_season int)
returns boolean language sql stable security definer set search_path = public, extensions
as $$ select coalesce((select now() >= closes_at from public.seasons where id = p_season), false) $$;

create or replace function public._new_token(p_account uuid)
returns text language plpgsql security definer set search_path = public, extensions
as $$
declare v_raw text := translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/=', '-_');
begin
  insert into public.account_tokens (token_hash, account_id) values (encode(extensions.digest(v_raw, 'sha256'), 'hex'), p_account);
  delete from public.account_tokens where account_id = p_account and expires_at < now();
  return v_raw;
end $$;

create or replace function public._me_json(a public.accounts)
returns jsonb language sql immutable as $$ select jsonb_build_object('id', a.id, 'pseudo', a.pseudo, 'role', a.role) $$;

-- ---------------------------------------------------------------------
-- Fonctions publiques (appelables sans être connecté)
-- ---------------------------------------------------------------------
create or replace function public.server_info()
returns jsonb language sql stable security definer set search_path = public, extensions
as $$
  select jsonb_build_object('now', now(),
    'seasons', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', label, 'closes_at', closes_at, 'first_reveal', first_reveal) order by id) from public.seasons), '[]'::jsonb))
$$;

create or replace function public.pseudo_available(p_pseudo text)
returns boolean language sql stable security definer set search_path = public, extensions
as $$ select not exists (select 1 from public.accounts where public.norm_name(pseudo) = public.norm_name(p_pseudo)) $$;

create or replace function public.register(p_pseudo text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_pseudo text := btrim(regexp_replace(coalesce(p_pseudo, ''), '\s+', ' ', 'g')); a public.accounts;
begin
  if char_length(v_pseudo) not between 2 and 24 or v_pseudo ~ '[<>"&\\[:cntrl:]]' then raise exception 'bad_pseudo'; end if;
  if char_length(coalesce(p_code, '')) < 6 then raise exception 'weak_password'; end if;
  if (select count(*) from public.accounts where created_at > now() - interval '1 hour') >= 100 then raise exception 'busy'; end if;
  begin
    insert into public.accounts (pseudo, pass_hash) values (v_pseudo, extensions.crypt(p_code, extensions.gen_salt('bf', 8))) returning * into a;
  exception when unique_violation then raise exception 'pseudo_taken';
  end;
  return jsonb_build_object('ok', true, 'token', public._new_token(a.id), 'me', public._me_json(a));
end $$;

-- Connexion. Renvoie un objet (et non une erreur) pour pouvoir compter les échecs.
create or replace function public.login(p_pseudo text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts;
begin
  select * into a from public.accounts where public.norm_name(pseudo) = public.norm_name(p_pseudo);
  if not found then return jsonb_build_object('ok', false, 'error', 'bad_credentials'); end if;
  if a.locked_until is not null and a.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked', 'retry_in', ceil(extract(epoch from (a.locked_until - now())))::int);
  end if;
  if a.pass_hash = extensions.crypt(coalesce(p_code, ''), a.pass_hash) then
    update public.accounts set failed_attempts = 0, locked_until = null where id = a.id;
    return jsonb_build_object('ok', true, 'token', public._new_token(a.id), 'me', public._me_json(a));
  end if;
  update public.accounts set
         locked_until = case when failed_attempts + 1 >= 6 then now() + interval '10 minutes' else locked_until end,
         failed_attempts = case when failed_attempts + 1 >= 6 then 0 else failed_attempts + 1 end
   where id = a.id;
  return jsonb_build_object('ok', false, 'error', 'bad_credentials');
end $$;

create or replace function public.logout(p_token text)
returns void language sql security definer set search_path = public, extensions
as $$ delete from public.account_tokens where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') $$;

-- ---------------------------------------------------------------------
-- Lecture : tout ce que le joueur connecté a le droit de voir, en un seul appel
-- ---------------------------------------------------------------------
create or replace function public.snapshot(p_token text, p_season int default null)
returns jsonb language plpgsql stable security definer set search_path = public, extensions
as $$
declare
  a public.accounts := public._me(p_token); s public.seasons;
  v_closed boolean; v_gm boolean := (a.role = 'gamemaster'); v_mine uuid[]; v_co uuid[];
begin
  select * into s from public.seasons where id = coalesce(p_season, (select max(id) from public.seasons));
  v_closed := now() >= s.closes_at;
  select coalesce(array_agg(league_id), '{}') into v_mine from public.league_members where user_id = a.id;
  select coalesce(array_agg(distinct user_id), '{}') into v_co from public.league_members where league_id = any(v_mine);
  return jsonb_build_object(
    'now', now(),
    'season', jsonb_build_object('id', s.id, 'label', s.label, 'closes_at', s.closes_at, 'first_reveal', s.first_reveal),
    'me', public._me_json(a),
    'profiles', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'pseudo', pseudo, 'role', role) order by pseudo), '[]'::jsonb)
                  from public.accounts where id = a.id or v_gm or id = any(v_co)),
    'leagues', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'code', code, 'owner_id', owner_id) order by name), '[]'::jsonb)
                  from public.leagues where season = s.id and (id = any(v_mine) or v_gm)),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('league_id', m.league_id, 'user_id', m.user_id)), '[]'::jsonb)
                  from public.league_members m join public.leagues l on l.id = m.league_id
                 where l.season = s.id and (m.league_id = any(v_mine) or v_gm)),
    'picks', (select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'classement', classement, 'pos', pos, 'name', name)), '[]'::jsonb)
                from public.picks where season = s.id and (user_id = a.id or (v_closed and (v_gm or user_id = any(v_co))))),
    'status', (select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'validated', validated)), '[]'::jsonb)
                 from public.pick_status where season = s.id and (user_id = a.id or (v_closed and (v_gm or user_id = any(v_co))))),
    'reveals', (select coalesce(jsonb_agg(jsonb_build_object('classement', classement, 'rank', rank, 'name', name)), '[]'::jsonb) from public.reveals where season = s.id),
    'sports', (select coalesce(jsonb_agg(jsonb_build_object('key', key, 'sport', sport)), '[]'::jsonb) from public.athlete_sports),
    'rules', case when v_closed then (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'k', k, 'v', v)), '[]'::jsonb) from public.name_rules where season = s.id) else '[]'::jsonb end
  );
end $$;

-- ---------------------------------------------------------------------
-- Compte
-- ---------------------------------------------------------------------
create or replace function public.change_code(p_token text, p_old text, p_new text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token);
begin
  if char_length(coalesce(p_new, '')) < 6 then raise exception 'weak_password'; end if;
  if a.locked_until is not null and a.locked_until > now() then return jsonb_build_object('ok', false, 'error', 'locked'); end if;
  if a.pass_hash <> extensions.crypt(coalesce(p_old, ''), a.pass_hash) then
    update public.accounts set
           locked_until = case when failed_attempts + 1 >= 6 then now() + interval '10 minutes' else locked_until end,
           failed_attempts = case when failed_attempts + 1 >= 6 then 0 else failed_attempts + 1 end where id = a.id;
    return jsonb_build_object('ok', false, 'error', 'bad_credentials');
  end if;
  update public.accounts set pass_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 8)), failed_attempts = 0 where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.delete_my_account(p_token text)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token);
begin
  if a.role = 'gamemaster' and (select count(*) from public.accounts where role = 'gamemaster') <= 1 then raise exception 'last_gamemaster'; end if;
  delete from public.accounts where id = a.id;
end $$;

-- ---------------------------------------------------------------------
-- Pronos
-- ---------------------------------------------------------------------
create or replace function public.save_picks(p_token text, p_season int, p_monde text[], p_france text[], p_validate boolean default false)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare
  a public.accounts := public._me(p_token);
  v_cls text; v_arr text[]; i int; v_name text; v_filled int;
begin
  if public._is_closed(p_season) then raise exception 'closed'; end if;
  if not exists (select 1 from public.seasons where id = p_season) then raise exception 'unknown_season'; end if;
  foreach v_cls in array array['monde', 'france'] loop
    v_arr := case v_cls when 'monde' then p_monde else p_france end;
    if v_arr is null or coalesce(array_length(v_arr, 1), 0) <> 10 then raise exception 'bad_list'; end if;
    v_filled := 0;
    for i in 1..10 loop if btrim(coalesce(v_arr[i], '')) <> '' then v_filled := v_filled + 1; end if; end loop;
    if p_validate and v_filled < 10 then raise exception 'incomplete'; end if;
    if exists (select 1 from (select public.norm_name(x) n from unnest(v_arr) x where btrim(coalesce(x, '')) <> '') s group by n having count(*) > 1) then
      raise exception 'duplicate';
    end if;
  end loop;
  foreach v_cls in array array['monde', 'france'] loop
    v_arr := case v_cls when 'monde' then p_monde else p_france end;
    delete from public.picks where season = p_season and user_id = a.id and classement = v_cls;
    for i in 1..10 loop
      v_name := btrim(coalesce(v_arr[i], ''));
      if v_name <> '' then insert into public.picks (season, user_id, classement, pos, name) values (p_season, a.id, v_cls, i, v_name); end if;
    end loop;
  end loop;
  insert into public.pick_status (season, user_id, validated, updated_at) values (p_season, a.id, p_validate, now())
  on conflict (season, user_id) do update set validated = excluded.validated, updated_at = now();
end $$;

-- ---------------------------------------------------------------------
-- Ligues
-- ---------------------------------------------------------------------
create or replace function public.create_league(p_token text, p_season int, p_name text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token); v_code text; v_row public.leagues; al text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  if char_length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'bad_name'; end if;
  loop
    v_code := '';
    for i in 1..6 loop v_code := v_code || substr(al, 1 + floor(random() * length(al))::int, 1); end loop;
    exit when not exists (select 1 from public.leagues where code = v_code);
  end loop;
  insert into public.leagues (season, name, code, owner_id) values (p_season, btrim(p_name), v_code, a.id) returning * into v_row;
  insert into public.league_members (league_id, user_id) values (v_row.id, a.id);
  return jsonb_build_object('id', v_row.id, 'name', v_row.name, 'code', v_row.code);
end $$;

create or replace function public.join_league(p_token text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token); v_row public.leagues;
begin
  select * into v_row from public.leagues where code = upper(btrim(coalesce(p_code, '')));
  if not found then raise exception 'unknown_code'; end if;
  if exists (select 1 from public.league_members where league_id = v_row.id and user_id = a.id) then raise exception 'already_member'; end if;
  insert into public.league_members (league_id, user_id) values (v_row.id, a.id);
  return jsonb_build_object('id', v_row.id, 'name', v_row.name, 'code', v_row.code);
end $$;

create or replace function public.leave_league(p_token text, p_league uuid)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token); v_next uuid;
begin
  delete from public.league_members where league_id = p_league and user_id = a.id;
  if exists (select 1 from public.leagues where id = p_league and owner_id = a.id) then
    select user_id into v_next from public.league_members where league_id = p_league order by joined_at limit 1;
    if v_next is null then delete from public.leagues where id = p_league;
    else update public.leagues set owner_id = v_next where id = p_league; end if;
  end if;
end $$;

create or replace function public.rename_league(p_token text, p_league uuid, p_name text)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token);
begin
  if char_length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'bad_name'; end if;
  update public.leagues set name = btrim(p_name) where id = p_league and (owner_id = a.id or a.role = 'gamemaster');
  if not found then raise exception 'forbidden'; end if;
end $$;

create or replace function public.remove_member(p_token text, p_league uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token);
begin
  if not exists (select 1 from public.leagues where id = p_league and (owner_id = a.id or a.role = 'gamemaster')) then raise exception 'forbidden'; end if;
  if p_user = (select owner_id from public.leagues where id = p_league) then raise exception 'owner_cannot_be_removed'; end if;
  delete from public.league_members where league_id = p_league and user_id = p_user;
end $$;

create or replace function public.delete_league(p_token text, p_league uuid)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token);
begin
  delete from public.leagues where id = p_league and (owner_id = a.id or a.role = 'gamemaster');
  if not found then raise exception 'forbidden'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Gamemaster
-- ---------------------------------------------------------------------
create or replace function public.set_reveal(p_token text, p_season int, p_classement text, p_rank int, p_name text)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token);
begin
  if a.role <> 'gamemaster' then raise exception 'forbidden'; end if;
  if btrim(coalesce(p_name, '')) = '' then
    delete from public.reveals where season = p_season and classement = p_classement and rank = p_rank;
  else
    insert into public.reveals (season, classement, rank, name) values (p_season, p_classement, p_rank, btrim(p_name))
    on conflict (season, classement, rank) do update set name = excluded.name, updated_at = now();
  end if;
end $$;

create or replace function public.set_sport(p_token text, p_key text, p_sport text)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token);
begin
  if btrim(coalesce(p_key, '')) = '' then raise exception 'bad_key'; end if;
  if a.role = 'gamemaster' then
    insert into public.athlete_sports (key, sport, set_by) values (p_key, p_sport, a.id)
    on conflict (key) do update set sport = excluded.sport, set_by = excluded.set_by, updated_at = now();
  else
    insert into public.athlete_sports (key, sport, set_by) values (p_key, p_sport, a.id) on conflict (key) do nothing;
  end if;
end $$;

-- Rapprochement de noms appliqué partout (pronos et athlètes publiés). Uniquement après la clôture :
-- ainsi, personne (gamemasters compris) ne voit les pronos des autres avant.
create or replace function public.gm_apply_spelling(p_token text, p_season int, p_variants text[], p_spelling text, p_rules jsonb default '[]'::jsonb)
returns int language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token); v_norms text[]; v_n int := 0; r jsonb; v_spell text := btrim(coalesce(p_spelling, ''));
begin
  if a.role <> 'gamemaster' then raise exception 'forbidden'; end if;
  if not public._is_closed(p_season) then raise exception 'not_closed'; end if;
  if v_spell = '' then raise exception 'bad_spelling'; end if;
  select array_agg(distinct public.norm_name(x)) into v_norms from unnest(p_variants) x;
  delete from public.picks p using public.picks q
   where p.season = p_season and q.season = p_season and p.user_id = q.user_id and p.classement = q.classement
     and p.pos > q.pos and public.norm_name(p.name) = any(v_norms) and public.norm_name(q.name) = any(v_norms);
  update public.picks set name = v_spell where season = p_season and public.norm_name(name) = any(v_norms) and name <> v_spell;
  get diagnostics v_n = row_count;
  update public.reveals set name = v_spell where season = p_season and public.norm_name(name) = any(v_norms) and name <> v_spell;
  for r in select * from jsonb_array_elements(coalesce(p_rules, '[]'::jsonb)) loop
    insert into public.name_rules (season, kind, k, v) values (p_season, r ->> 'kind', r ->> 'k', coalesce(r ->> 'v', ''))
    on conflict (season, kind, k) do update set v = excluded.v;
  end loop;
  return v_n;
end $$;

create or replace function public.gm_set_rules(p_token text, p_season int, p_rules jsonb)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token); r jsonb;
begin
  if a.role <> 'gamemaster' then raise exception 'forbidden'; end if;
  if not public._is_closed(p_season) then raise exception 'not_closed'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rules, '[]'::jsonb)) loop
    insert into public.name_rules (season, kind, k, v) values (p_season, r ->> 'kind', r ->> 'k', coalesce(r ->> 'v', ''))
    on conflict (season, kind, k) do update set v = excluded.v;
  end loop;
end $$;

create or replace function public.set_role(p_token text, p_user uuid, p_role text)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token);
begin
  if a.role <> 'gamemaster' then raise exception 'forbidden'; end if;
  if p_role not in ('member', 'gamemaster') then raise exception 'bad_role'; end if;
  update public.accounts set role = p_role where id = p_user;
  if not exists (select 1 from public.accounts where role = 'gamemaster') then raise exception 'last_gamemaster'; end if;
end $$;

create or replace function public.admin_reset_password(p_token text, p_user uuid, p_new text)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare a public.accounts := public._me(p_token);
begin
  if a.role <> 'gamemaster' then raise exception 'forbidden'; end if;
  if char_length(coalesce(p_new, '')) < 6 then raise exception 'weak_password'; end if;
  update public.accounts set pass_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 8)), failed_attempts = 0, locked_until = null where id = p_user;
  if not found then raise exception 'unknown_user'; end if;
  delete from public.account_tokens where account_id = p_user;
end $$;

-- ---------------------------------------------------------------------
-- Droits d'exécution : seules ces fonctions sont appelables depuis l'application
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.server_info(), public.pseudo_available(text), public.register(text, text), public.login(text, text), public.logout(text),
  public.snapshot(text, int), public.change_code(text, text, text), public.delete_my_account(text),
  public.save_picks(text, int, text[], text[], boolean),
  public.create_league(text, int, text), public.join_league(text, text), public.leave_league(text, uuid),
  public.rename_league(text, uuid, text), public.remove_member(text, uuid, uuid), public.delete_league(text, uuid),
  public.set_reveal(text, int, text, int, text), public.set_sport(text, text, text),
  public.gm_apply_spelling(text, int, text[], text, jsonb), public.gm_set_rules(text, int, jsonb),
  public.set_role(text, uuid, text), public.admin_reset_password(text, uuid, text)
  to anon, authenticated;
grant execute on function public.norm_name(text) to anon, authenticated;
