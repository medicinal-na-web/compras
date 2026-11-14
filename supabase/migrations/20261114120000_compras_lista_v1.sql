-- Lista de compras: replica o painel Power BI LISTADECOMPRAS.V7 (docs/powerbi-lista-de-compras.md).
--
-- Carga: n8n lê a réplica Firebird e chama compras_sync_produto / compras_sync_estoque /
-- compras_sync_consumo com o resultado das consultas de sql/formula-certa/ (chaves em
-- maiúsculas, como o Firebird devolve). Cada chamada substitui a tabela inteira.
-- Consumo usa a tabela "DataSet_Compras_12110_18100", criada em 21/07/2026.
--
-- Acesso: RLS deny-all; só service_role (n8n e, depois, o portal via funções).

-- ---------------------------------------------------------------- tabelas espelho

create table if not exists public.compras_produto (
  cdpro     integer primary key,
  descr     text,
  grupo     text,
  setor     text,
  situa     text,
  unida     text,
  prcom     numeric,
  prcomn    numeric,
  porta     text,
  synced_at timestamptz not null default now()
);
comment on table public.compras_produto is
  'FIREBIRD - espelho do FC03000 (só as colunas da lista de compras). Fonte de verdade: ERP. Sem dado pessoal.';

create table if not exists public.compras_estoque (
  cdpro           integer primary key,
  estoque_filial1 numeric not null default 0,
  estoque_filial2 numeric not null default 0,
  synced_at       timestamptz not null default now()
);
comment on table public.compras_estoque is
  'FIREBIRD - SUM(ESTAT) da FC03140 por produto nas filiais 1 e 2 (sql/formula-certa/dataset_compras_fc03140.sql).';

comment on table public."DataSet_Compras_12110_18100" is
  'FIREBIRD - consumo 30/90 dias por produto: FC12110 (fórmulas) + FC18100/FC18000 (produção, sufixo FP). Consolidado = soma das duas.';

-- ---------------------------------------------------------------- parâmetros

create table if not exists public.compras_parametro (
  id                     boolean primary key default true check (id),
  grupo                  text    not null default 'M',
  setor                  text    not null default '001',
  corte_curva_a          numeric not null default 0.80,
  corte_curva_b          numeric not null default 0.95,
  peso_estoque_filial1   numeric not null default 0.6,
  dias_cobertura_geral   numeric not null default 45,
  dias_cobertura_filial2 numeric not null default 30,
  dias_compra            numeric not null default 30,
  embalagens             numeric[] not null default
    '{1,5,10,25,50,100,250,500,1000,2500,5000,10000,25000,50000,100000,150000,300000}',
  atualizado_em          timestamptz not null default now(),
  atualizado_por         text
);
comment on table public.compras_parametro is
  'Parâmetros da lista de compras (linha única). dias_cobertura_filial2 = 30 é o ajuste de dez/2025; o valor original do painel era 45.';

insert into public.compras_parametro (id) values (true) on conflict do nothing;

create table if not exists public.compras_parametro_hist (
  id         bigint generated always as identity primary key,
  alterado_em timestamptz not null default now(),
  antes      jsonb,
  depois     jsonb not null
);
comment on table public.compras_parametro_hist is
  'Append-only: toda alteração de compras_parametro (antes/depois).';

create or replace function public.compras_parametro_hist_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.atualizado_em := now();
  insert into public.compras_parametro_hist (antes, depois)
  values (to_jsonb(old), to_jsonb(new));
  return new;
end $$;

drop trigger if exists compras_parametro_hist on public.compras_parametro;
create trigger compras_parametro_hist
  before update on public.compras_parametro
  for each row execute function public.compras_parametro_hist_trg();

-- ---------------------------------------------------------------- carga (n8n)

