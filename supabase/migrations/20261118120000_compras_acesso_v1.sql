-- Perfis de acesso do Portal de Compras: administrador, comprador, produção e fornecedor.
--
--   admin      tudo; cadastra acessos; altera parâmetros
--   comprador  lista completa com valores; ajusta quantidades; só vê parâmetros
--   producao   lista sem preços nem valores; não ajusta
--   fornecedor só os itens do pedido ligados ao próprio CNPJ (código, descrição, unidade, quantidade)
--
-- Login: Supabase Auth por e-mail (código), como nos outros portais. O e-mail do login
-- precisa estar ativo em compras_acesso. O portal só fala com o banco pelas funções
-- compras_* abaixo; as tabelas continuam fechadas (RLS deny-all).

-- ---------------------------------------------------------------- acessos

create table if not exists public.compras_acesso (
  email      text primary key check (email = lower(email)),
  nome       text,
  papel      text not null check (papel in ('admin', 'comprador', 'producao', 'fornecedor')),
  cdfnr      text,   -- CNPJ do fornecedor (só números), obrigatório para papel fornecedor
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  criado_por text,
  check (papel <> 'fornecedor' or cdfnr ~ '^[0-9]{14}$')
);
comment on table public.compras_acesso is
  'Acesso ao Portal de Compras. Uma linha por e-mail. Fornecedor fica ligado ao CNPJ (cdfnr) e só vê o próprio pedido.';

create table if not exists public.compras_acesso_hist (
  id          bigint generated always as identity primary key,
  alterado_em timestamptz not null default now(),
  alterado_por text,
  antes       jsonb,
  depois      jsonb
);
comment on table public.compras_acesso_hist is 'Append-only: toda inclusão, alteração e remoção de acesso do Portal de Compras.';

-- ---------------------------------------------------------------- fornecedor por produto

create table if not exists public.compras_produto_fornecedor (
  cdpro     integer primary key,
  cdfnr     text not null,
  dtent     date,
  synced_at timestamptz not null default now()
);
comment on table public.compras_produto_fornecedor is
  'FIREBIRD - fornecedor (CNPJ) do lote de entrada mais recente de cada produto na FC03140 (sql/formula-certa/compras_produto_fornecedor.sql).';

