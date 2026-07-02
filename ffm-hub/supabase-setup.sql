-- ==================================================================
-- RSA FFM Hub — SETUP TRỌN BỘ database Supabase (IDEMPOTENT)
-- CÁCH DÙNG: dán TOÀN BỘ file này vào Supabase -> SQL Editor -> Run.
-- Chạy được cho MỌI trường hợp (project mới hay đã có sẵn bảng) và
-- CHẠY LẠI NHIỀU LẦN vẫn an toàn — không làm mất dữ liệu đang có.
-- Không cần chọn "Phần 3/4/5" nữa: cứ chạy cả file này 1 lần là đủ.
-- ==================================================================

-- ============ PHẦN 1/3: schema gốc (bảng, view, RLS, trigger, nhật ký) ============
-- ============================================================
-- FFM Tool — Supabase / Postgres schema  (BẢN NHÁP để duyệt)
-- Phạm vi: Vận hành FFM. KHÔNG gồm doanh thu / lãi-lỗ sản phẩm.
--          Có sẵn field ffm_fee (nullable) để bật P&L của FFM sau.
-- Phân quyền: Role (LÀM cột nào) × 3 scope độc lập view/edit/delete (none/own/all).
-- Có nhật ký hoạt động (activity_log) ghi tự động ai thao tác gì.
-- ============================================================

create extension if not exists "pgcrypto";
-- Gợi ý: dùng pgsodium / Supabase Vault để mã hoá mật khẩu xưởng (factory_secrets).

-- ---------------------- ENUMS ----------------------
do $$ begin
  create type user_role as enum ('seller','ffm','admin');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type perm_scope_t as enum ('none','own','all');
exception when duplicate_object then null;
end $$;   -- phạm vi mỗi quyền: không / chỉ của mình / toàn bộ
do $$ begin
  create type platform_t as enum ('AMZ','TTS');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type shipped_by_t as enum ('tiktok_shipping','seller_shipping');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type currency_t as enum ('USD','VND');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type item_status as enum ('new','waiting_design','design_ok','ordered',
                                       'in_production','has_tracking','synced',
                                       'delivered','issue','cancelled');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type tracking_status_t as enum ('none','in_transit','delivered','returned');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type factory_status as enum ('active','evaluating','rejected');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type task_type as enum ('design_fix','follow_up','issue','other');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type task_status as enum ('open','in_progress','done');
exception when duplicate_object then null;
end $$;

-- ------------------ helper updated_at ------------------
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ---------------------- profiles ----------------------
-- Mở rộng auth.users của Supabase.
-- role       = LÀM gì (cột nào được sửa): seller cols / fulfillment / quản trị.
-- *_scope    = phân bổ ĐỘC LẬP theo từng nhân sự (Admin cấu hình).
--   Preset gợi ý:  seller thường  view=own  edit=own  delete=none
--                  trưởng nhóm    view=all  edit=own  delete=none
--                  FFM (Ngọc)     view=all  edit=all  delete=none
--                  admin/chủ      (mọi thứ = all, tự động)
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role user_role not null default 'seller',
  view_scope   perm_scope_t not null default 'own',      -- THẤY (SELECT)
  edit_scope   perm_scope_t not null default 'own',      -- SỬA  (UPDATE)
  delete_scope perm_scope_t not null default 'none',     -- XOÁ  (DELETE)
  telegram_chat_id text,                                 -- để bot Telegram nhắc việc
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------- factories ----------------------
-- Gồm cả xưởng đang dùng (active) và prospect từ "Tìm xưởng POD" (evaluating/rejected).
create table if not exists factories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  status factory_status not null default 'active',
  website text, login_url text,
  contact_group text,                    -- FB / Teams / Zalo / Telegram
  production_sla_days int, ship_sla_days int, tracking_time_note text,
  pricing_link text, order_guide_url text,
  default_currency currency_t not null default 'USD',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 1 xưởng nhiều email đăng nhập (vd Mangotee có 3 email).
create table if not exists factory_accounts (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references factories(id) on delete cascade,
  email text not null,
  note text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (factory_id, email)
);

-- Mật khẩu tách riêng, RLS chặt (chỉ ffm/admin). KHÔNG lưu plaintext.
create table if not exists factory_secrets (
  factory_account_id uuid primary key references factory_accounts(id) on delete cascade,
  password_enc text,
  updated_at timestamptz not null default now()
);

