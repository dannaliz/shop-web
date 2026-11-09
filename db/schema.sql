-- ============================================================
--  Maison Market — Supabase schema, security and policies
--  Run this in Supabase → SQL Editor (New query) and press RUN.
--  Then run db/seed.sql the same way to load the 80 products.
--  This file is safe to run again: it only adds what is missing.
-- ============================================================
--
--  HOW THE SIGN-UP WIZARD IS ENFORCED
--  The browser shows a 5-step wizard, but the browser can be
--  tampered with (inspect / console). So every step is checked
--  HERE, on the server:
--    1. Riddle             → start_registration() / answer_riddle()
--    2. Captcha            → new_captcha() / verify_captcha()
--    3. Survey             → save_survey()
--       (steps 1–3 are tracked in a registration ticket, before
--        the account exists)
--    4. Email, password, name, phone → Supabase Auth + claim_registration()
--    5. Terms accepted     → complete_registration()
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
  add column if not exists completed         boolean not null default false;

alter table public.profiles enable row level security;

-- Users may READ their own profile, but never write it directly:
-- all writes go through the step functions below.
drop policy if exists "own profile read"   on public.profiles;
drop policy if exists "own profile write"  on public.profiles;
drop policy if exists "own profile update" on public.profiles;
create policy "own profile read" on public.profiles for select to authenticated using (auth.uid() = id);
revoke insert, update, delete on public.profiles from anon, authenticated;

-- TRUE only when the signed-in user finished all 5 steps.
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
-- Steps 1–3 happen BEFORE the account exists, so their progress is
-- kept in a server-side "ticket" identified by a random token. The
-- browser only holds the token; riddle answers, the captcha answer
-- and the step flags never leave the server.

-- Old version of the wizard (account first) — remove it.
drop function if exists public.new_captcha();
drop function if exists public.verify_captcha(text);
drop function if exists public.save_survey(text, text, text);
drop function if exists public.save_details(text, text, text, text);
drop table if exists public.captchas;

create table if not exists public.riddles (
  id       int primary key,
  question text   not null,
  answers  text[] not null   -- normalized: lowercase, no accents, no "a/the"
);
alter table public.riddles enable row level security;
revoke all on public.riddles from anon, authenticated;

insert into public.riddles (id, question, answers) values
  (1, 'What has keys but can''t open a single lock?',                                        array['piano','keyboard']),
  (2, 'What has hands but can''t clap?',                                                      array['clock','watch','reloj']),
  (3, 'What gets wetter the more it dries?',                                                  array['towel','toalla']),
  (4, 'What has a neck but no head?',                                                         array['bottle','botella']),
  (5, 'What can you catch but not throw?',                                                    array['cold','resfriado','gripe','catarro']),
  (6, 'What has to be broken before you can use it?',                                         array['egg','huevo']),
  (7, 'I have cities but no houses, forests but no trees, and water but no fish. What am I?', array['map','mapa']),
  (8, 'What goes up but never comes down?',                                                   array['age','edad'])
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
  if not found then raise exception 'Your registration session expired. Please reload the page and start again.'; end if;
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
                            'captcha_ok', t.captcha_ok, 'survey_done', t.looking_for is not null);
end $$;

-- Swaps the riddle for a different one (only before it is solved).
create or replace function public.new_riddle(p_token uuid)
returns text language plpgsql volatile security definer set search_path = public as $$
declare t public.registration_tickets%rowtype; q text;
begin
  t := public._ticket(p_token);
  if t.riddle_ok then raise exception 'The riddle is already solved.'; end if;
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
  if not t.riddle_ok then raise exception 'Please solve the riddle first.'; end if;

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