create or replace function public.compras_sync_produto(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from public.compras_produto where true;
  insert into public.compras_produto (cdpro, descr, grupo, setor, situa, unida, prcom, prcomn, porta)
  select "CDPRO", "DESCR", "GRUPO", "SETOR", "SITUA", "UNIDA", "PRCOM", "PRCOMN", "PORTA"
  from jsonb_to_recordset(p) as x("CDPRO" integer, "DESCR" text, "GRUPO" text, "SETOR" text,
                                  "SITUA" text, "UNIDA" text, "PRCOM" numeric, "PRCOMN" numeric, "PORTA" text)
  where "CDPRO" is not null;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.compras_sync_estoque(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from public.compras_estoque where true;
  insert into public.compras_estoque (cdpro, estoque_filial1, estoque_filial2)
  select "CDPRO", coalesce("ESTOQUEFILIAL1", 0), coalesce("ESTOQUEFILIAL2", 0)
  from jsonb_to_recordset(p) as x("CDPRO" integer, "ESTOQUEFILIAL1" numeric, "ESTOQUEFILIAL2" numeric)
  where "CDPRO" is not null;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.compras_sync_consumo(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from public."DataSet_Compras_12110_18100" where true;
  insert into public."DataSet_Compras_12110_18100" (
    "CDPRO",
    "SomaFrequencia30D", "SomaFisico30D", "SomaCusto30D",
    "SomaFrequencia90D", "SomaFisico90D", "SomaCusto90D",
    "SomaFrequencia30DFP", "SomaFisico30DFP", "SomaCusto30DFP",
    "SomaFrequencia90DFP", "SomaFisico90DFP", "SomaCusto90DFP",
    "ConsolidadoCusto30D", "ConsolidadoFrequencia30D", "ConsolidadoFisico30D",
    "ConsolidadoCusto90D", "ConsolidadoFrequencia90D", "ConsolidadoFisico90D",
    synced_at)
  select "CDPRO",
    coalesce("SOMAFREQUENCIA30D", 0), coalesce("SOMAFISICO30D", 0), coalesce("SOMACUSTO30D", 0),
    coalesce("SOMAFREQUENCIA90D", 0), coalesce("SOMAFISICO90D", 0), coalesce("SOMACUSTO90D", 0),
    coalesce("SOMAFREQUENCIA30DFP", 0), coalesce("SOMAFISICO30DFP", 0), coalesce("SOMACUSTO30DFP", 0),
    coalesce("SOMAFREQUENCIA90DFP", 0), coalesce("SOMAFISICO90DFP", 0), coalesce("SOMACUSTO90DFP", 0),
    coalesce("CONSOLIDADOCUSTO30D", 0), coalesce("CONSOLIDADOFREQUENCIA30D", 0), coalesce("CONSOLIDADOFISICO30D", 0),
    coalesce("CONSOLIDADOCUSTO90D", 0), coalesce("CONSOLIDADOFREQUENCIA90D", 0), coalesce("CONSOLIDADOFISICO90D", 0),
    now()
  from jsonb_to_recordset(p) as x("CDPRO" integer,
    "SOMAFREQUENCIA30D" numeric, "SOMAFISICO30D" numeric, "SOMACUSTO30D" numeric,
    "SOMAFREQUENCIA90D" numeric, "SOMAFISICO90D" numeric, "SOMACUSTO90D" numeric,
    "SOMAFREQUENCIA30DFP" numeric, "SOMAFISICO30DFP" numeric, "SOMACUSTO30DFP" numeric,
    "SOMAFREQUENCIA90DFP" numeric, "SOMAFISICO90DFP" numeric, "SOMACUSTO90DFP" numeric,
    "CONSOLIDADOCUSTO30D" numeric, "CONSOLIDADOFREQUENCIA30D" numeric, "CONSOLIDADOFISICO30D" numeric,
    "CONSOLIDADOCUSTO90D" numeric, "CONSOLIDADOFREQUENCIA90D" numeric, "CONSOLIDADOFISICO90D" numeric)
  where "CDPRO" is not null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- lista de compras
--
-- Regras do painel (docs/powerbi-lista-de-compras.md, seção 3). Onde o DAX compara
-- BLANK (divisão por zero), o BLANK vale 0 - daí os coalesce(..., 0) nas comparações.

create or replace view public.compras_lista with (security_invoker = true) as
with par as (
  select * from public.compras_parametro where id
),
base as (
  select p.cdpro, p.descr, p.situa, p.unida,
         coalesce(p.prcom, 0)  as prcom,
         coalesce(p.prcomn, 0) as prcomn,
         case when coalesce(trim(p.porta), '') = '' then 0 else 1 end as controlado,
         coalesce(e.estoque_filial1, 0) as estoque_filial1,
         coalesce(e.estoque_filial2, 0) as estoque_filial2,
         coalesce(c."ConsolidadoCusto90D", 0)      as custo_90d,
         coalesce(c."ConsolidadoFisico30D", 0)     as fisico_30d,
         coalesce(c."ConsolidadoFisico90D", 0)     as fisico_90d,
         coalesce(c."ConsolidadoFrequencia90D", 0)::numeric as frequencia_90d
  from public.compras_produto p
  cross join par
  left join public.compras_estoque e on e.cdpro = p.cdpro
  left join public."DataSet_Compras_12110_18100" c on c."CDPRO" = p.cdpro
  where p.grupo = par.grupo and p.setor = par.setor
),
participacao as (
  select b.*,
         coalesce(custo_90d      / nullif(sum(custo_90d)      over (), 0), 0) as part_financeiro,
         coalesce(fisico_90d     / nullif(sum(fisico_90d)     over (), 0), 0) as part_fisico,
         coalesce(frequencia_90d / nullif(sum(frequencia_90d) over (), 0), 0) as part_frequencia
  from base b
),
-- acumulado = soma das participações com rank <= o do produto (empates entram juntos, como no RANKX)
acumulado as (
  select pa.*,
         sum(part_financeiro) over (order by part_financeiro desc range between unbounded preceding and current row) as acum_financeiro,
         sum(part_fisico)     over (order by part_fisico     desc range between unbounded preceding and current row) as acum_fisico,
         sum(part_frequencia) over (order by part_frequencia desc range between unbounded preceding and current row) as acum_frequencia
  from participacao pa
),
curvas as (
  select a.*,
         case when acum_financeiro < par.corte_curva_a then 3 when acum_financeiro < par.corte_curva_b then 2 else 1 end as nota_financeiro,
         case when acum_fisico     < par.corte_curva_a then 3 when acum_fisico     < par.corte_curva_b then 2 else 1 end as nota_fisico,
         case when acum_frequencia < par.corte_curva_a then 3 when acum_frequencia < par.corte_curva_b then 2 else 1 end as nota_frequencia,
         (fisico_30d + fisico_90d) / 120.0 as media_consumo_diario
  from acumulado a cross join par
),
cobertura as (
  select c.*,
         nota_financeiro + nota_fisico + nota_frequencia as nota,
         (estoque_filial1 * par.peso_estoque_filial1 + estoque_filial2) / nullif(media_consumo_diario, 0) as dias_consumo_geral,
         estoque_filial2 / nullif(media_consumo_diario, 0) as dias_consumo_filial2
  from curvas c cross join par
),
indicacao as (
  select co.*,
         case
           when nota >= 8 then 1
           when nota >= 6 then 2
           when nota = 5  then 3
           when nota = 4  then 4
           else 5
         end as lista
  from cobertura co
),
decisao as (
  select i.*,
         case
           when lista = 5 then
             case when fisico_90d = 0 then false
                  else coalesce(dias_consumo_geral, 0) <= par.dias_cobertura_geral end
           when lista in (3, 4) then
             coalesce(dias_consumo_geral, 0) <= par.dias_cobertura_geral
           else -- listas 1 e 2
             coalesce(dias_consumo_filial2, 0) <= par.dias_cobertura_filial2
             and (controlado = 0 or coalesce(dias_consumo_geral, 0) < par.dias_cobertura_geral)
         end as comprar,
         -- = media_consumo_diario * dias_compra, sem a divisão intermediária (200/120*30 dava 50,0...01)
         (fisico_30d + fisico_90d) * par.dias_compra / 120.0 as necessidade
  from indicacao i cross join par
)
select d.cdpro, d.descr, d.situa, d.unida, d.controlado,
       d.estoque_filial1, d.estoque_filial2,
       d.fisico_30d, d.fisico_90d, d.custo_90d, d.frequencia_90d,
       d.prcom, d.prcomn,
       substr('CBA', d.nota_financeiro, 1) as curva_financeiro,
       substr('CBA', d.nota_fisico, 1)     as curva_fisico,
       substr('CBA', d.nota_frequencia, 1) as curva_frequencia,
       d.nota, d.lista,
       round(d.media_consumo_diario, 4) as media_consumo_diario,
       round(d.dias_consumo_geral, 1)   as dias_consumo_geral,
       round(d.dias_consumo_filial2, 1) as dias_consumo_filial2,
       d.comprar,
       coalesce(q.quantidade, 0)            as quantidade_compra,
       d.prcomn * coalesce(q.quantidade, 0) as total_compra
from decisao d
cross join par
left join lateral (
  select min(x) as quantidade
  from unnest(par.embalagens) x
  where d.comprar and d.necessidade > 0 and x >= d.necessidade
) q on true;

comment on view public.compras_lista is
  'Lista de compras por produto: curvas ABC (financeiro/físico/frequência 90d), lista 1-5, cobertura em dias, indicação e quantidade sugerida. Regras em docs/powerbi-lista-de-compras.md.';

-- ---------------------------------------------------------------- acesso

alter table public.compras_produto        enable row level security;
alter table public.compras_estoque        enable row level security;
alter table public.compras_parametro      enable row level security;
alter table public.compras_parametro_hist enable row level security;

revoke all on public.compras_produto, public.compras_estoque, public.compras_parametro,
              public.compras_parametro_hist, public.compras_lista
  from anon, authenticated;
revoke all on function public.compras_sync_produto(jsonb), public.compras_sync_estoque(jsonb),
                       public.compras_sync_consumo(jsonb), public.compras_parametro_hist_trg()
  from public, anon, authenticated;
grant execute on function public.compras_sync_produto(jsonb), public.compras_sync_estoque(jsonb),
                          public.compras_sync_consumo(jsonb)
  to service_role;