-- Tài khoản bán hàng trên sàn: TTS33, AMZ Vân Anh... (dropdown, chặn gõ sai).
create table if not exists selling_accounts (
  id uuid primary key default gen_random_uuid(),
  platform platform_t not null,
  name text not null,
  note text, active boolean not null default true,
  unique (platform, name)
);

-- ---------------------- templates ----------------------
-- Catalog mẫu. Chọn template -> auto-fill product_type/factory/dimension cho item.
create table if not exists templates (
  id uuid primary key default gen_random_uuid(),
  code text unique,                      -- '007'
  name text not null,                    -- '007_Merchize_Kid Satin Graduation Stole'
  factory_id uuid references factories(id),
  product_type text,
  dimension text,
  template_link text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------- orders ----------------------
-- 1 dòng = 1 đơn trên sàn. Chi tiết sản phẩm nằm ở order_items.
create table if not exists orders (
  id uuid primary key default gen_random_uuid(),
  platform platform_t not null,
  platform_order_id text not null,
  selling_account_id uuid references selling_accounts(id),
  seller_id uuid references profiles(id),          -- người phụ trách đơn
  order_date date,
  shipped_by shipped_by_t,
  label_link text,
  tracking_number text,                            -- mã vận đơn (Cotik/TikTok, cấp đơn/shipment)
  platform_status text,                            -- trạng thái sàn: AWAITING_SHIPMENT/IN_TRANSIT/DELIVERED/...
  work_status text,                                -- trạng thái xử lý nội bộ Cotik: New/Worked
  label_fee numeric(12,2) default 0,               -- USD
  ffm_fee numeric(12,2),                           -- (tuỳ chọn) phí FFM thu seller; để trống nếu chưa dùng
  customer_name text, customer_contact text, customer_address text,
  buyer_note text,                                 -- lời nhắn khách (Cotik: Buyer Note)
  delivery_instructions text,                      -- hướng dẫn giao (Cotik)
  seller_note text,
  archived_at timestamptz,                         -- soft delete
  created_by uuid references profiles(id),
  updated_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (platform, platform_order_id)             -- import upsert theo khoá này
);

-- ---------------------- order_items ----------------------
-- Pipeline fulfillment nằm ở đây (mỗi sản phẩm có factory_order_id + tracking riêng).
create table if not exists order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  template_id uuid references templates(id),
  -- SNAPSHOT auto-fill (chốt lúc tạo, không đổi khi sửa template):
  product_type text,
  factory_id uuid references factories(id),
  dimension text,
  -- Seller nhập:
  sku_phoi text, size text, color text, quantity int not null default 1,
  design_link text, confirm_design boolean not null default false,
  -- FFM cập nhật:
  factory_account_id uuid references factory_accounts(id),
  factory_order_id text,
  tracking_number text,
  tracking_status tracking_status_t not null default 'none',
  fulfillment_cost numeric(12,2),
  cost_currency currency_t not null default 'USD',
  item_status item_status not null default 'new',
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------- tài chính ----------------------
-- Nạp topup: THEO XƯỞNG (khớp file YCTT). account tuỳ chọn.
create table if not exists topups (
  id uuid primary key default gen_random_uuid(),
  paid_date date not null,
  amount numeric(14,2) not null,
  currency currency_t not null default 'USD',
  factory_id uuid not null references factories(id),
  factory_account_id uuid references factory_accounts(id),
  bank text,
  reason text default 'RS - Thanh toán topup',
  content_note text,
  month_label text,                                -- '5.2026'
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists refunds (
  id uuid primary key default gen_random_uuid(),
  sent_date date, received_date date,
  factory_id uuid references factories(id),
  amount numeric(14,2) not null,
  currency currency_t not null default 'USD',
  receive_account text, bank text, note text,
  created_at timestamptz not null default now()
);

-- Thanh toán khác (Pink Design...) — VND.
create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  paid_date date not null,
  amount numeric(14,2) not null,
  currency currency_t not null default 'VND',
  category text,                                   -- 'design'...
  supplier text, bank text, content_note text, month_label text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

-- ---------------------- tasks (giao việc + log sửa design) ----------------------
create table if not exists tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  type task_type not null default 'other',
  description text,
  assignee_id uuid references profiles(id),
  order_id uuid references orders(id) on delete set null,
  order_item_id uuid references order_items(id) on delete set null,
  status task_status not null default 'open',
  due_at timestamptz,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------- indexes ----------------------
create index if not exists idx_orders_seller_id on orders (seller_id);
create index if not exists idx_orders_order_date on orders (order_date);
create index if not exists idx_order_items_order_id on order_items (order_id);
create index if not exists idx_order_items_factory_id on order_items (factory_id);
create index if not exists idx_order_items_item_status on order_items (item_status);
create index if not exists idx_order_items_tracking_status on order_items (tracking_status);
create index if not exists idx_topups_factory_id on topups (factory_id);
create index if not exists idx_tasks_assignee_id_status on tasks (assignee_id, status);

-- ---------------------- triggers updated_at ----------------------
drop trigger if exists t_upd on profiles;
create trigger t_upd before update on profiles     for each row execute function set_updated_at();
drop trigger if exists t_upd on factories;
create trigger t_upd before update on factories    for each row execute function set_updated_at();
drop trigger if exists t_upd on templates;
create trigger t_upd before update on templates    for each row execute function set_updated_at();
drop trigger if exists t_upd on orders;
create trigger t_upd before update on orders       for each row execute function set_updated_at();
drop trigger if exists t_upd on order_items;
create trigger t_upd before update on order_items  for each row execute function set_updated_at();
drop trigger if exists t_upd on tasks;
create trigger t_upd before update on tasks        for each row execute function set_updated_at();

-- ---------------------- views ----------------------
-- Số dư từng xưởng (USD): đã nạp − đã tiêu + hoàn.
create or replace view v_factory_balance as
select f.id as factory_id, f.name,
  coalesce((select sum(t.amount)  from topups t       where t.factory_id=f.id  and t.currency='USD'),0)
  - coalesce((select sum(oi.fulfillment_cost) from order_items oi where oi.factory_id=f.id and oi.cost_currency='USD'),0)
  + coalesce((select sum(r.amount) from refunds r     where r.factory_id=f.id  and r.currency='USD'),0)
  as balance_usd
from factories f;

-- Trạng thái tổng của đơn = rollup từ các item.
create or replace view v_order_status as
select o.id as order_id,
  case
    when bool_or(oi.item_status='issue')          then 'issue'
    when bool_and(oi.item_status='cancelled')     then 'cancelled'
    when bool_and(oi.item_status='delivered')     then 'delivered'
    when bool_or(oi.item_status='synced')         then 'synced'
    when bool_or(oi.item_status='has_tracking')   then 'has_tracking'
    when bool_or(oi.item_status='in_production')  then 'in_production'
    when bool_or(oi.item_status='ordered')        then 'ordered'
    when bool_or(oi.item_status='design_ok')      then 'design_ok'
    when bool_or(oi.item_status='waiting_design') then 'waiting_design'
    else 'new'
  end as status
from orders o left join order_items oi on oi.order_id=o.id
group by o.id;

-- ============================================================
-- RLS (Row Level Security) — theo Role × scope (view/edit/delete)
-- ============================================================
create or replace function my_role() returns user_role language sql stable as $$
  select role from profiles where id = auth.uid()
$$;

-- Phạm vi hiệu lực của 1 quyền cho user hiện tại. Admin luôn 'all';
-- còn lại lấy đúng cột scope đã set => phân bổ theo từng nhân sự.
create or replace function my_scope(action text) returns perm_scope_t language sql stable as $$
  select case when p.role='admin' then 'all'::perm_scope_t
              else case action
                     when 'view'   then p.view_scope
                     when 'edit'   then p.edit_scope
                     when 'delete' then p.delete_scope
                   end
         end
  from profiles p where p.id = auth.uid()
$$;

-- 1 dòng đơn (theo seller_id) có nằm trong phạm vi quyền không.
create or replace function in_scope(action text, row_seller uuid) returns boolean language sql stable as $$
  select case my_scope(action)
           when 'all' then true
           when 'own' then row_seller = auth.uid()
           else false
         end
$$;

alter table profiles         enable row level security;
alter table factories        enable row level security;
alter table factory_accounts enable row level security;
alter table factory_secrets  enable row level security;
alter table selling_accounts enable row level security;
alter table templates        enable row level security;
alter table orders           enable row level security;
alter table order_items      enable row level security;
alter table topups           enable row level security;
alter table refunds          enable row level security;
alter table payments         enable row level security;
alter table tasks            enable row level security;

-- profiles: mình đọc mình; ai xem-toàn-bộ đọc hết; chỉ admin sửa (quản lý phân quyền).
drop policy if exists p_read on profiles;
create policy p_read on profiles for select using (id = auth.uid() or my_scope('view')='all');
drop policy if exists p_write on profiles;
create policy p_write on profiles for all    using (my_role()='admin') with check (my_role()='admin');

-- Reference data: đọc cho mọi user đã đăng nhập; ghi cho ffm/admin.
drop policy if exists ref_read on factories;
create policy ref_read on factories       for select using (auth.role()='authenticated');
drop policy if exists ref_write on factories;
create policy ref_write on factories       for all    using (my_role() in ('ffm','admin')) with check (my_role() in ('ffm','admin'));
drop policy if exists fa_read on factory_accounts;
create policy fa_read on factory_accounts for select using (auth.role()='authenticated');
drop policy if exists fa_write on factory_accounts;
create policy fa_write on factory_accounts for all   using (my_role() in ('ffm','admin')) with check (my_role() in ('ffm','admin'));
drop policy if exists sa_read on selling_accounts;
create policy sa_read on selling_accounts for select using (auth.role()='authenticated');
drop policy if exists sa_write on selling_accounts;
create policy sa_write on selling_accounts for all   using (my_role() in ('ffm','admin')) with check (my_role() in ('ffm','admin'));
drop policy if exists tm_read on templates;
create policy tm_read on templates        for select using (auth.role()='authenticated');
drop policy if exists tm_write on templates;
create policy tm_write on templates        for all   using (my_role() in ('ffm','admin')) with check (my_role() in ('ffm','admin'));

-- Secrets: chỉ ffm/admin.
drop policy if exists sec_rw on factory_secrets;
create policy sec_rw on factory_secrets for all using (my_role() in ('ffm','admin')) with check (my_role() in ('ffm','admin'));

-- orders: mỗi hành động theo scope riêng (none/own/all). INSERT theo role.
drop policy if exists o_read on orders;
create policy o_read on orders for select using (in_scope('view',   seller_id));
drop policy if exists o_ins on orders;
create policy o_ins on orders for insert with check (my_role() in ('seller','ffm','admin') and my_scope('edit') <> 'none');
drop policy if exists o_upd on orders;
create policy o_upd on orders for update using (in_scope('edit',   seller_id)) with check (in_scope('edit', seller_id));
drop policy if exists o_del on orders;
create policy o_del on orders for delete using (in_scope('delete', seller_id));

-- order_items: theo scope của ĐƠN CHA.
drop policy if exists oi_read on order_items;
create policy oi_read on order_items for select using (
  exists(select 1 from orders o where o.id=order_items.order_id and in_scope('view',   o.seller_id)));
drop policy if exists oi_ins on order_items;
create policy oi_ins on order_items for insert with check (
  exists(select 1 from orders o where o.id=order_items.order_id and in_scope('edit',   o.seller_id)));
drop policy if exists oi_upd on order_items;
create policy oi_upd on order_items for update using (
  exists(select 1 from orders o where o.id=order_items.order_id and in_scope('edit',   o.seller_id)));
drop policy if exists oi_del on order_items;
create policy oi_del on order_items for delete using (
  exists(select 1 from orders o where o.id=order_items.order_id and in_scope('delete', o.seller_id)));

-- Tài chính (topups/refunds/payments): ffm/admin.
drop policy if exists fin_topups on topups;
create policy fin_topups on topups   for all using (my_role() in ('ffm','admin')) with check (my_role() in ('ffm','admin'));
drop policy if exists fin_refunds on refunds;
create policy fin_refunds on refunds  for all using (my_role() in ('ffm','admin')) with check (my_role() in ('ffm','admin'));
drop policy if exists fin_payments on payments;
create policy fin_payments on payments for all using (my_role() in ('ffm','admin')) with check (my_role() in ('ffm','admin'));

-- tasks: người được giao / người tạo / ai xem-toàn-bộ đọc; ffm/admin ghi.
drop policy if exists tk_read on tasks;
create policy tk_read on tasks for select using (assignee_id = auth.uid() or created_by = auth.uid() or my_scope('view')='all');
drop policy if exists tk_write on tasks;
create policy tk_write on tasks for all    using (my_role() in ('ffm','admin')) with check (my_role() in ('ffm','admin'));

-- ---------------------- HARDENING: chặn seller sửa cột FFM ----------------------
-- RLS chỉ theo dòng, không theo cột. Trigger dưới chặn seller đổi cột do FFM sở hữu
-- (kể cả trưởng nhóm role=seller có edit_scope='all' cũng chỉ sửa được cột seller).
create or replace function guard_item_columns() returns trigger language plpgsql as $$
begin
  if my_role() = 'seller' then
    if new.factory_order_id   is distinct from old.factory_order_id
    or new.tracking_number    is distinct from old.tracking_number
    or new.tracking_status    is distinct from old.tracking_status
    or new.fulfillment_cost   is distinct from old.fulfillment_cost
    or new.factory_account_id is distinct from old.factory_account_id
    or new.item_status        is distinct from old.item_status then
      raise exception 'Seller không được sửa cột do FFM quản lý';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists t_guard_item on order_items;
create trigger t_guard_item before update on order_items for each row execute function guard_item_columns();

-- ============================================================
-- NHẬT KÝ HOẠT ĐỘNG (activity_log) — ai thao tác gì, khi nào
-- ============================================================
create table if not exists activity_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor uuid references profiles(id),
  action text not null,              -- INSERT / UPDATE / DELETE
  entity text not null,              -- tên bảng
  entity_id uuid,                    -- id dòng bị tác động
  changes jsonb                      -- INSERT/DELETE: cả dòng; UPDATE: {cột:{old,new}} chỉ cột đổi
);
create index if not exists idx_activity_log_at_desc on activity_log (at desc);
create index if not exists idx_activity_log_actor on activity_log (actor);
create index if not exists idx_activity_log_entity_entity_id on activity_log (entity, entity_id);

-- Ghi log tự động. SECURITY DEFINER để bỏ qua RLS khi chèn (client không tự chèn/sửa log).
create or replace function log_activity() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_changes jsonb;
begin
  if tg_op = 'DELETE' then
    v_id := old.id; v_changes := to_jsonb(old);
  elsif tg_op = 'INSERT' then
    v_id := new.id; v_changes := to_jsonb(new);
  else
    v_id := new.id;
    select jsonb_object_agg(n.key, jsonb_build_object('old', o.value, 'new', n.value))
      into v_changes
    from jsonb_each(to_jsonb(new)) n
    left join jsonb_each(to_jsonb(old)) o on o.key = n.key
    where n.value is distinct from o.value;
  end if;
  insert into activity_log(actor, action, entity, entity_id, changes)
  values (auth.uid(), tg_op, tg_table_name, v_id, v_changes);
  return coalesce(new, old);
end $$;

-- Gắn log cho các bảng nghiệp vụ chính (không log factory_secrets để tránh lộ mật khẩu).
drop trigger if exists log_orders on orders;
create trigger log_orders    after insert or update or delete on orders      for each row execute function log_activity();
drop trigger if exists log_items on order_items;
create trigger log_items     after insert or update or delete on order_items for each row execute function log_activity();
drop trigger if exists log_topups on topups;
create trigger log_topups    after insert or update or delete on topups      for each row execute function log_activity();
drop trigger if exists log_refunds on refunds;
create trigger log_refunds   after insert or update or delete on refunds     for each row execute function log_activity();
drop trigger if exists log_payments on payments;
create trigger log_payments  after insert or update or delete on payments    for each row execute function log_activity();
drop trigger if exists log_tasks on tasks;
create trigger log_tasks     after insert or update or delete on tasks       for each row execute function log_activity();
drop trigger if exists log_templates on templates;
create trigger log_templates after insert or update or delete on templates   for each row execute function log_activity();
drop trigger if exists log_factories on factories;
create trigger log_factories after insert or update or delete on factories   for each row execute function log_activity();
drop trigger if exists log_profiles on profiles;
create trigger log_profiles  after insert or update or delete on profiles    for each row execute function log_activity();

-- RLS: chỉ người xem-toàn-bộ (admin/ffm hoặc view_scope='all') đọc nhật ký. Không ai sửa/xoá (bất biến).
alter table activity_log enable row level security;
drop policy if exists log_read on activity_log;
create policy log_read on activity_log for select using (my_scope('view') = 'all');

-- ============================================================
-- Tự tạo profile khi có user mới đăng ký (nếu không sẽ bị RLS chặn hết).
-- Mặc định role='seller', view=own, edit=own, delete=none.
-- => Sau khi tạo user ĐẦU TIÊN, tự nâng lên admin:
--    update profiles set role='admin', view_scope='all', edit_scope='all', delete_scope='all'
--    where id = (select id from auth.users where email='ban@example.com');
-- ============================================================
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
          'seller')
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ============ PHẦN 2/3: cột phục vụ import Cotik/RSA ============
-- ============================================================
-- 0002 — Bổ sung cột phục vụ IMPORT (Cotik export + RSA-FFM Excel)
-- An toàn chạy lại (idempotent): dùng ADD COLUMN IF NOT EXISTS.
-- Không đổi cột cũ. Mục tiêu: giữ TRỌN dữ liệu 2 nguồn, không bắt seller sửa file.
-- ============================================================

