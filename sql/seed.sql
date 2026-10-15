-- psql -v customers=N. Two accounts per customer, each opened with a deposit
-- posted against the bank's cash GL account (id 1) so the ledger balances from row one.

insert into core.accounts (customer_id, account_no) values (null, 'GL-CASH-0001');

insert into core.customers (nid, full_name)
select 'A' || lpad(g::text, 6, '0'), 'Customer ' || g
from generate_series(1, :customers) g;

insert into core.accounts (customer_id, account_no)
select c.id, '7701' || lpad(c.id::text, 9, '0') || s
from core.customers c cross join generate_series(1, 2) s
order by c.id, s;

with d as (
  select id, gen_random_uuid() as t, round((random() * 50000 + 100)::numeric, 2) as amt
  from core.accounts where id > 1
)
insert into core.ledger (transfer_id, account_id, amount)
select t, id, amt from d
union all
select t, 1, -amt from d;

update core.accounts a set balance = l.s
from (select account_id, sum(amount) s from core.ledger group by account_id) l
where l.account_id = a.id;
