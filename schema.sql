-- PETS BOUTIQUE · esquema próprio (rode no SQL Editor de um projeto Supabase NOVO)
create extension if not exists btree_gist;

create table profiles(id uuid primary key references auth.users on delete cascade, nome text, telefone text,
  role text not null default 'cliente' check(role in('cliente','admin')), criado_em timestamptz default now());
create function is_admin() returns boolean language sql stable security definer set search_path=public as
$$select exists(select 1 from profiles where id=auth.uid() and role='admin')$$;
create function novo_usuario() returns trigger language plpgsql security definer set search_path=public as
$$begin insert into profiles(id,nome) values(new.id,new.raw_user_meta_data->>'nome'); return new; end$$;
create trigger t_novo_usuario after insert on auth.users for each row execute function novo_usuario();

create table store_settings(id int primary key default 1 check(id=1), nome text default 'Pets Boutique',
  whatsapp text, endereco text, abre int, fecha int); -- abre/fecha em minutos (ex.: 540 = 09:00). PREENCHER pela loja.
insert into store_settings default values;

create table categories(id bigserial primary key, nome text not null, parent_id bigint references categories, imagem text, ativo bool default true, ordem int default 0);
create table products(id bigserial primary key, categoria_id bigint references categories, nome text not null, marca text, descricao text,
  sku text unique, preco numeric(10,2) not null check(preco>=0), preco_promo numeric(10,2) check(preco_promo>=0), estoque int not null default 0 check(estoque>=0),
  imagem text, ativo bool default true, destaque bool default false, exige_receita bool default false);
create table pets(id bigserial primary key, user_id uuid not null default auth.uid() references profiles, nome text not null, especie text not null, raca text, nascimento date, peso numeric, obs text);
create table services(id bigserial primary key, nome text not null, descricao text, preco numeric(10,2) not null, duracao_min int not null default 60, ativo bool default true);
create table appointments(id bigserial primary key, user_id uuid not null references profiles, pet_id bigint not null references pets, service_id bigint not null references services,
  data date not null, inicio int not null, fim int not null, preco numeric(10,2) not null, obs text, status text not null default 'agendado' check(status in('agendado','concluido','cancelado')),
  exclude using gist (data with =, int4range(inicio,fim) with &&) where (status<>'cancelado'));
create table orders(id bigserial primary key, user_id uuid not null references profiles, canal text not null check(canal in('app','whatsapp')),
  status text not null default 'aguardando_pagamento' check(status in('aguardando_pagamento','confirmado','separacao','enviado','concluido','cancelado')),
  total numeric(10,2) not null, entrega text, endereco text, criado_em timestamptz default now());
create table order_items(id bigserial primary key, order_id bigint not null references orders on delete cascade, product_id bigint references products, nome text, qtd int not null check(qtd>0), preco numeric(10,2) not null);

-- RLS
alter table profiles enable row level security; alter table store_settings enable row level security; alter table categories enable row level security;
alter table products enable row level security; alter table pets enable row level security; alter table services enable row level security;
alter table appointments enable row level security; alter table orders enable row level security; alter table order_items enable row level security;
create policy p_prof_ler on profiles for select using(id=auth.uid() or is_admin());
create policy p_prof_edit on profiles for update using(id=auth.uid()) with check(id=auth.uid() and role='cliente');
create policy p_set_ler on store_settings for select using(true); create policy p_set_adm on store_settings for all using(is_admin()) with check(is_admin());
create policy p_cat_ler on categories for select using(ativo or is_admin()); create policy p_cat_adm on categories for all using(is_admin()) with check(is_admin());
create policy p_prod_ler on products for select using(ativo or is_admin()); create policy p_prod_adm on products for all using(is_admin()) with check(is_admin());
create policy p_serv_ler on services for select using(ativo or is_admin()); create policy p_serv_adm on services for all using(is_admin()) with check(is_admin());
create policy p_pets on pets for all using(user_id=auth.uid() or is_admin()) with check(user_id=auth.uid());
create policy p_ag_ler on appointments for select using(user_id=auth.uid() or is_admin()); create policy p_ag_adm on appointments for update using(is_admin());
create policy p_ped_ler on orders for select using(user_id=auth.uid() or is_admin()); create policy p_ped_adm on orders for update using(is_admin());
create policy p_it_ler on order_items for select using(exists(select 1 from orders o where o.id=order_id and (o.user_id=auth.uid() or is_admin())));
-- clientes NÃO escrevem em orders, order_items nem appointments: só pelas funções abaixo (preço e estoque validados no servidor)

create function criar_pedido(itens jsonb, canal text, entrega text, endereco text) returns jsonb language plpgsql security definer set search_path=public as $$
declare it jsonb; p products; oid bigint; tot numeric:=0; q int;
begin
  if auth.uid() is null then raise exception 'login_necessario'; end if;
  if canal not in('app','whatsapp') then raise exception 'canal_invalido'; end if;
  insert into orders(user_id,canal,total,entrega,endereco) values(auth.uid(),canal,0,entrega,endereco) returning id into oid;
  for it in select * from jsonb_array_elements(itens) loop
    q:=(it->>'q')::int; if q is null or q<1 then raise exception 'quantidade_invalida'; end if;
    select * into p from products where id=(it->>'id')::bigint and ativo for update;
    if not found then raise exception 'produto_indisponivel'; end if;
    if p.exige_receita then raise exception 'exige_receita:%',p.nome; end if;
    if p.estoque<q then raise exception 'sem_estoque:%',p.nome; end if;
    update products set estoque=estoque-q where id=p.id;
    insert into order_items(order_id,product_id,nome,qtd,preco) values(oid,p.id,p.nome,q,coalesce(p.preco_promo,p.preco));
    tot:=tot+q*coalesce(p.preco_promo,p.preco);
  end loop;
  if tot<=0 then raise exception 'carrinho_vazio'; end if;
  update orders set total=tot where id=oid;
  return jsonb_build_object('id',oid,'total',tot);
end$$;

create function agendar(p_pet bigint, p_serv bigint, p_data date, p_inicio int, p_obs text) returns bigint language plpgsql security definer set search_path=public as $$
declare s services; id bigint; ab int; fe int;
begin
  if auth.uid() is null then raise exception 'login_necessario'; end if;
  if not exists(select 1 from pets where pets.id=p_pet and user_id=auth.uid()) then raise exception 'pet_invalido'; end if;
  select * into s from services where services.id=p_serv and ativo; if not found then raise exception 'servico_invalido'; end if;
  select abre,fecha into ab,fe from store_settings;
  if ab is null or p_inicio<ab or p_inicio+s.duracao_min>fe or p_data<current_date then raise exception 'horario_invalido'; end if;
  insert into appointments(user_id,pet_id,service_id,data,inicio,fim,preco,obs) values(auth.uid(),p_pet,p_serv,p_data,p_inicio,p_inicio+s.duracao_min,s.preco,p_obs) returning appointments.id into id;
  return id;
exception when exclusion_violation then raise exception 'horario_ocupado';
end$$;

create function ocupados(d date) returns table(inicio int, fim int) language sql stable security definer set search_path=public as
$$select inicio,fim from appointments where data=d and status<>'cancelado'$$;

create function cancelar_agendamento(p_id bigint) returns void language sql security definer set search_path=public as
$$update appointments set status='cancelado' where id=p_id and user_id=auth.uid() and status='agendado'$$;

-- Para virar administrador: update profiles set role='admin' where id='<uuid do dono>';