-- ---- orders ----
-- order_value: GIÁ TRỊ đơn (Cotik cột `price`). Nullable, chỉ để tham khảo/đối chiếu
--   & ưu tiên đơn — KHÔNG dùng tính lãi-lỗ (ngoài scope FFM). Bỏ cột `est`.
alter table orders add column if not exists order_value numeric(12,2);

-- import_source: nguồn nạp dòng ('cotik' | 'rsa_ffm' | thủ công=null) để truy vết.
alter table orders add column if not exists import_source text;

-- seller_name_import: TÊN seller thô từ file (Tú/Hằng…) khi chưa map được profiles.id
--   (vd seed dữ liệu lúc chưa có user, hoặc import bởi FFM). Hiển thị tạm tới khi gán seller_id.
alter table orders add column if not exists seller_name_import text;

-- source_raw: lưu NGUYÊN dòng gốc (các cột non-empty) -> không mất dữ liệu khi migrate.
alter table orders add column if not exists source_raw jsonb;

-- ---- order_items ----
-- product_title : tên listing/sản phẩm (Cotik `title` / RSA phần listing) — schema gốc thiếu chỗ chứa.
alter table order_items add column if not exists product_title text;
-- template_code : mã Template thô từ RSA (vd '024_Onos_All-Over Print') để map templates.id sau.
alter table order_items add column if not exists template_code text;
-- skus_raw      : chuỗi SKU/phôi thô (Cotik `skus` trộn size+lời nhắn / RSA `Phôi`) — giữ bản gốc.
alter table order_items add column if not exists skus_raw text;
-- carrier       : đơn vị vận chuyển (RSA `Carrier`: USPS...).
alter table order_items add column if not exists carrier text;
-- shipping_cost : chi phí ship xưởng (RSA `Shipping Cost (USD)`). `fulfillment_cost` = Items Cost.
alter table order_items add column if not exists shipping_cost numeric(12,2);
-- source_line   : thứ tự dòng-item trong đơn (1..n) — khoá ổn định để re-import không nhân bản.
alter table order_items add column if not exists source_line int;
-- import_source / source_raw: như orders.
alter table order_items add column if not exists import_source text;
alter table order_items add column if not exists source_raw jsonb;

