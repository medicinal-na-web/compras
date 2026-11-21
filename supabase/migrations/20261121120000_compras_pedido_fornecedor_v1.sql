-- Pedido por fornecedor: o comprador escolhe o fornecedor, o valor do pedido e a base de consumo
-- (90 ou 180 dias); o sistema distribui o valor entre os itens já comprados desse fornecedor.
--
-- Regra (decisão do Ricardo, 21/11/2026):
--  * Itens = todo produto com lote de entrada desse fornecedor nos últimos 3 anos (FC03140),
--    mesmo que o último lote tenha vindo de outro fornecedor.
--  * Desconta o estoque: compra primeiro quem tem menos dias de estoque. O valor sobe os itens
--    até todos os comprados ficarem com os mesmos dias de estoque (D); quem já tem mais que D fica de fora.
--      consumo/dia c = consumo da base ÷ dias da base
--      estoque s     = estoque F1 × peso + estoque F2 (mesmo critério do DiasConsumo (F1+F2))
--      dias atuais   = s ÷ c
--      quantidade    = c × (D − dias atuais), arredondada pelos passos do − / + do portal
--  * Preço = último preço de compra (PRCOMN; sem ele, PRCOM). Sem preço ou sem consumo: listado, sem quantidade.

-- ---------------------------------------------------------------- dados novos da carga

create table if not exists public.compras_consumo180 (
  cdpro           integer primary key,
  fisico_180d     numeric not null default 0,
  frequencia_180d numeric not null default 0,
  synced_at       timestamptz not null default now()
);
comment on table public.compras_consumo180 is
  'FIREBIRD - consumo de 180 dias por produto: fórmulas (FC12110) + ordens de produção (FC18100). sql/formula-certa/compras_consumo180.sql.';

