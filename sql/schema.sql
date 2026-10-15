-- A small core-banking shape: customers, accounts, and an append-only double-entry ledger.
-- The ledger is the source of truth. accounts.balance is a derived, cached value,
-- which is exactly what makes the PITR drill's repair possible.

create schema core;

create table core.customers (
  id         bigint generated always as identity primary key,
  nid        text not null unique,
  full_name  text not null,
  created_at timestamptz not null default now()
);

create table core.accounts (
  id          bigint generated always as identity primary key,
  customer_id bigint references core.customers,
  account_no  text not null unique,
  currency    char(3) not null default 'MVR',
  balance     numeric(18,2) not null default 0,
  status      text not null default 'active' check (status in ('active', 'frozen', 'closed')),
  opened_at   timestamptz not null default now(),
  updated_at  timestamptz
);

-- Every transfer writes one debit and one credit, so the whole table nets to zero
-- and any account's balance can be rebuilt from its rows.
create table core.ledger (
  id          bigint generated always as identity primary key,
  transfer_id uuid not null,
  account_id  bigint not null references core.accounts,
  amount      numeric(18,2) not null check (amount <> 0),
  posted_at   timestamptz not null default clock_timestamp()
);
create index ledger_account_posted on core.ledger (account_id, posted_at);
create index ledger_transfer on core.ledger (transfer_id);

create function core.transfer(p_from bigint, p_to bigint, p_amount numeric)
returns uuid language plpgsql as $$
declare
  t uuid := gen_random_uuid();
begin
  if p_from = p_to or p_amount <= 0 then
    return null;
  end if;
  -- Lock both rows in id order so two opposite transfers can never deadlock each other.
  perform 1 from core.accounts where id in (p_from, p_to) order by id for update;
  update core.accounts set balance = balance - p_amount, updated_at = now() where id = p_from;
  update core.accounts set balance = balance + p_amount, updated_at = now() where id = p_to;
  insert into core.ledger (transfer_id, account_id, amount)
  values (t, p_from, -p_amount), (t, p_to, p_amount);
  return t;
end $$;

create function core.verify_integrity()
returns table (check_name text, ok boolean, detail text) language sql stable as $$
  select 'ledger nets to zero', coalesce(sum(amount), 0) = 0, 'sum ' || coalesce(sum(amount), 0)
  from core.ledger
  union all
  select 'balances match ledger', count(*) = 0, count(*) || ' accounts differ'
  from core.accounts a
  left join (select account_id, sum(amount) s from core.ledger group by account_id) l on l.account_id = a.id
  where a.balance <> coalesce(l.s, 0)
  union all
  select 'every transfer balanced', count(*) = 0, count(*) || ' unbalanced transfers'
  from (select transfer_id from core.ledger group by transfer_id having sum(amount) <> 0) x;
$$;