-- pushed_at    : ngày FFM đẩy đơn xuống xưởng (RSA `Ngày đẩy đơn`) — mốc trạng thái "đã gửi xưởng".
alter table order_items add column if not exists pushed_at date;
-- deadline_ship: hạn phải ship (RSA `Deadline Ship by - US time`) — phục vụ cảnh báo SLA sau.
alter table order_items add column if not exists deadline_ship date;
-- order_design_code / listing_link: mã & link thiết kế (RSA `Order Design`, `Listing Mockup/Link SP`).
alter table order_items add column if not exists order_design_code text;
alter table order_items add column if not exists listing_link text;

-- Khoá tự nhiên cho item (để upsert idempotent khi re-import cùng đơn):
--   (order_id, source_line). Item nhập tay không có source_line (null) nên không vướng.
create unique index if not exists uq_order_items_source_line
  on order_items (order_id, source_line)
  where source_line is not null;

-- ============================================================
-- PHÂN QUYỀN XEM: KHÔNG ép cứng. Mặc định least-privilege (seller view='own' — chỉ
-- thấy đơn của mình). ADMIN tự chọn cho từng người: ai được "xem tất cả" thì set
-- view_scope='all' (vd trưởng nhóm, seller đã tin tưởng); seller mới cứ để 'own'.
-- Cấu hình per-user ở trang Admin › Người dùng, hoặc bằng SQL:
--   update profiles set view_scope='all' where full_name = 'Tên seller';
-- (schema 0001 đã có sẵn 3 scope độc lập view/edit/delete cho mỗi profile.)
-- ============================================================

