-- Caixa, comandas e lançamentos (rode uma vez no SQL Editor; só administradores acessam)
alter table staff add column comissao_pct numeric(5,2) not null default 0;
create table caixa_sessoes(id bigserial primary key, status text not null default 'aberto' check(status in('aberto','fechado')), fundo_inicial numeric(10,2) not null default 0,
  aberto_em timestamptz default now(), fechado_em timestamptz, valor_contado numeric(10,2), totais jsonb);
create unique index um_caixa_aberto on caixa_sessoes(status) where status='aberto';
create table comandas(id bigserial primary key, numero serial, caixa_id bigint not null references caixa_sessoes, user_id uuid references profiles, cliente_nome text not null default 'Avulso',
  staff_id bigint references staff, staff_nome text, itens jsonb not null default '[]', desconto numeric(10,2) not null default 0, total numeric(10,2) not null default 0,
  status text not null default 'aberta' check(status in('aberta','fechada','cancelada')), pagamentos jsonb not null default '[]', troco numeric(10,2) not null default 0,
  aberta_em timestamptz default now(), fechada_em timestamptz);
create table lancamentos(id bigserial primary key, tipo text not null check(tipo in('entrada','saida')), descricao text, categoria text, valor numeric(10,2) not null,
  metodo text, staff_id bigint references staff, data date not null default current_date);
alter table caixa_sessoes enable row level security; alter table comandas enable row level security; alter table lancamentos enable row level security;
create policy cx_adm on caixa_sessoes for all using(is_admin()) with check(is_admin());
create policy cm_adm on comandas for all using(is_admin()) with check(is_admin());
create policy lc_adm on lancamentos for all using(is_admin()) with check(is_admin());
create function fechar_comanda(p_id bigint, p_pags jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare c comandas; pago numeric; it jsonb; sub numeric:=0; ss numeric:=0; ps numeric:=0; sv numeric; pv numeric; maior text; tr numeric;
begin
  if not is_admin() then raise exception 'sem_permissao'; end if;
  select * into c from comandas where id=p_id and status='aberta' for update; if not found then raise exception 'comanda_invalida'; end if;
  select coalesce(sum((x->>'valor')::numeric),0) into pago from jsonb_array_elements(p_pags) x;
  if pago < c.total - 0.001 then raise exception 'pagamento_insuficiente'; end if;
  for it in select * from jsonb_array_elements(c.itens) loop
    sub:=sub+(it->>'preco')::numeric*(it->>'qtd')::int;
    if it->>'tipo'='servico' then ss:=ss+(it->>'preco')::numeric*(it->>'qtd')::int;
    else ps:=ps+(it->>'preco')::numeric*(it->>'qtd')::int;
      if it->>'product_id' is not null then update products set estoque=greatest(0,estoque-(it->>'qtd')::int) where id=(it->>'product_id')::bigint; end if; end if;
  end loop;
  sv:=case when ps>0 then round(case when sub>0 then ss*(c.total/sub) else 0 end,2) else c.total end; pv:=case when ps>0 then round(c.total-sv,2) else 0 end;
  select x->>'metodo' into maior from jsonb_array_elements(p_pags) x order by (x->>'valor')::numeric desc limit 1;
  tr:=greatest(0,round(pago-c.total,2));
  update comandas set status='fechada', pagamentos=p_pags, troco=tr, fechada_em=now() where id=p_id;
  if ss>0 then insert into lancamentos(tipo,descricao,categoria,valor,metodo,staff_id) values('entrada','Comanda '||c.numero||' - '||c.cliente_nome,'Serviço',sv,maior,c.staff_id); end if;
  if pv>0 then insert into lancamentos(tipo,descricao,categoria,valor,metodo,staff_id) values('entrada','Comanda '||c.numero||' - '||c.cliente_nome||' (produtos)','Produtos',pv,maior,c.staff_id); end if;
  return jsonb_build_object('troco',tr);
end$$;
