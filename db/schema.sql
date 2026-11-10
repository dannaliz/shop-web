-- ============================================================
--  Maison Market — Supabase schema, security and policies
--  Run this in Supabase → SQL Editor (New query) and press RUN.
--  Then run db/seed.sql the same way to load the 80 products.
--  This file is safe to run again: it only adds what is missing.
-- ============================================================
--
--  HOW THE SIGN-UP WIZARD IS ENFORCED
--  The browser shows an 8-step wizard (in isiZulu), but the browser
--  can be tampered with (inspect / console). So every step is
--  checked HERE, on the server:
--    1. Riddle               → start_registration() / answer_riddle()
--    2. Number captcha       → new_captcha() / verify_captcha()
--    3. Emoji picture game   → new_emoji_grid() / verify_emoji_grid()
--    4. Interests + age      → save_survey()
--       (steps 1–4 are tracked in a registration ticket, before
--        the account exists)
--    5. Name, email, password, terms → Supabase Auth + claim_registration()
--    6. Counting captcha + phone     → new_count_captcha() / save_phone()
--    7. Re-type the account email          → confirm_identity()
--    8. Short story + shipping address → complete_registration()
--  Each function refuses to run if the previous step is missing,
--  and users cannot write to their profile directly. Products,
--  prices, UI text and new orders are only available once
--  profiles.completed = true.
-- ============================================================

-- 1) PROFILES -------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text,
  city       text,
  zip        text,
  occupation text,
  created_at timestamptz default now()
);

alter table public.profiles
  add column if not exists address           text,
  add column if not exists phone             text,
  add column if not exists captcha_ok        boolean not null default false,
  add column if not exists looking_for       text,
  add column if not exists budget            text,
  add column if not exists profession        text,
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists completed         boolean not null default false,
  add column if not exists age               int,
  add column if not exists phone_saved_at    timestamptz,
  add column if not exists identity_ok_at    timestamptz,
  add column if not exists story             text;

alter table public.profiles enable row level security;

-- Users may READ their own profile, but never write it directly:
-- all writes go through the step functions below.
drop policy if exists "own profile read"   on public.profiles;
drop policy if exists "own profile write"  on public.profiles;
drop policy if exists "own profile update" on public.profiles;
create policy "own profile read" on public.profiles for select to authenticated using (auth.uid() = id);
revoke insert, update, delete on public.profiles from anon, authenticated;

-- TRUE only when the signed-in user finished all 8 steps.
create or replace function public.is_registered()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select completed from public.profiles where id = auth.uid()), false);
$$;

-- 2) PRODUCTS -------------------------------------------------
-- Prices live in this table on the server, NOT in the HTML.
create table if not exists public.products (
  id          bigint generated always as identity primary key,
  category    text    not null,
  name        text    not null,
  base_price  numeric not null,
  icon        text,
  bg          text,
  description text,
  on_sale     boolean not null default false,
  sort        int     not null default 0
);

alter table public.products enable row level security;

-- Only users who COMPLETED the sign-up wizard can read products.
drop policy if exists "products readable by authenticated" on public.products;
drop policy if exists "products readable by registered"    on public.products;
create policy "products readable by registered"
  on public.products for select to authenticated
  using (public.is_registered());

-- 3) ORDERS ---------------------------------------------------
create table if not exists public.orders (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  code       text not null,
  items      jsonb not null,
  total      numeric not null,
  method     text,
  address    text,
  status     text not null default 'Paid · Preparing shipment',
  reason     text,
  created_at timestamptz default now()
);

alter table public.orders enable row level security;

-- A user only sees THEIR OWN orders, and can only buy once registered.
drop policy if exists "own orders read"   on public.orders;
drop policy if exists "own orders insert" on public.orders;
drop policy if exists "own orders update" on public.orders;
create policy "own orders read"   on public.orders for select to authenticated using (auth.uid() = user_id);
create policy "own orders insert" on public.orders for insert to authenticated
  with check (auth.uid() = user_id and public.is_registered());