-- ============ PHẦN 3/3: đăng ký + SD phê duyệt + gán đơn seed ============
-- ============================================================
-- 0003 — Luồng ĐĂNG KÝ + SD PHÊ DUYỆT (giống rs-channel-hub / rsa-qltk)
-- Nhân sự tự đăng ký -> chờ duyệt -> Admin (SD) gán vai trò + phạm vi + seller_label
-- -> tự nhận lại toàn bộ đơn seed cũ theo tên (claim_seller_orders).
-- Idempotent: chạy lại an toàn.
-- ============================================================

alter table profiles add column if not exists approved boolean not null default false;
alter table profiles add column if not exists email text;
alter table profiles add column if not exists seller_label text;

-- User đã tạo TRƯỚC migration này (tạo tay trong Supabase) coi như đã duyệt
update profiles set approved = true where approved = false;

-- Backfill email từ auth.users
update profiles p set email = u.email
from auth.users u where u.id = p.id and p.email is null;

-- handle_new_user: ghi thêm email; user mới mặc định CHƯA duyệt
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, email, role, approved)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
          new.email,
          'seller',
          false)
  on conflict (id) do nothing;
  return new;
end $$;

-- is_approved(): user hiện tại đã được duyệt chưa
create or replace function is_approved() returns boolean language sql stable as $$
  select coalesce((select approved from profiles where id = auth.uid()), false)