-- STEP 3: survey. Returns up to 4 recommended products (no prices).
create or replace function public.save_survey(p_token uuid, p_looking_for text, p_budget text, p_profession text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  t      public.registration_tickets%rowtype;
  target numeric;
  res    jsonb;
begin
  t := public._ticket(p_token);
  if not t.captcha_ok then raise exception 'Please complete the verification step first.'; end if;
  if p_looking_for is null or p_looking_for not in ('clothing','objects','shoes','paintings','everything') then
    raise exception 'Please choose what you are looking for.';
  end if;
  target := case p_budget when 'under50' then 35 when '50to100' then 75 when '100to250' then 175 when 'over250' then 400 end;
  if target is null then raise exception 'Please choose your budget.'; end if;
  if length(trim(coalesce(p_profession, ''))) not between 2 and 60 then
    raise exception 'Please choose your profession.';
  end if;

  update public.registration_tickets
     set looking_for = p_looking_for, budget = p_budget, profession = trim(p_profession)
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

-- STEP 4: called right after the account is created (email + password).
-- Moves the ticket's progress onto the new user's profile.
create or replace function public.claim_registration(p_token uuid, p_name text, p_phone text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  t   public.registration_tickets%rowtype;
begin
  if uid is null then raise exception 'Please create your account first.'; end if;
  t := public._ticket(p_token);
  if not t.riddle_ok or not t.captcha_ok or t.looking_for is null then
    raise exception 'Please complete the previous steps first.';
  end if;
  if length(trim(coalesce(p_name, ''))) not between 2 and 80 then raise exception 'Please enter your full name.'; end if;
  if coalesce(trim(p_phone), '') !~ '^\+?[0-9 ()-]{7,20}$' then raise exception 'Please enter a valid phone number.'; end if;

  insert into public.profiles (id, name, phone, captcha_ok, looking_for, budget, profession)
  values (uid, trim(p_name), trim(p_phone), true, t.looking_for, t.budget, t.profession)
  on conflict (id) do update
    set name = excluded.name, phone = excluded.phone, captcha_ok = true,
        looking_for = excluded.looking_for, budget = excluded.budget, profession = excluded.profession;

  update public.registration_tickets set claimed_by = uid where token = p_token;
end $$;

-- STEP 5: accept the terms → account becomes fully registered.
create or replace function public.complete_registration(p_accept boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  r   public.profiles%rowtype;
begin
  select * into r from public.profiles where id = uid;
  if not found or not r.captcha_ok or r.looking_for is null or r.name is null or r.phone is null then
    raise exception 'Please complete the previous steps first.';
  end if;
  if p_accept is not true then raise exception 'You must accept the Terms and Conditions.'; end if;

  update public.profiles set terms_accepted_at = now(), completed = true where id = uid;
end $$;

-- Permissions: steps 1–3 can be done before having an account (anon);
-- steps 4–5 need a signed-in user. Internal helpers are not callable.
revoke all on function public._norm(text)                                  from public, anon, authenticated;
revoke all on function public._ticket(uuid)                                from public, anon, authenticated;
revoke all on function public.is_registered()                              from public, anon;
revoke all on function public.start_registration(uuid)                     from public;
revoke all on function public.new_riddle(uuid)                             from public;
revoke all on function public.answer_riddle(uuid, text)                    from public;
revoke all on function public.new_captcha(uuid)                            from public;
revoke all on function public.verify_captcha(uuid, text)                   from public;
revoke all on function public.save_survey(uuid, text, text, text)          from public;
revoke all on function public.claim_registration(uuid, text, text)         from public, anon;
revoke all on function public.complete_registration(boolean)               from public, anon;
grant execute on function public.is_registered()                           to authenticated;
grant execute on function public.start_registration(uuid)                  to anon, authenticated;
grant execute on function public.new_riddle(uuid)                          to anon, authenticated;
grant execute on function public.answer_riddle(uuid, text)                 to anon, authenticated;
grant execute on function public.new_captcha(uuid)                         to anon, authenticated;
grant execute on function public.verify_captcha(uuid, text)                to anon, authenticated;
grant execute on function public.save_survey(uuid, text, text, text)       to anon, authenticated;
grant execute on function public.claim_registration(uuid, text, text)      to authenticated;
grant execute on function public.complete_registration(boolean)            to authenticated;
