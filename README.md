# Maison Market

A demo store (clothing, objects, shoes, paintings) with a real backend on
[Supabase](https://supabase.com): login is required, prices live on the server
(not in the page source), and orders are saved to the database.

> Demo only — no real payments are processed.

## How it works

- **Logged out:** only the home page is visible. There are **no products or
  prices in the page source**, so they can't be read with "view source" /
  inspect.
- **Sign-up (8 steps, in isiZulu):** riddle → number captcha → emoji picture
  game → interests + age → name, email, password + terms (account is created)
  → counting captcha + phone → re-type the account email to confirm
  → short story about a magician + shipping address (only used to
  pre-fill checkout; a temporary one is fine). Every step is enforced by a
  Postgres function in `db/schema.sql`, so it can't be skipped from devtools.
  After changing `db/schema.sql`, run it again in the SQL Editor.
- **After signing up / logging in:** the browser fetches the catalog and prices
  from Supabase and renders the store.
- **Checkout:** orders are inserted into the `orders` table in Supabase and read
  back from there (not only from the browser). Cancel / refund updates the order
  status in the database.
- **Security:** Row Level Security (RLS) makes prices readable only by
  authenticated users, and each user can only see and change their own orders.
  The `anon` / publishable key in `config.js` is safe to publish because of this.

## Setup

1. Create a free project at https://supabase.com
2. **SQL Editor → New query** → paste all of `db/schema.sql` → **Run**.
3. **New query** → paste all of `db/seed.sql` → **Run** (loads the 80 products).
4. **Settings → API** (or the **Connect** button) → copy the **Project URL** and
   the **publishable / anon** key into `config.js`.
5. Open `index.html`.

### Note on email confirmation
By default Supabase asks new users to confirm their email. To let people sign up
and enter immediately, turn off email confirmation in **Authentication**.
Leaving it on is fine too — users just confirm their email once (normal for a
real store). To create a ready-to-use account for testing, use
**Authentication → Users → Add user** with **Auto Confirm User** checked.

## Files
- `index.html` — the whole store (UI + logic).
- `config.js` — your Supabase URL and publishable key.
- `db/schema.sql` — tables, Row Level Security and policies.
- `db/seed.sql` — the 80 products and their prices.