create or replace function public.compras_sync_fornecedor(p jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from public.compras_produto_fornecedor where true;
  insert into public.compras_produto_fornecedor (cdpro, cdfnr, dtent)
  select distinct on ("CDPRO") "CDPRO", trim("CDFNR"), "DTENT"::date
  from jsonb_to_recordset(p) as x("CDPRO" integer, "CDFNR" text, "DTENT" text)
  where "CDPRO" is not null and coalesce(trim("CDFNR"), '') <> ''
  order by "CDPRO", "DTENT" desc nulls last, "CDFNR";
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- ajustes do pedido

create table if not exists public.compras_pedido_ajuste (
  cdpro        integer primary key,
  quantidade   numeric not null check (quantidade >= 0),
  ajustado_por text not null,
  ajustado_em  timestamptz not null default now()
);
comment on table public.compras_pedido_ajuste is
  'Quantidade do pedido alterada à mão pelo comprador. Sem linha = vale a sugestão de compras_lista.';

create table if not exists public.compras_pedido_ajuste_hist (
  id           bigint generated always as identity primary key,
  cdpro        integer not null,
  de           numeric,
  para         numeric,
  sugerido     numeric,
  ajustado_por text not null,
  ajustado_em  timestamptz not null default now()
);
comment on table public.compras_pedido_ajuste_hist is 'Append-only: todo ajuste e desfazer de quantidade do pedido.';

-- ---------------------------------------------------------------- quem é o usuário

create or replace function public.compras_meu_acesso()
returns public.compras_acesso language sql stable security definer set search_path = public as $$
  select a.* from public.compras_acesso a
  where a.email = lower(coalesce(auth.jwt() ->> 'email', '')) and a.ativo
$$;

create or replace function public.compras_exige(papeis text[])
returns public.compras_acesso language plpgsql stable security definer set search_path = public as $$
declare a public.compras_acesso;
begin
  a := public.compras_meu_acesso();
  if a.email is null then raise exception 'Sem acesso ao Portal de Compras' using errcode = '42501'; end if;
  if not a.papel = any (papeis) then raise exception 'Seu perfil (%) não permite esta ação', a.papel using errcode = '42501'; end if;
  return a;
end $$;

-- ---------------------------------------------------------------- leitura conforme o perfil

create or replace function public.compras_lista_portal()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.compras_acesso;
begin
  a := public.compras_exige(array['admin', 'comprador', 'producao', 'fornecedor']);

  if a.papel = 'fornecedor' then
    return coalesce((
      select jsonb_agg(jsonb_build_object('cdpro', l.cdpro, 'descr', l.descr, 'unida', l.unida,
                                          'quantidade', coalesce(aj.quantidade, l.quantidade_compra))
                       order by l.descr)
      from public.compras_lista l
      join public.compras_produto_fornecedor f on f.cdpro = l.cdpro and f.cdfnr = a.cdfnr
      left join public.compras_pedido_ajuste aj on aj.cdpro = l.cdpro
      where coalesce(aj.quantidade, l.quantidade_compra) > 0), '[]'::jsonb);
  end if;

  return coalesce((
    select jsonb_agg(
             case when a.papel = 'producao'
                  then to_jsonb(l) - 'prcom' - 'prcomn' - 'custo_90d' - 'total_compra'
                  else to_jsonb(l) || jsonb_build_object(
                         'cdfnr', f.cdfnr,
                         'total_pedido', l.prcomn * coalesce(aj.quantidade, l.quantidade_compra))
             end
             || jsonb_build_object('quantidade_pedido', coalesce(aj.quantidade, l.quantidade_compra),
                                   'ajustado', aj.cdpro is not null,
                                   'ajustado_por', aj.ajustado_por))
    from public.compras_lista l
    left join public.compras_produto_fornecedor f on f.cdpro = l.cdpro
    left join public.compras_pedido_ajuste aj on aj.cdpro = l.cdpro), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- escrita conforme o perfil

create or replace function public.compras_ajustar(p_cdpro integer, p_quantidade numeric)
returns void language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; sug numeric; ant numeric;
begin
  a := public.compras_exige(array['admin', 'comprador']);
  select quantidade_compra into sug from public.compras_lista where cdpro = p_cdpro;
  if not found then raise exception 'Produto % fora da lista de compras', p_cdpro; end if;
  select quantidade into ant from public.compras_pedido_ajuste where cdpro = p_cdpro;
  if p_quantidade is null or p_quantidade = sug then          -- voltar à sugestão
    delete from public.compras_pedido_ajuste where cdpro = p_cdpro;
  else
    insert into public.compras_pedido_ajuste (cdpro, quantidade, ajustado_por)
    values (p_cdpro, p_quantidade, a.email)
    on conflict (cdpro) do update set quantidade = excluded.quantidade,
      ajustado_por = excluded.ajustado_por, ajustado_em = now();
  end if;
  insert into public.compras_pedido_ajuste_hist (cdpro, de, para, sugerido, ajustado_por)
  values (p_cdpro, coalesce(ant, sug), coalesce(p_quantidade, sug), sug, a.email);
end $$;

create or replace function public.compras_salvar_parametros(p jsonb)
returns public.compras_parametro language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; r public.compras_parametro;
begin
  a := public.compras_exige(array['admin']);
  update public.compras_parametro set
    dias_cobertura_geral   = coalesce((p ->> 'dias_cobertura_geral')::numeric,   dias_cobertura_geral),
    dias_cobertura_filial2 = coalesce((p ->> 'dias_cobertura_filial2')::numeric, dias_cobertura_filial2),
    peso_estoque_filial1   = coalesce((p ->> 'peso_estoque_filial1')::numeric,   peso_estoque_filial1),
    dias_compra            = coalesce((p ->> 'dias_compra')::numeric,            dias_compra),
    corte_curva_a          = coalesce((p ->> 'corte_curva_a')::numeric,          corte_curva_a),
    corte_curva_b          = coalesce((p ->> 'corte_curva_b')::numeric,          corte_curva_b),
    atualizado_por         = a.email
  where id
  returning * into r;
  return r;
end $$;

create or replace function public.compras_salvar_acesso(p_email text, p_papel text, p_nome text default null,
                                                        p_cdfnr text default null, p_ativo boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; antes jsonb; e text := lower(trim(p_email));
begin
  a := public.compras_exige(array['admin']);
  select to_jsonb(x) into antes from public.compras_acesso x where x.email = e;
  insert into public.compras_acesso (email, nome, papel, cdfnr, ativo, criado_por)
  values (e, p_nome, p_papel, nullif(regexp_replace(coalesce(p_cdfnr, ''), '\D', '', 'g'), ''), p_ativo, a.email)
  on conflict (email) do update set nome = excluded.nome, papel = excluded.papel,
    cdfnr = excluded.cdfnr, ativo = excluded.ativo;
  insert into public.compras_acesso_hist (alterado_por, antes, depois)
  select a.email, antes, to_jsonb(x) from public.compras_acesso x where x.email = e;
end $$;

create or replace function public.compras_listar_acessos()
returns setof public.compras_acesso language plpgsql stable security definer set search_path = public as $$
begin
  perform public.compras_exige(array['admin']);
  return query select * from public.compras_acesso order by papel, email;
end $$;

-- ---------------------------------------------------------------- permissões

alter table public.compras_acesso             enable row level security;
alter table public.compras_acesso_hist        enable row level security;
alter table public.compras_produto_fornecedor enable row level security;
alter table public.compras_pedido_ajuste      enable row level security;
alter table public.compras_pedido_ajuste_hist enable row level security;

revoke all on public.compras_acesso, public.compras_acesso_hist, public.compras_produto_fornecedor,
              public.compras_pedido_ajuste, public.compras_pedido_ajuste_hist
  from anon, authenticated;

revoke all on function public.compras_sync_fornecedor(jsonb), public.compras_meu_acesso(),
                       public.compras_exige(text[]), public.compras_lista_portal(),
                       public.compras_ajustar(integer, numeric), public.compras_salvar_parametros(jsonb),
                       public.compras_salvar_acesso(text, text, text, text, boolean),
                       public.compras_listar_acessos()
  from public, anon;
grant execute on function public.compras_sync_fornecedor(jsonb) to service_role;
grant execute on function public.compras_meu_acesso(), public.compras_lista_portal(),
                          public.compras_ajustar(integer, numeric), public.compras_salvar_parametros(jsonb),
                          public.compras_salvar_acesso(text, text, text, text, boolean),
                          public.compras_listar_acessos()
  to authenticated;
revoke all on function public.compras_sync_fornecedor(jsonb), public.compras_exige(text[]) from authenticated;