create policy "own orders update" on public.orders for update to authenticated using (auth.uid() = user_id);

-- 4) UI TEXT --------------------------------------------------
create table if not exists public.ui_text (
  key text primary key,
  val text not null
);

alter table public.ui_text enable row level security;

drop policy if exists "ui_text readable by authenticated" on public.ui_text;
drop policy if exists "ui_text readable by registered"    on public.ui_text;
create policy "ui_text readable by registered"
  on public.ui_text for select to authenticated
  using (public.is_registered());

-- 5) REGISTRATION TICKETS -------------------------------------
-- Steps 1–4 happen BEFORE the account exists, so their progress is
-- kept in a server-side "ticket" identified by a random token. The
-- browser only holds the token; riddle answers, captcha answers
-- and the step flags never leave the server.
-- Error messages are in isiZulu, like the wizard.

-- Older versions of the wizard — remove them (signatures changed).
drop function if exists public.new_captcha();
drop function if exists public.verify_captcha(text);
drop function if exists public.save_survey(text, text, text);
drop function if exists public.save_details(text, text, text, text);
drop function if exists public.save_survey(uuid, text, text, text);
drop function if exists public.claim_registration(uuid, text, text);
drop function if exists public.complete_registration(boolean);
drop table if exists public.captchas;

create table if not exists public.riddles (
  id       int primary key,
  question text   not null,
  answers  text[] not null   -- normalized: lowercase, no accents, no "a/the"
);
alter table public.riddles enable row level security;
revoke all on public.riddles from anon, authenticated;

-- Questions in isiZulu; answers accepted in isiZulu, English or Spanish.
insert into public.riddles (id, question, answers) values
  (1, 'Yini enokhiye abaningi kodwa engakwazi ukuvula ngisho ingidi elilodwa?',                                   array['piano','keyboard','upiyano','ipiyano','ikhibhodi','teclado']),
  (2, 'Yini enezandla kodwa engakwazi ukushaya ihlombe?',                                                        array['clock','watch','reloj','iwashi']),
  (3, 'Yini eya ngokuba manzi kakhulu lapho yomisa?',                                                            array['towel','toalla','ithawula','ithawuli']),
  (4, 'Yini enentamo kodwa engenalo ikhanda?',                                                                   array['bottle','botella','ibhodlela']),
  (5, 'Yini ongayibamba kodwa ungakwazi ukuyiphonsa?',                                                           array['cold','resfriado','gripe','catarro','umkhuhlane','imfiva']),
  (6, 'Yini okumele iphulwe ngaphambi kokuthi uyisebenzise?',                                                    array['egg','huevo','iqanda']),
  (7, 'Nginamadolobha kodwa anginazindlu, nginamahlathi kodwa anginazihlahla, nginamanzi kodwa anginazinhlanzi. Ngingubani?', array['map','mapa','ibalazwe','imephu']),
  (8, 'Yini ehlala ikhuphuka kodwa ingehli neze?',                                                               array['age','edad','iminyaka','ubudala'])
on conflict (id) do update set question = excluded.question, answers = excluded.answers;

