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
--    1. Account (email + password)  → Supabase Auth
--    2. Captcha                     → new_captcha() / verify_captcha()
--    3. Survey                      → save_survey()
--    4. Name, phone, address        → save_details()
--    5. Terms accepted              → complete_registration()
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

-- 5) CAPTCHA --------------------------------------------------
-- The answer is stored only here. RLS is on with NO policies, so
-- nobody can read this table from the browser.
create table if not exists public.captchas (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  answer     text not null,
  attempts   int  not null default 0,
  expires_at timestamptz not null
);
alter table public.captchas enable row level security;
revoke all on public.captchas from anon, authenticated;

-- Returns an SVG image with 5 random digits. The digits are drawn
-- as distorted strokes (not text), so they cannot be read from the
-- page source; the answer never leaves the server.
create or replace function public.new_captcha()
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  uid    uuid := auth.uid();
  segs   text[] := array['abcdef','bc','abdeg','abcdg','bcfg','acdfg','acdefg','abc','abcdefg','abcdfg'];
  seg    jsonb := '{"a":[0,0,20,0],"b":[20,0,20,18],"c":[20,18,20,36],"d":[0,36,20,36],"e":[0,18,0,36],"f":[0,0,0,18],"g":[0,18,20,18]}';
  inks   text[] := array['#1f1b16','#8f3e20','#1a2a6c','#2e4d3a'];
  noise  text[] := array['#b5532f','#6d655b','#2e7d4f','#3a5bbf','#c9a227'];
  code   text := '';
  svg    text;
  dg int; s text; c jsonb; i int; j int;
  x1 numeric; y1 numeric; x2 numeric; y2 numeric;
begin
  if uid is null then raise exception 'Please sign in first.'; end if;

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

  insert into public.captchas (user_id, answer, attempts, expires_at)
  values (uid, code, 0, now() + interval '10 minutes')
  on conflict (user_id) do update set answer = excluded.answer, attempts = 0, expires_at = excluded.expires_at;

  return svg;
end $$;

-- Returns 'ok', 'wrong' or 'expired' (expired after 10 min or 5 wrong tries).
create or replace function public.verify_captcha(p_answer text)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  r   public.captchas%rowtype;
begin
  if uid is null then raise exception 'Please sign in first.'; end if;
  select * into r from public.captchas where user_id = uid for update;
  if not found or r.expires_at < now() or r.attempts >= 5 then
    delete from public.captchas where user_id = uid;
    return 'expired';
  end if;
  if trim(coalesce(p_answer, '')) = r.answer then
    delete from public.captchas where user_id = uid;
    insert into public.profiles (id, captcha_ok) values (uid, true)
    on conflict (id) do update set captcha_ok = true;
    return 'ok';
  end if;
  update public.captchas set attempts = attempts + 1 where user_id = uid;
  return 'wrong';
end $$;

-- 6) WIZARD STEPS ---------------------------------------------
-- Step 3: survey. Returns up to 4 recommended products (no prices).
create or replace function public.save_survey(p_looking_for text, p_budget text, p_profession text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  uid    uuid := auth.uid();
  target numeric;
  res    jsonb;
begin
  if not exists (select 1 from public.profiles where id = uid and captcha_ok) then
    raise exception 'Please complete the verification step first.';
  end if;
  if p_looking_for is null or p_looking_for not in ('clothing','objects','shoes','paintings','everything') then
    raise exception 'Please choose what you are looking for.';
  end if;
  target := case p_budget when 'under50' then 35 when '50to100' then 75 when '100to250' then 175 when 'over250' then 400 end;
  if target is null then raise exception 'Please choose your budget.'; end if;
  if length(trim(coalesce(p_profession, ''))) not between 2 and 60 then
    raise exception 'Please choose your profession.';
  end if;

  update public.profiles
     set looking_for = p_looking_for, budget = p_budget, profession = trim(p_profession)
   where id = uid;

  select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'icon', t.icon, 'bg', t.bg, 'category', t.category)), '[]'::jsonb)
    into res
    from (select p.name, p.icon, p.bg, p.category
            from public.products p
           where p_looking_for = 'everything' or p.category = p_looking_for
           order by abs(p.base_price - target), p.sort
           limit 4) t;
  return res;
end $$;

-- Step 4: personal details.
create or replace function public.save_details(p_name text, p_phone text, p_address text, p_zip text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if not exists (select 1 from public.profiles where id = uid and captcha_ok and looking_for is not null) then
    raise exception 'Please complete the previous steps first.';
  end if;
  if length(trim(coalesce(p_name, ''))) not between 2 and 80 then raise exception 'Please enter your full name.'; end if;
  if coalesce(trim(p_phone), '') !~ '^\+?[0-9 ()-]{7,20}$' then raise exception 'Please enter a valid phone number.'; end if;
  if length(trim(coalesce(p_address, ''))) not between 5 and 200 then raise exception 'Please enter your address.'; end if;
  if coalesce(trim(p_zip), '') !~ '^[A-Za-z0-9 -]{4,10}$' then raise exception 'Please enter a valid postal code.'; end if;

  update public.profiles
     set name = trim(p_name), phone = trim(p_phone), address = trim(p_address), zip = trim(p_zip)
   where id = uid;
end $$;

-- Step 5: accept the terms → account becomes fully registered.
create or replace function public.complete_registration(p_accept boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  r   public.profiles%rowtype;
begin
  select * into r from public.profiles where id = uid;
  if not found or not r.captcha_ok then raise exception 'Please complete the verification step first.'; end if;
  if r.looking_for is null then raise exception 'Please complete the survey first.'; end if;
  if r.name is null or r.phone is null or r.address is null or r.zip is null then
    raise exception 'Please enter your details first.';
  end if;
  if p_accept is not true then raise exception 'You must accept the Terms and Conditions.'; end if;

  update public.profiles set terms_accepted_at = now(), completed = true where id = uid;
end $$;

-- Only signed-in users may call these functions.
revoke all on function public.is_registered()                         from public, anon;
revoke all on function public.new_captcha()                           from public, anon;
revoke all on function public.verify_captcha(text)                    from public, anon;
revoke all on function public.save_survey(text, text, text)           from public, anon;
revoke all on function public.save_details(text, text, text, text)    from public, anon;
revoke all on function public.complete_registration(boolean)          from public, anon;
grant execute on function public.is_registered()                      to authenticated;
grant execute on function public.new_captcha()                        to authenticated;
grant execute on function public.verify_captcha(text)                 to authenticated;
grant execute on function public.save_survey(text, text, text)        to authenticated;
grant execute on function public.save_details(text, text, text, text) to authenticated;
grant execute on function public.complete_registration(boolean)       to authenticated;