$$;

-- my_scope: CHƯA duyệt => 'none' (khoá toàn bộ dữ liệu). Admin luôn 'all'.
create or replace function my_scope(action text) returns perm_scope_t language sql stable as $$
  select case
           when p.role = 'admin' then 'all'::perm_scope_t
           when not p.approved   then 'none'::perm_scope_t
           else case action
                  when 'view'   then p.view_scope
                  when 'edit'   then p.edit_scope
                  when 'delete' then p.delete_scope
                end
         end
  from profiles p where p.id = auth.uid()
$$;

-- Siết reference data: phải ĐÃ DUYỆT mới đọc
drop policy if exists ref_read on factories;
drop policy if exists ref_read on factories;
create policy ref_read on factories        for select using (is_approved());
drop policy if exists fa_read on factory_accounts;
drop policy if exists fa_read on factory_accounts;
create policy fa_read on factory_accounts for select using (is_approved());
drop policy if exists sa_read on selling_accounts;
drop policy if exists sa_read on selling_accounts;
create policy sa_read on selling_accounts for select using (is_approved());
drop policy if exists tm_read on templates;
drop policy if exists tm_read on templates;
create policy tm_read on templates        for select using (is_approved());

-- Gán đơn seed cũ cho user vừa duyệt, theo seller_label. Chỉ admin gọi.
create or replace function claim_seller_orders(p_user uuid, p_label text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if my_role() <> 'admin' then
    raise exception 'Chỉ admin được gán đơn cho seller';
  end if;
  update orders set seller_id = p_user
  where seller_name_import = p_label and seller_id is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ============ PHẦN 4/4: Giao việc + Care hộ (bổ sung) ============
-- ============================================================
-- 0004 — BỔ SUNG: Giao việc (tasks) + Care hộ (care_grants)
-- Idempotent: chạy lại an toàn. Chạy SAU 0001..0003.
-- ============================================================

-- ---- 4a. GIAO VIỆC: mọi user đã duyệt được tạo việc (seller giao design cho Media);
--          sửa bởi người tạo / người nhận / FFM / Admin.
drop policy if exists tk_write on tasks;
drop policy if exists tk_ins on tasks;
drop policy if exists tk_upd on tasks;
drop policy if exists tk_del on tasks;
drop policy if exists tk_ins on tasks;
create policy tk_ins on tasks for insert with check (is_approved());
drop policy if exists tk_upd on tasks;
create policy tk_upd on tasks for update
  using (created_by = auth.uid() or assignee_id = auth.uid() or my_role() in ('ffm','admin'));
drop policy if exists tk_del on tasks;
create policy tk_del on tasks for delete
  using (created_by = auth.uid() or my_role() in ('ffm','admin'));

-- ---- 4b. CARE HỘ (docx 6.4): tự nhận quyền SỬA TẠM 24h trên đơn đồng nghiệp.
--          Điều kiện: đã duyệt + nhìn thấy đơn. Ghi nhật ký. Cột FFM vẫn bị trigger chặn.
create table if not exists care_grants (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  grantee uuid not null references profiles(id),
  expires_at timestamptz not null default now() + interval '24 hours',
  created_at timestamptz not null default now()
);
alter table care_grants enable row level security;
drop policy if exists cg_read on care_grants;
drop policy if exists cg_ins on care_grants;
drop policy if exists cg_del on care_grants;
drop policy if exists cg_read on care_grants;
create policy cg_read on care_grants for select
  using (grantee = auth.uid() or my_scope('view') = 'all');
drop policy if exists cg_ins on care_grants;
create policy cg_ins on care_grants for insert with check (
  grantee = auth.uid() and is_approved()
  and exists(select 1 from orders o where o.id = order_id and in_scope('view', o.seller_id)));
drop policy if exists cg_del on care_grants;
create policy cg_del on care_grants for delete
  using (grantee = auth.uid() or my_role() = 'admin');

create or replace function has_care(row_order uuid) returns boolean language sql stable as $$
  select exists(select 1 from care_grants g
    where g.order_id = row_order and g.grantee = auth.uid() and g.expires_at > now())
$$;

-- Mở quyền UPDATE theo care grant (đơn + sản phẩm của đơn)
drop policy if exists o_upd on orders;
drop policy if exists o_upd on orders;
create policy o_upd on orders for update
  using (in_scope('edit', seller_id) or has_care(id))
  with check (in_scope('edit', seller_id) or has_care(id));
drop policy if exists oi_upd on order_items;
drop policy if exists oi_upd on order_items;
create policy oi_upd on order_items for update using (
  exists(select 1 from orders o where o.id = order_items.order_id
         and (in_scope('edit', o.seller_id) or has_care(o.id))));

-- Ghi nhật ký nhận/trả care
drop trigger if exists log_care on care_grants;
drop trigger if exists log_care on care_grants;
create trigger log_care after insert or delete on care_grants
  for each row execute function log_activity();

-- ============ PHẦN 5/5: VÁ LỖI RLS ĐỆ QUY — BẮT BUỘC CHẠY ============
-- Bug: my_role()/my_scope()/is_approved() đọc bảng profiles, mà policy của profiles
-- lại gọi chính các hàm này -> đệ quy vô hạn -> user đăng nhập xong MẤT TOÀN BỘ quyền.
-- Fix: SECURITY DEFINER (hàm bỏ qua RLS khi đọc profiles). GIỮ NGUYÊN luồng SD duyệt user.
create or replace function my_role() returns user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;
create or replace function is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select approved from profiles where id = auth.uid()), false)
$$;
create or replace function my_scope(action text) returns perm_scope_t
language sql stable security definer set search_path = public as $$
  select case
           when p.role = 'admin' then 'all'::perm_scope_t
           when not p.approved   then 'none'::perm_scope_t
           else case action
                  when 'view'   then p.view_scope
                  when 'edit'   then p.edit_scope
                  when 'delete' then p.delete_scope
                end
         end
  from profiles p where p.id = auth.uid()
$$;
create or replace function has_care(row_order uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from care_grants g
    where g.order_id = row_order and g.grantee = auth.uid() and g.expires_at > now())
$$;