create or replace function public.compras_carga_consumo180(p_linhas jsonb, p_carga timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  insert into public.compras_consumo180 (cdpro, fisico_180d, frequencia_180d, synced_at)
  select distinct on ("CDPRO") "CDPRO", coalesce("FISICO180D", 0), coalesce("FREQUENCIA180D", 0), p_carga
  from jsonb_to_recordset(p_linhas) as x("CDPRO" integer, "FISICO180D" numeric, "FREQUENCIA180D" numeric)
  where "CDPRO" is not null
  order by "CDPRO"
  on conflict (cdpro) do update set fisico_180d = excluded.fisico_180d, frequencia_180d = excluded.frequencia_180d,
    synced_at = excluded.synced_at;
  get diagnostics n = row_count;
  return n;
end $$;

create table if not exists public.compras_fornecedor_item (
  cdpro          integer not null,
  cdfnr          text not null,
  ultima_entrada date,
  lotes          integer not null default 0,
  synced_at      timestamptz not null default now(),
  primary key (cdpro, cdfnr)
);
create index if not exists compras_fornecedor_item_cdfnr on public.compras_fornecedor_item (cdfnr);
comment on table public.compras_fornecedor_item is
  'FIREBIRD - todo par produto × fornecedor com lote de entrada nos últimos 3 anos (FC03140, sem FORMULA PADRAO). sql/formula-certa/compras_fornecedor_item.sql.';

create or replace function public.compras_carga_fornecedor_item(p_linhas jsonb, p_carga timestamptz)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  insert into public.compras_fornecedor_item (cdpro, cdfnr, ultima_entrada, lotes, synced_at)
  select "CDPRO", f, max("ULTIMA"::date), sum(coalesce("LOTES", 0)), p_carga
  from jsonb_to_recordset(p_linhas) as x("CDPRO" integer, "CDFNR" text, "ULTIMA" text, "LOTES" integer),
       lateral (select trim("CDFNR") as f) k
  where "CDPRO" is not null and coalesce(f, '') <> ''
  group by "CDPRO", f
  on conflict (cdpro, cdfnr) do update set ultima_entrada = excluded.ultima_entrada, lotes = excluded.lotes,
    synced_at = excluded.synced_at;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.compras_carga_fechar(p_tabela text, p_carga timestamptz, p_total integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare tabela text; recebidas integer; apagadas integer := 0;
begin
  tabela := case p_tabela
    when 'produto' then 'compras_produto' when 'estoque' then 'compras_estoque'
    when 'consumo' then 'DataSet_Compras_12110_18100'
    when 'fornecedor' then 'compras_fornecedor' when 'produto_fornecedor' then 'compras_produto_fornecedor'
    when 'consumo180' then 'compras_consumo180' when 'fornecedor_item' then 'compras_fornecedor_item' end;
  if tabela is null then raise exception 'Tabela de carga desconhecida: %', p_tabela; end if;
  execute format('select count(*) from public.%I where synced_at = $1', tabela) into recebidas using p_carga;
  if recebidas <> p_total then
    return jsonb_build_object('tabela', tabela, 'ok', false, 'esperadas', p_total, 'recebidas', recebidas);
  end if;
  execute format('delete from public.%I where synced_at <> $1', tabela) using p_carga;
  get diagnostics apagadas = row_count;
  return jsonb_build_object('tabela', tabela, 'ok', true, 'recebidas', recebidas, 'apagadas', apagadas);
end $$;

-- ---------------------------------------------------------------- cálculo

-- passo do − / + do portal conforme a quantidade
create or replace function public.compras_passo(q numeric)
returns numeric language sql immutable as $$
  select case when q >= 25000 then 5000 when q >= 2500 then 500 when q >= 500 then 50 when q >= 50 then 10 else 1 end;
$$;

-- fornecedores com itens comprados nos últimos 3 anos, para a escolha na tela
create or replace function public.compras_fornecedores_com_itens()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.compras_exige(array['admin', 'comprador']);
  return coalesce((
    select jsonb_agg(jsonb_build_object('cnpj', x.cdfnr, 'nome', coalesce(f.fantasia, f.razao, x.cdfnr), 'itens', x.n, 'ultima', x.ultima)
                     order by coalesce(f.fantasia, f.razao, x.cdfnr))
    from (select cdfnr, count(*) n, max(ultima_entrada) ultima from public.compras_fornecedor_item group by cdfnr) x
    left join public.compras_fornecedor f on f.cnpj = x.cdfnr), '[]'::jsonb);
end $$;

create or replace function public.compras_pedido_fornecedor(p_cnpj text, p_valor numeric, p_base integer default 90)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_cnpj text := regexp_replace(coalesce(p_cnpj, ''), '\D', '', 'g'); r jsonb;
begin
  perform public.compras_exige(array['admin', 'comprador']);
  if p_base not in (90, 180) then raise exception 'Base de consumo deve ser 90 ou 180 dias' using errcode = '22023'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Informe o valor do pedido' using errcode = '22023'; end if;

  with par as (select * from public.compras_parametro where id),
  base as (
    select i.cdpro, p.descr, p.unida, p.grupo, p.situa, l.lista, pf.cdfnr = v_cnpj as habitual, i.ultima_entrada, i.lotes,
           coalesce(nullif(p.prcomn, 0), nullif(p.prcom, 0)) as preco,
           coalesce(e.estoque_filial1, 0) as e1, coalesce(e.estoque_filial2, 0) as e2,
           greatest(coalesce(e.estoque_filial1, 0) * par.peso_estoque_filial1 + coalesce(e.estoque_filial2, 0), 0) as s,
           case when p_base = 90 then coalesce(k."ConsolidadoFisico90D", 0) / 90.0
                else coalesce(k180.fisico_180d, 0) / 180.0 end as c
    from public.compras_fornecedor_item i
    cross join par
    join public.compras_produto p on p.cdpro = i.cdpro
    left join public.compras_estoque e on e.cdpro = i.cdpro
    left join public."DataSet_Compras_12110_18100" k on k."CDPRO" = i.cdpro
    left join public.compras_consumo180 k180 on k180.cdpro = i.cdpro
    left join public.compras_produto_fornecedor pf on pf.cdpro = i.cdpro
    left join public.compras_lista l on l.cdpro = i.cdpro
    where i.cdfnr = v_cnpj
  ),
  calc as (
    select b.*, case when b.c > 0 and b.preco > 0 then b.s / b.c end as cov,
                case when b.c > 0 and b.preco > 0 then b.preco * b.c end as a
    from base b
  ),
  -- D: nível de dias em que o gasto  Σ a·(D − cov)  dos itens abaixo de D  iguala o valor do pedido
  ordem as (
    select cov, a, row_number() over w as k, sum(a) over w as sa, sum(a * cov) over w as sac,
           lead(cov) over w as prox
    from calc where a > 0
    window w as (order by cov, cdpro)
  ),
  nivel as (
    select (p_valor + sac) / sa as d from ordem
    where prox is null or prox * sa - sac >= p_valor
    order by k limit 1
  ),
  item as (
    select calc.*, nivel.d,
           case when a > 0 and nivel.d > cov then
             greatest(round(c * (nivel.d - cov) / public.compras_passo(c * (nivel.d - cov))) * public.compras_passo(c * (nivel.d - cov)), 0)
           else 0 end as q
    from calc left join nivel on true
  )
  select jsonb_build_object(
    'cnpj', v_cnpj, 'fornecedor', (select coalesce(fantasia, razao, v_cnpj) from public.compras_fornecedor where cnpj = v_cnpj),
    'valor', p_valor, 'base', p_base, 'peso_f1', (select peso_estoque_filial1 from par),
    'dias_alvo', (select round(d, 1) from nivel),
    'total', coalesce(sum(round(q * coalesce(preco, 0), 2)), 0),
    'itens', coalesce(jsonb_agg(jsonb_build_object(
      'cdpro', cdpro, 'descr', descr, 'unida', unida, 'grupo', grupo, 'situa', situa, 'lista', lista,
      'habitual', habitual, 'ultima', ultima_entrada, 'lotes', lotes,
      'preco', preco, 'e1', e1, 'e2', e2, 'consumo_dia', round(c, 4), 'consumo_base', round(c * p_base, 2),
      'dias_atual', round(cov, 1), 'qtd', q, 'total', round(q * coalesce(preco, 0), 2),
      'dias_apos', case when c > 0 then round((s + q) / c, 1) end,
      'motivo', case when coalesce(preco, 0) <= 0 then 'sem preço' when c <= 0 then 'sem consumo'
                     when q = 0 then 'estoque acima do alvo' end)
      order by q * coalesce(preco, 0) desc, cov nulls last, descr), '[]'::jsonb))
  into r from item;
  return r;
end $$;

-- ---------------------------------------------------------------- permissões

alter table public.compras_consumo180      enable row level security;
alter table public.compras_fornecedor_item enable row level security;
revoke all on public.compras_consumo180, public.compras_fornecedor_item from anon, authenticated;

revoke all on function public.compras_carga_consumo180(jsonb, timestamptz), public.compras_carga_fornecedor_item(jsonb, timestamptz),
                       public.compras_carga_fechar(text, timestamptz, integer),
                       public.compras_fornecedores_com_itens(), public.compras_pedido_fornecedor(text, numeric, integer)
  from public, anon, authenticated;
grant execute on function public.compras_carga_consumo180(jsonb, timestamptz), public.compras_carga_fornecedor_item(jsonb, timestamptz),
                          public.compras_carga_fechar(text, timestamptz, integer)
  to service_role;
grant execute on function public.compras_fornecedores_com_itens(), public.compras_pedido_fornecedor(text, numeric, integer)
  to authenticated;