-- "A Piano!" → "piano", "La Toalla" → "toalla", "Él reloj" → "reloj"
create or replace function public._norm(t text)
returns text language sql immutable as $$
  select trim(regexp_replace(
           regexp_replace(
             regexp_replace(translate(lower(trim(coalesce(t, ''))), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9 ]', '', 'g'),
             '\s+', ' ', 'g'),
           '^ ?(a|an|the|your|my|el|la|los|las|un|una|tu|mi) ', ''));
$$;

create table if not exists public.registration_tickets (
  token            uuid primary key default gen_random_uuid(),
  riddle_id        int references public.riddles(id),
  riddle_ok        boolean not null default false,
  riddle_attempts  int     not null default 0,
  captcha_answer   text,
  captcha_attempts int     not null default 0,
  captcha_expires  timestamptz,
  captcha_ok       boolean not null default false,
  looking_for      text,
  budget           text,
  profession       text,
  claimed_by       uuid references auth.users(id) on delete cascade,
  created_at       timestamptz not null default now()
);
alter table public.registration_tickets
  add column if not exists emoji_answer   int[],
  add column if not exists emoji_expires  timestamptz,
  add column if not exists emoji_attempts int     not null default 0,
  add column if not exists emoji_ok       boolean not null default false,
  add column if not exists age            int;
alter table public.registration_tickets enable row level security;
revoke all on public.registration_tickets from anon, authenticated;

-- Locks and returns a valid (unclaimed, < 1 day old) ticket, or fails.
create or replace function public._ticket(p_token uuid)
returns public.registration_tickets language plpgsql volatile security definer set search_path = public as $$
declare t public.registration_tickets%rowtype;
begin
  select * into t from public.registration_tickets
   where token = p_token and claimed_by is null and created_at > now() - interval '1 day'
   for update;
  if not found then raise exception 'Isikhathi sokubhalisa siphelile. Sicela uvuselele ikhasi bese uqala kabusha.'; end if;
  return t;
end $$;

-- Starts (or resumes) a registration. Returns the token, the riddle
-- question and which steps are already done.
create or replace function public.start_registration(p_token uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  t public.registration_tickets%rowtype;
  q text;
begin
  delete from public.registration_tickets where claimed_by is null and created_at < now() - interval '1 day';
  if p_token is not null then
    select * into t from public.registration_tickets where token = p_token and claimed_by is null;
  end if;
  if p_token is null or not found then
    insert into public.registration_tickets (riddle_id)
    values ((select id from public.riddles order by random() limit 1))
    returning * into t;
  end if;
  select question into q from public.riddles where id = t.riddle_id;
  return jsonb_build_object('token', t.token, 'question', q, 'riddle_ok', t.riddle_ok,
                            'captcha_ok', t.captcha_ok, 'emoji_ok', t.emoji_ok,
                            'survey_done', t.looking_for is not null and t.age is not null);
end $$;

-- Swaps the riddle for a different one (only before it is solved).
create or replace function public.new_riddle(p_token uuid)
returns text language plpgsql volatile security definer set search_path = public as $$
declare t public.registration_tickets%rowtype; q text;
begin
  t := public._ticket(p_token);
  if t.riddle_ok then raise exception 'Imfumbe isivele ixazululiwe.'; end if;
  select id, question into t.riddle_id, q from public.riddles where id <> coalesce(t.riddle_id, 0) order by random() limit 1;
  update public.registration_tickets set riddle_id = t.riddle_id, riddle_attempts = 0 where token = p_token;
  return q;
end $$;

-- STEP 1: riddle. Returns {status: ok | wrong | new, question?}.
-- After 3 wrong answers a different riddle is given.
create or replace function public.answer_riddle(p_token uuid, p_answer text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare t public.registration_tickets%rowtype;
begin
  t := public._ticket(p_token);
  if t.riddle_ok then return jsonb_build_object('status', 'ok'); end if;
  if exists (select 1 from public.riddles where id = t.riddle_id and public._norm(p_answer) = any(answers)) then
    update public.registration_tickets set riddle_ok = true where token = p_token;
    return jsonb_build_object('status', 'ok');
  end if;
  if t.riddle_attempts + 1 >= 3 then
    return jsonb_build_object('status', 'new', 'question', public.new_riddle(p_token));
  end if;
  update public.registration_tickets set riddle_attempts = riddle_attempts + 1 where token = p_token;
  return jsonb_build_object('status', 'wrong');
end $$;

-- STEP 2: captcha. Returns an SVG with 5 random digits drawn as
-- distorted strokes (not text), so they can't be read from the source.
create or replace function public.new_captcha(p_token uuid)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  t      public.registration_tickets%rowtype;
  segs   text[] := array['abcdef','bc','abdeg','abcdg','bcfg','acdfg','acdefg','abc','abcdefg','abcdfg'];
  seg    jsonb := '{"a":[0,0,20,0],"b":[20,0,20,18],"c":[20,18,20,36],"d":[0,36,20,36],"e":[0,18,0,36],"f":[0,0,0,18],"g":[0,18,20,18]}';
  inks   text[] := array['#1f1b16','#8f3e20','#1a2a6c','#2e4d3a'];
  noise  text[] := array['#b5532f','#6d655b','#2e7d4f','#3a5bbf','#c9a227'];
  code   text := '';
  svg    text;
  dg int; s text; c jsonb; i int; j int;
  x1 numeric; y1 numeric; x2 numeric; y2 numeric;
begin
  t := public._ticket(p_token);
  if not t.riddle_ok then raise exception 'Sicela uxazulule imfumbe kuqala.'; end if;

  svg := '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="70" viewBox="0 0 200 70"><rect width="200" height="70" fill="#f3ede4"/>';
  for i in 1..35 loop
    svg := svg || format('<circle cx="%s" cy="%s" r="%s" fill="%s" opacity=".55"/>',
      round((random()*200)::numeric), round((random()*70)::numeric),
      round((0.6 + random()*1.6)::numeric, 1), noise[1 + floor(random()*5)::int]);
  end loop;

  for i in 0..4 loop
    dg   := floor(random()*10)::int;
    code := code || dg::text;
    svg  := svg || format('<g transform="translate(%s %s) rotate(%s 10 18) skewX(%s)" stroke="%s" stroke-width="%s" stroke-linecap="round" fill="none">',
      18 + i*36 + round((random()*6 - 3)::numeric, 1), 15 + round((random()*8 - 4)::numeric, 1),
      round((random()*30 - 15)::numeric), round((random()*16 - 8)::numeric),
      inks[1 + floor(random()*4)::int], round((3 + random()*1.5)::numeric, 1));
    s := segs[dg + 1];
    for j in 1..length(s) loop
      c  := seg -> substr(s, j, 1);
      x1 := (c->>0)::numeric + round((random()*3 - 1.5)::numeric, 1);
      y1 := (c->>1)::numeric + round((random()*3 - 1.5)::numeric, 1);
      x2 := (c->>2)::numeric + round((random()*3 - 1.5)::numeric, 1);
      y2 := (c->>3)::numeric + round((random()*3 - 1.5)::numeric, 1);
      svg := svg || format('<path d="M%s %s Q%s %s %s %s"/>', x1, y1,
        round((x1 + x2)/2 + (random()*5 - 2.5)::numeric, 1), round((y1 + y2)/2 + (random()*5 - 2.5)::numeric, 1), x2, y2);
    end loop;
    svg := svg || '</g>';
  end loop;

  for i in 1..5 loop
    svg := svg || format('<path d="M%s %s Q%s %s %s %s" stroke="%s" stroke-width="1.4" fill="none" opacity=".7"/>',
      round((random()*20)::numeric), round((random()*70)::numeric),
      round((random()*200)::numeric), round((random()*70)::numeric),
      round((180 + random()*20)::numeric), round((random()*70)::numeric), noise[1 + floor(random()*5)::int]);
  end loop;
  svg := svg || '</svg>';

  update public.registration_tickets
     set captcha_answer = code, captcha_attempts = 0, captcha_expires = now() + interval '10 minutes'
   where token = p_token;
  return svg;
end $$;

-- Returns 'ok', 'wrong' or 'expired' (expired after 10 min or 5 wrong tries).
create or replace function public.verify_captcha(p_token uuid, p_answer text)
returns text language plpgsql volatile security definer set search_path = public as $$
declare t public.registration_tickets%rowtype;
begin
  t := public._ticket(p_token);
  if t.captcha_ok then return 'ok'; end if;
  if t.captcha_answer is null or t.captcha_expires < now() or t.captcha_attempts >= 5 then
    update public.registration_tickets set captcha_answer = null where token = p_token;
    return 'expired';
  end if;
  if trim(coalesce(p_answer, '')) = t.captcha_answer then
    update public.registration_tickets set captcha_ok = true, captcha_answer = null where token = p_token;
    return 'ok';
  end if;
  update public.registration_tickets set captcha_attempts = captcha_attempts + 1 where token = p_token;
  return 'wrong';
end $$;

-- STEP 3: emoji picture game. 9 pictures, 3–4 of them belong to the
-- requested group (fruits / animals / vehicles). The correct positions
-- stay on the server. Returns {prompt, items[9]}.
create or replace function public.new_emoji_grid(p_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  t       public.registration_tickets%rowtype;
  cats    text[] := array['fruit','animal','transport'];
  pool    jsonb := '{"fruit":["🍎","🍌","🍇","🍓","🍍","🍉","🍒","🍋","🥝","🍑"],
                     "animal":["🐘","🦒","🐄","🐕","🐈","🦁","🐒","🐑","🐓","🦓"],
                     "transport":["🚗","🚌","🚲","✈️","🚂","🚢","🏍️","🚁","🚕","🛵"]}';
  prompts jsonb := '{"fruit":"Chofoza zonke izithelo.","animal":"Chofoza zonke izilwane.","transport":"Chofoza zonke izinto zokuhamba."}';
  c       text;
  k       int;
  items   text[];
  ans     int[];
begin
  t := public._ticket(p_token);
  if not t.captcha_ok then raise exception 'Sicela uqedele ukuqinisekisa kuqala.'; end if;
  if t.emoji_ok then raise exception 'Lolu vivinyo selwenziwe.'; end if;

  c := cats[1 + floor(random()*3)::int];
  k := 3 + floor(random()*2)::int;
  with good as (select e, true as ok from jsonb_array_elements_text(pool -> c) e order by random() limit k),
       bad  as (select e, false as ok
                  from (select jsonb_array_elements_text(pool -> x) e from unnest(cats) x where x <> c) s
                 order by random() limit (9 - k)),
       allx as (select e, ok, (row_number() over (order by random()) - 1)::int as i
                  from (select * from good union all select * from bad) u)
  select array_agg(e order by i), array_agg(i order by i) filter (where ok)
    into items, ans from allx;

  update public.registration_tickets
     set emoji_answer = ans, emoji_attempts = 0, emoji_expires = now() + interval '10 minutes'
   where token = p_token;
  return jsonb_build_object('prompt', prompts ->> c, 'items', to_jsonb(items));
end $$;

-- Returns 'ok', 'wrong' or 'expired' (10 min / 3 wrong tries).
create or replace function public.verify_emoji_grid(p_token uuid, p_picks int[])
returns text language plpgsql volatile security definer set search_path = public as $$
declare t public.registration_tickets%rowtype;
begin
  t := public._ticket(p_token);
  if t.emoji_ok then return 'ok'; end if;
  if t.emoji_answer is null or t.emoji_expires < now() or t.emoji_attempts >= 3 then
    update public.registration_tickets set emoji_answer = null where token = p_token;
    return 'expired';
  end if;
  if (select array_agg(distinct x order by x) from unnest(coalesce(p_picks, '{}')) x) = t.emoji_answer then
    update public.registration_tickets set emoji_ok = true, emoji_answer = null where token = p_token;
    return 'ok';
  end if;
  update public.registration_tickets set emoji_attempts = emoji_attempts + 1 where token = p_token;
  return 'wrong';
end $$;

-- STEP 4: interests, budget and age. Returns up to 4 recommended products (no prices).
create or replace function public.save_survey(p_token uuid, p_looking_for text, p_budget text, p_age int)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  t      public.registration_tickets%rowtype;
  target numeric;
  res    jsonb;
begin
  t := public._ticket(p_token);
  if not t.emoji_ok then raise exception 'Sicela uqedele umdlalo wezithombe kuqala.'; end if;
  if p_looking_for is null or p_looking_for not in ('clothing','objects','shoes','paintings','everything') then
    raise exception 'Sicela ukhethe ukuthi ufunani.';
  end if;
  target := case p_budget when 'under50' then 35 when '50to100' then 75 when '100to250' then 175 when 'over250' then 400 end;
  if target is null then raise exception 'Sicela ukhethe isabelomali sakho.'; end if;
  if p_age is null or p_age not between 13 and 120 then
    raise exception 'Sicela ufake iminyaka yakho (13–120).';
  end if;

  update public.registration_tickets
     set looking_for = p_looking_for, budget = p_budget, age = p_age
   where token = p_token;

  select coalesce(jsonb_agg(jsonb_build_object('name', x.name, 'icon', x.icon, 'bg', x.bg, 'category', x.category)), '[]'::jsonb)
    into res
    from (select p.name, p.icon, p.bg, p.category
            from public.products p
           where p_looking_for = 'everything' or p.category = p_looking_for
           order by abs(p.base_price - target), p.sort
           limit 4) x;
  return res;
end $$;

-- STEP 5: called right after the account is created (name, email,
-- password, terms). Moves the ticket's progress onto the new profile.
-- Accounts from the older wizard (already have a profile) only need
-- the name and the terms.
create or replace function public.claim_registration(p_token uuid, p_name text, p_accept boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  t   public.registration_tickets%rowtype;
begin
  if uid is null then raise exception 'Sicela udale i-akhawunti yakho kuqala.'; end if;
  if length(trim(coalesce(p_name, ''))) not between 2 and 80 then raise exception 'Sicela ufake igama lakho eliphelele.'; end if;
  if p_accept is not true then raise exception 'Kumele wamukele Imigomo Nemibandela.'; end if;

  if exists (select 1 from public.profiles where id = uid and looking_for is not null) then
    update public.profiles set name = trim(p_name), terms_accepted_at = coalesce(terms_accepted_at, now()) where id = uid;
    return;
  end if;

  t := public._ticket(p_token);
  if not t.riddle_ok or not t.captcha_ok or not t.emoji_ok or t.looking_for is null or t.age is null then
    raise exception 'Sicela uqedele izinyathelo zangaphambili kuqala.';
  end if;

  insert into public.profiles (id, name, captcha_ok, looking_for, budget, age, terms_accepted_at)
  values (uid, trim(p_name), true, t.looking_for, t.budget, t.age, now())
  on conflict (id) do update
    set name = excluded.name, captcha_ok = true, looking_for = excluded.looking_for,
        budget = excluded.budget, age = excluded.age, terms_accepted_at = excluded.terms_accepted_at;

  update public.registration_tickets set claimed_by = uid where token = p_token;
end $$;

-- State of the step-6 counting captcha. Kept OUT of profiles because
-- users can read their own profile (that would leak the answer).
create table if not exists public.identity_checks (
  id             uuid primary key references auth.users(id) on delete cascade,
  count_answer   text,
  count_expires  timestamptz,
  count_attempts int     not null default 0,
  count_ok       boolean not null default false
);
alter table public.identity_checks enable row level security;
revoke all on public.identity_checks from anon, authenticated;

create or replace function public._claimed_profile()
returns public.profiles language plpgsql stable security definer set search_path = public as $$
declare r public.profiles%rowtype;
begin
  select * into r from public.profiles where id = auth.uid();
  if not found or r.looking_for is null or r.terms_accepted_at is null or r.name is null then
    raise exception 'Sicela uqedele izinyathelo zangaphambili kuqala.';
  end if;
  return r;
end $$;

-- STEP 6a: counting captcha. Small animals scattered in an image:
-- "how many of THIS one are there?". Returns {svg, prompt}.
create or replace function public.new_count_captcha()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  uid     uuid := auth.uid();
  r       public.profiles%rowtype;
  animals text[] := array['🐘','🦒','🦊','🐢','🐙','🦉','🐝','🐳','🐸','🦋'];
  target  text;
  n int; m int; i int; cx int; cy int;
  cells   int[];
  e       text;
  svg     text;
begin
  r := public._claimed_profile();
  target := animals[1 + floor(random()*10)::int];
  n := 3 + floor(random()*6)::int;     -- 3..8 of the target
  m := 6 + floor(random()*5)::int;     -- 6..10 others
  select array_agg(c) into cells from (select c from generate_series(0, 39) c order by random() limit n + m) s;

  svg := '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="150" viewBox="0 0 300 150"><rect width="300" height="150" fill="#f3ede4"/>';
  for i in 1..(n + m) loop
    if i <= n then e := target;
    else e := (select a from unnest(animals) a where a <> target order by random() limit 1);
    end if;
    cx := (cells[i] % 10) * 29 + 3 + floor(random()*6)::int;
    cy := (cells[i] / 10) * 35 + 28 + floor(random()*6)::int;
    svg := svg || format('<text x="%s" y="%s" font-size="%s" transform="rotate(%s %s %s)">%s</text>',
      cx, cy, 17 + floor(random()*7)::int, floor(random()*50 - 25)::int, cx + 10, cy - 8, e);
  end loop;
  svg := svg || '</svg>';

  insert into public.identity_checks (id, count_answer, count_expires, count_attempts)
  values (uid, n::text, now() + interval '10 minutes', 0)
  on conflict (id) do update
    set count_answer = excluded.count_answer, count_expires = excluded.count_expires, count_attempts = 0;

  return jsonb_build_object('svg', svg,
    'prompt', format('Bala izithombe ezincane ezifana nalesi: %s — zingaki?', target));
end $$;

-- STEP 6b: checks the counting captcha and saves the phone number.
-- Returns 'ok', 'wrong' or 'expired' (10 min / 5 wrong tries).
create or replace function public.save_phone(p_answer text, p_phone text)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  r   public.profiles%rowtype;
  c   public.identity_checks%rowtype;
begin
  r := public._claimed_profile();
  if coalesce(trim(p_phone), '') !~ '^\+?[0-9 ()-]{7,20}$' then
    raise exception 'Sicela ufake inombolo yocingo evumelekile.';
  end if;

  select * into c from public.identity_checks where id = uid for update;
  if not found or not c.count_ok then
    if not found or c.count_answer is null or c.count_expires < now() or c.count_attempts >= 5 then
      update public.identity_checks set count_answer = null where id = uid;
      return 'expired';
    end if;
    if trim(coalesce(p_answer, '')) <> c.count_answer then
      update public.identity_checks set count_attempts = count_attempts + 1 where id = uid;
      return 'wrong';
    end if;
    update public.identity_checks set count_ok = true, count_answer = null where id = uid;
  end if;

  update public.profiles
     set phone = trim(p_phone), phone_saved_at = now(), identity_ok_at = null
   where id = uid;
  return 'ok';
end $$;

-- STEP 7: same person check — the user types the account email again
-- and it must match the signed-in account's email.
-- (Earlier version took a phone number; the parameter name changed.)
drop function if exists public.confirm_identity(text);
create or replace function public.confirm_identity(p_email text)
returns void language plpgsql volatile security definer set search_path = public, auth as $$
declare
  r public.profiles%rowtype;
begin
  r := public._claimed_profile();
  if r.phone_saved_at is null then raise exception 'Sicela uqedele izinyathelo zangaphambili kuqala.'; end if;
  if lower(trim(coalesce(p_email, ''))) <> lower(coalesce((select email from auth.users where id = r.id), '')) then
    raise exception 'Le imeyili akuyona eye-akhawunti yakho.';
  end if;
  update public.profiles set identity_ok_at = now() where id = r.id;
end $$;

-- STEP 8: short story + shipping address → account fully registered.
-- The address only pre-fills the shipping form at checkout, where the
-- user sees it and can change it (a temporary address is fine).
create or replace function public.complete_registration(p_story text, p_address text, p_city text, p_zip text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  r public.profiles%rowtype;
begin
  r := public._claimed_profile();
  if r.phone is null or r.identity_ok_at is null then
    raise exception 'Sicela uqedele izinyathelo zangaphambili kuqala.';
  end if;
  if length(trim(coalesce(p_story, ''))) not between 150 and 3000 then
    raise exception 'Indaba kumele ibe nezinhlamvu eziphakathi kuka-150 no-3000.';
  end if;
  if length(trim(coalesce(p_address, ''))) not between 5 and 150 then raise exception 'Sicela ufake umgwaqo nenombolo.'; end if;
  if length(trim(coalesce(p_city, ''))) not between 2 and 80 then raise exception 'Sicela ufake idolobha.'; end if;
  if coalesce(trim(p_zip), '') !~ '^[A-Za-z0-9 -]{3,10}$' then raise exception 'Ikhodi yeposi ayivumelekile.'; end if;

  update public.profiles
     set story = trim(p_story), address = trim(p_address), city = trim(p_city), zip = trim(p_zip), completed = true
   where id = r.id;
end $$;

-- Permissions: steps 1–4 can be done before having an account (anon);
-- steps 5–8 need a signed-in user. Internal helpers are not callable.
revoke all on function public._norm(text)                                  from public, anon, authenticated;
revoke all on function public._ticket(uuid)                                from public, anon, authenticated;
revoke all on function public._claimed_profile()                           from public, anon, authenticated;
revoke all on function public.is_registered()                              from public, anon;
revoke all on function public.start_registration(uuid)                     from public;
revoke all on function public.new_riddle(uuid)                             from public;
revoke all on function public.answer_riddle(uuid, text)                    from public;
revoke all on function public.new_captcha(uuid)                            from public;
revoke all on function public.verify_captcha(uuid, text)                   from public;
revoke all on function public.new_emoji_grid(uuid)                         from public;
revoke all on function public.verify_emoji_grid(uuid, int[])               from public;
revoke all on function public.save_survey(uuid, text, text, int)           from public;
revoke all on function public.claim_registration(uuid, text, boolean)      from public, anon;
revoke all on function public.new_count_captcha()                          from public, anon;
revoke all on function public.save_phone(text, text)                       from public, anon;
revoke all on function public.confirm_identity(text)                       from public, anon;
revoke all on function public.complete_registration(text, text, text, text) from public, anon;
grant execute on function public.is_registered()                           to authenticated;
grant execute on function public.start_registration(uuid)                  to anon, authenticated;
grant execute on function public.new_riddle(uuid)                          to anon, authenticated;
grant execute on function public.answer_riddle(uuid, text)                 to anon, authenticated;
grant execute on function public.new_captcha(uuid)                         to anon, authenticated;
grant execute on function public.verify_captcha(uuid, text)                to anon, authenticated;
grant execute on function public.new_emoji_grid(uuid)                      to anon, authenticated;
grant execute on function public.verify_emoji_grid(uuid, int[])            to anon, authenticated;
grant execute on function public.save_survey(uuid, text, text, int)        to anon, authenticated;
grant execute on function public.claim_registration(uuid, text, boolean)   to authenticated;
grant execute on function public.new_count_captcha()                       to authenticated;
grant execute on function public.save_phone(text, text)                    to authenticated;
grant execute on function public.confirm_identity(text)                    to authenticated;
grant execute on function public.complete_registration(text, text, text, text) to authenticated;
