-- ============================================================
--  Maison Market — Supabase schema, security and policies
--  Run this in Supabase → SQL Editor (New query) and press RUN.
--  Then run db/seed.sql the same way to load the 80 products.
-- ============================================================

-- 1) PRODUCTS -------------------------------------------------
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

-- Only LOGGED-IN users can read products (so prices are hidden
-- from anyone who is not signed in — including "view source").
drop policy if exists "products readable by authenticated" on public.products;
create policy "products readable by authenticated"
  on public.products for select
  to authenticated
  using (true);

-- 2) PROFILES -------------------------------------------------
-- Extra data from the sign-up form, one row per user.
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text,
  city       text,
  zip        text,
  occupation text,
  created_at timestamptz default now()
);

alter table public.profiles enable row level security;

drop policy if exists "own profile read"  on public.profiles;
drop policy if exists "own profile write" on public.profiles;
create policy "own profile read"  on public.profiles for select to authenticated using (auth.uid() = id);
create policy "own profile write" on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "own profile update" on public.profiles for update to authenticated using (auth.uid() = id);

-- 3) ORDERS ---------------------------------------------------
-- Orders are stored on the server, not only in the browser.
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

-- A user can only see and create THEIR OWN orders.
drop policy if exists "own orders read"   on public.orders;
drop policy if exists "own orders insert" on public.orders;
drop policy if exists "own orders update" on public.orders;
create policy "own orders read"   on public.orders for select to authenticated using (auth.uid() = user_id);
create policy "own orders insert" on public.orders for insert to authenticated with check (auth.uid() = user_id);
create policy "own orders update" on public.orders for update to authenticated using (auth.uid() = user_id);

-- 4) UI TEXT --------------------------------------------------
-- Interface strings (e.g. the "Are you sure?" dialog) live here on
-- the server instead of in index.html, so they do NOT appear in the
-- page source ("view source") for anyone who is not signed in.
create table if not exists public.ui_text (
  key text primary key,
  val text not null
);

alter table public.ui_text enable row level security;

-- Only LOGGED-IN users can read these strings.
drop policy if exists "ui_text readable by authenticated" on public.ui_text;
create policy "ui_text readable by authenticated"
  on public.ui_text for select
  to authenticated
  using (true);
