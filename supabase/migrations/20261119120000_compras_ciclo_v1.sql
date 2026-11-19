-- Ciclo de compras, cotação dos fornecedores e fila de e-mails do Portal de Compras.
--
-- Regras (definidas com o Ricardo, protótipo em portal/prototipo/):
--   * Um ciclo ativo por vez: em montagem ou aberto. Como o ciclo aberto ainda aceita itens,
--     o próximo só começa depois de travar o atual.
--   * O comprador aplica itens ao ciclo. Com o ciclo aberto, o item entra marcado como "após a
--     abertura" e o fornecedor habitual recebe aviso por e-mail.
--   * Tirar um item: em montagem ele só sai; com o ciclo aberto fica inativo (retirado), some da
--     cotação e o habitual e quem já cotou recebem aviso.
--   * Lançar abre a cotação e convida todo fornecedor com acesso liberado (habituais sem acesso
--     ficam registrados como sem destinatário). Travar congela as quantidades.
--   * Fornecedor: informa preço por unidade e quantidade mínima. Depois do primeiro preço só reduz.
--     Enquanto não reduz, vê se tem o menor preço; depois de reduzir, o resultado fica oculto.
--   * E-mails: entram na fila compras_email; o n8n envia (SMTP Medicinal) e marca o resultado.

-- ---------------------------------------------------------------- tabelas

create table if not exists public.compras_ciclo (
  id          integer generated always as identity primary key,
  status      text not null default 'montagem' check (status in ('montagem', 'aberto', 'travado')),
  criado_em   timestamptz not null default now(),
  criado_por  text not null,
  aberto_em   timestamptz,
  aberto_por  text,
  travado_em  timestamptz,
  travado_por text
);
comment on table public.compras_ciclo is 'Ciclos de compras. Só um ciclo ativo (montagem ou aberto) por vez.';
create unique index if not exists compras_ciclo_um_ativo on public.compras_ciclo ((true)) where status <> 'travado';

create table if not exists public.compras_ciclo_item (
  ciclo_id      integer not null references public.compras_ciclo (id),
  cdpro         integer not null,
  incluido_em   timestamptz not null default now(),
  incluido_por  text not null,
  apos_abertura boolean not null default false,
  retirado_em   timestamptz,
  retirado_por  text,
  qtd_travada   numeric,
  primary key (ciclo_id, cdpro)
);
comment on table public.compras_ciclo_item is 'Itens do ciclo. retirado_em preenchido = inativo (saiu com o ciclo aberto).';

create table if not exists public.compras_cotacao (
  ciclo_id      integer not null references public.compras_ciclo (id),
  cdpro         integer not null,
  cnpj          text not null,
  preco         numeric check (preco > 0),
  qtd_min       numeric check (qtd_min > 0),
  lances        integer not null default 0,
  cego          boolean not null default false,
  atualizado_em timestamptz not null default now(),
  atualizado_por text not null,
  primary key (ciclo_id, cdpro, cnpj)
);
comment on table public.compras_cotacao is 'Cotação do fornecedor (CNPJ) por item do ciclo. cego = já reduziu o preço e não vê mais quem ganha.';

create table if not exists public.compras_cotacao_hist (
  id        bigint generated always as identity primary key,
  ciclo_id  integer not null,
  cdpro     integer not null,
  cnpj      text not null,
  preco     numeric,
  qtd_min   numeric,
  feito_em  timestamptz not null default now(),
  feito_por text not null
);
comment on table public.compras_cotacao_hist is 'Append-only: todo preço e quantidade mínima informados pelos fornecedores.';

create table if not exists public.compras_email (
  id         bigint generated always as identity primary key,
  ciclo_id   integer not null references public.compras_ciclo (id),
  tipo       text not null check (tipo in ('convite', 'inclusao', 'retirada')),
  cnpj       text not null,
  para       text[] not null default '{}',
  assunto    text not null,
  corpo      text not null,
  itens      integer[] not null default '{}',
  criado_em  timestamptz not null default now(),
  status     text not null default 'pendente' check (status in ('pendente', 'enviado', 'sem_destinatario', 'erro')),
  enviado_em timestamptz,
  erro       text
);
comment on table public.compras_email is 'Fila de e-mails aos fornecedores. O n8n lê compras_email_fila() e grava compras_email_resultado().';

-- ---------------------------------------------------------------- apoio

-- quantidade do pedido de cada produto: ajuste do comprador ou sugestão da lista
create or replace function public.compras_qtd_pedido()
returns table (cdpro integer, quantidade numeric) language sql stable security definer set search_path = public as $$
  select l.cdpro, coalesce(aj.quantidade, l.quantidade_compra)
  from public.compras_lista l left join public.compras_pedido_ajuste aj on aj.cdpro = l.cdpro;
$$;

create or replace function public.compras_ciclo_ativo()
returns public.compras_ciclo language sql stable security definer set search_path = public as $$
  select * from public.compras_ciclo where status <> 'travado' limit 1;
$$;

-- enfileira um e-mail por fornecedor (CNPJ) para os e-mails com acesso liberado
create or replace function public.compras_enfileirar(p_ciclo integer, p_tipo text, p_cnpj text, p_itens integer[])
returns void language plpgsql security definer set search_path = public as $$
declare para text[]; nome text; lista text; n integer := coalesce(array_length(p_itens, 1), 0); assunto text; corpo text;
begin
  select coalesce(array_agg(email order by email), '{}') into para
  from public.compras_acesso where papel = 'fornecedor' and ativo and cdfnr = p_cnpj;
  select coalesce(fantasia, razao, p_cnpj) into nome from public.compras_fornecedor where cnpj = p_cnpj;
  select string_agg('- ' || coalesce(p.descr, i::text) || ' (' || i || ')', E'\n' order by p.descr) into lista
  from unnest(p_itens) i left join public.compras_produto p on p.cdpro = i;
  assunto := case p_tipo
    when 'convite'  then format('Medicinal: cotação do ciclo %s aberta', p_ciclo)
                         || case when n > 0 then format(' (%s %s que você costuma fornecer)', n, case when n = 1 then 'item' else 'itens' end) else '' end
    when 'inclusao' then format('Ciclo %s: %s à cotação da Medicinal', p_ciclo, case when n = 1 then 'item adicionado' else n || ' itens adicionados' end)
    else                 format('Ciclo %s: %s da cotação da Medicinal', p_ciclo, case when n = 1 then 'item retirado' else n || ' itens retirados' end) end;
  corpo := format(E'Olá, %s.\n\n', coalesce(nome, 'fornecedor'))
    || case p_tipo
         when 'convite'  then format(E'A cotação do ciclo %s de compras da Medicinal está aberta.\n', p_ciclo)
         when 'inclusao' then format(E'Incluímos na cotação do ciclo %s:\n', p_ciclo)
         else                 format(E'Retiramos da cotação do ciclo %s (não precisa mais cotar):\n', p_ciclo) end
    || case when lista is not null then case when p_tipo = 'convite' then E'Itens que você costuma fornecer:\n' else '' end || lista || E'\n' else '' end
    || E'\nAcesse o Portal de Compras para informar ou rever seus preços:\nhttps://www.medicinalnaweb.com.br/compras\n\nEquipe de Compras · Medicinal';
  insert into public.compras_email (ciclo_id, tipo, cnpj, para, assunto, corpo, itens, status)
  values (p_ciclo, p_tipo, p_cnpj, para, assunto, corpo, coalesce(p_itens, '{}'),
          case when cardinality(para) = 0 then 'sem_destinatario' else 'pendente' end);
end $$;

-- ---------------------------------------------------------------- comprador

create or replace function public.compras_ciclo_aplicar(p_cdpros integer[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; c public.compras_ciclo; novos integer[] := '{}'; r record;
begin
  a := public.compras_exige(array['admin', 'comprador']);
  c := public.compras_ciclo_ativo();
  if c.id is null then
    insert into public.compras_ciclo (criado_por) values (a.email) returning * into c;
  end if;
  with alvo as (
    select distinct x as cdpro from unnest(p_cdpros) x
    where exists (select 1 from public.compras_produto p where p.cdpro = x)
  ), gravados as (
    insert into public.compras_ciclo_item (ciclo_id, cdpro, incluido_por, apos_abertura)
    select c.id, alvo.cdpro, a.email, c.status = 'aberto' from alvo
    on conflict (ciclo_id, cdpro) do update
      set incluido_em = now(), incluido_por = excluded.incluido_por, apos_abertura = excluded.apos_abertura,
          retirado_em = null, retirado_por = null
      where compras_ciclo_item.retirado_em is not null      -- item ativo fica como está
    returning cdpro
  )
  select coalesce(array_agg(cdpro), '{}') into novos from gravados;
  if c.status = 'aberto' and cardinality(novos) > 0 then
    for r in select coalesce(pf.cdfnr, '') cnpj, array_agg(i order by i) itens
             from unnest(novos) i left join public.compras_produto_fornecedor pf on pf.cdpro = i
             group by 1 loop
      if r.cnpj <> '' then perform public.compras_enfileirar(c.id, 'inclusao', r.cnpj, r.itens); end if;
    end loop;
  end if;
  return jsonb_build_object('ciclo', c.id, 'status', c.status, 'incluidos', cardinality(novos));
end $$;

create or replace function public.compras_ciclo_retirar(p_cdpro integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; c public.compras_ciclo; cn text;
begin
  a := public.compras_exige(array['admin', 'comprador']);
  c := public.compras_ciclo_ativo();
  if c.id is null or not exists (select 1 from public.compras_ciclo_item
                                 where ciclo_id = c.id and cdpro = p_cdpro and retirado_em is null) then
    raise exception 'O item % não está no ciclo ativo', p_cdpro using errcode = '22023';
  end if;
  if c.status = 'montagem' then
    delete from public.compras_ciclo_item where ciclo_id = c.id and cdpro = p_cdpro;
  else
    update public.compras_ciclo_item set retirado_em = now(), retirado_por = a.email
    where ciclo_id = c.id and cdpro = p_cdpro;
    for cn in select pf.cdfnr from public.compras_produto_fornecedor pf where pf.cdpro = p_cdpro
              union select q.cnpj from public.compras_cotacao q where q.ciclo_id = c.id and q.cdpro = p_cdpro and q.preco is not null loop
      perform public.compras_enfileirar(c.id, 'retirada', cn, array[p_cdpro]);
    end loop;
  end if;
  return jsonb_build_object('ciclo', c.id, 'status', c.status, 'cdpro', p_cdpro);
end $$;

create or replace function public.compras_ciclo_lancar(p_ciclo integer)
returns void language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; r record;
begin
  a := public.compras_exige(array['admin', 'comprador']);
  update public.compras_ciclo set status = 'aberto', aberto_em = now(), aberto_por = a.email
  where id = p_ciclo and status = 'montagem';
  if not found then raise exception 'O ciclo % não está em montagem', p_ciclo using errcode = '22023'; end if;
  for r in
    with habituais as (
      select pf.cdfnr cnpj, array_agg(i.cdpro order by i.cdpro) itens
      from public.compras_ciclo_item i join public.compras_produto_fornecedor pf on pf.cdpro = i.cdpro
      where i.ciclo_id = p_ciclo and i.retirado_em is null group by 1
    ), com_acesso as (
      select distinct cdfnr cnpj from public.compras_acesso where papel = 'fornecedor' and ativo and cdfnr is not null
    )
    select coalesce(h.cnpj, ca.cnpj) cnpj, coalesce(h.itens, '{}') itens
    from habituais h full join com_acesso ca on ca.cnpj = h.cnpj
  loop
    perform public.compras_enfileirar(p_ciclo, 'convite', r.cnpj, r.itens);
  end loop;
end $$;

create or replace function public.compras_ciclo_travar(p_ciclo integer)
returns void language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso;
begin
  a := public.compras_exige(array['admin', 'comprador']);
  update public.compras_ciclo set status = 'travado', travado_em = now(), travado_por = a.email
  where id = p_ciclo and status = 'aberto';
  if not found then raise exception 'O ciclo % não está aberto', p_ciclo using errcode = '22023'; end if;
  update public.compras_ciclo_item i set qtd_travada = q.quantidade
  from public.compras_qtd_pedido() q
  where i.ciclo_id = p_ciclo and i.retirado_em is null and q.cdpro = i.cdpro;
end $$;

create or replace function public.compras_ciclos_listar()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.compras_exige(array['admin', 'comprador']);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', c.id, 'status', c.status, 'criado_em', c.criado_em, 'aberto_em', c.aberto_em, 'travado_em', c.travado_em,
      'itens', (select count(*) from public.compras_ciclo_item i where i.ciclo_id = c.id and i.retirado_em is null))
    order by c.id desc) from public.compras_ciclo c), '[]'::jsonb);
end $$;

-- detalhe de um ciclo (o ativo, se p_ciclo for nulo): itens com quantidade, valor, habitual e resumo das cotações
create or replace function public.compras_ciclo_detalhe(p_ciclo integer default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.compras_ciclo;
begin
  perform public.compras_exige(array['admin', 'comprador']);
  select * into c from public.compras_ciclo where id = coalesce(p_ciclo, (public.compras_ciclo_ativo()).id,
                                                                (select max(id) from public.compras_ciclo));
  if c.id is null then return null; end if;
  return jsonb_build_object(
    'ciclo', to_jsonb(c),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cdpro', i.cdpro, 'descr', p.descr, 'unida', p.unida, 'lista', l.lista, 'prcomn', p.prcomn,
        'quantidade', coalesce(i.qtd_travada, q.quantidade, 0),
        'cnpj', pf.cdfnr, 'fornecedor', coalesce(f.fantasia, pf.cdfnr),
        'incluido_em', i.incluido_em, 'apos_abertura', i.apos_abertura, 'retirado_em', i.retirado_em,
        'cotacoes', (select count(*) from public.compras_cotacao k where k.ciclo_id = c.id and k.cdpro = i.cdpro and k.preco is not null),
        'menor_preco', (select min(k.preco) from public.compras_cotacao k where k.ciclo_id = c.id and k.cdpro = i.cdpro),
        'menor_fornecedor', (select coalesce(f2.fantasia, k.cnpj) from public.compras_cotacao k
                               left join public.compras_fornecedor f2 on f2.cnpj = k.cnpj
                              where k.ciclo_id = c.id and k.cdpro = i.cdpro and k.preco is not null
                              order by k.preco, k.atualizado_em limit 1))
        order by i.retirado_em nulls first, p.prcomn * coalesce(i.qtd_travada, q.quantidade, 0) desc)
      from public.compras_ciclo_item i
      join public.compras_produto p on p.cdpro = i.cdpro
      left join public.compras_lista l on l.cdpro = i.cdpro
      left join public.compras_qtd_pedido() q on q.cdpro = i.cdpro
      left join public.compras_produto_fornecedor pf on pf.cdpro = i.cdpro
      left join public.compras_fornecedor f on f.cnpj = pf.cdfnr
      where i.ciclo_id = c.id), '[]'::jsonb),
    'emails', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'tipo', e.tipo, 'cnpj', e.cnpj,
               'fornecedor', coalesce(f.fantasia, e.cnpj), 'para', to_jsonb(e.para), 'assunto', e.assunto,
               'criado_em', e.criado_em, 'status', e.status, 'enviado_em', e.enviado_em, 'erro', e.erro)
             order by e.criado_em desc, e.id desc)
      from public.compras_email e left join public.compras_fornecedor f on f.cnpj = e.cnpj
      where e.ciclo_id = c.id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- fornecedor

-- itens do ciclo aberto que o fornecedor pode cotar (os que ele costuma fornecer, ou todos com p_todos)
create or replace function public.compras_cotacao_listar(p_todos boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.compras_acesso; c public.compras_ciclo;
begin
  a := public.compras_exige(array['fornecedor']);
  select * into c from public.compras_ciclo where status = 'aberto';
  if c.id is null then return jsonb_build_object('ciclo', null, 'itens', '[]'::jsonb); end if;
  return jsonb_build_object('ciclo', c.id, 'itens', coalesce((
    select jsonb_agg(jsonb_build_object(
      'cdpro', i.cdpro, 'descr', p.descr, 'unida', p.unida, 'quantidade', coalesce(q.quantidade, 0),
      'habitual', pf.cdfnr = a.cdfnr, 'novo', i.apos_abertura,
      'preco', k.preco, 'qtd_min', k.qtd_min, 'lances', coalesce(k.lances, 0),
      'total', k.preco * greatest(coalesce(q.quantidade, 0), coalesce(k.qtd_min, 0)),
      'status', case when k.preco is null then 'aguarda' when k.cego then 'cego'
                     when k.preco <= coalesce((select min(o.preco) from public.compras_cotacao o
                                                where o.ciclo_id = c.id and o.cdpro = i.cdpro and o.cnpj <> a.cdfnr), k.preco)
                     then 'ganha' else 'perde' end)
      order by (pf.cdfnr = a.cdfnr) desc, p.descr)
    from public.compras_ciclo_item i
    join public.compras_produto p on p.cdpro = i.cdpro
    left join public.compras_qtd_pedido() q on q.cdpro = i.cdpro
    left join public.compras_produto_fornecedor pf on pf.cdpro = i.cdpro
    left join public.compras_cotacao k on k.ciclo_id = c.id and k.cdpro = i.cdpro and k.cnpj = a.cdfnr
    where i.ciclo_id = c.id and i.retirado_em is null and (p_todos or pf.cdfnr = a.cdfnr)), '[]'::jsonb));
end $$;

-- preço (opcional) e quantidade mínima (opcional). Depois do primeiro preço, só aceita valor menor.
create or replace function public.compras_cotar(p_cdpro integer, p_preco numeric default null, p_qtd_min numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; c public.compras_ciclo; k public.compras_cotacao;
begin
  a := public.compras_exige(array['fornecedor']);
  select * into c from public.compras_ciclo where status = 'aberto';
  if c.id is null or not exists (select 1 from public.compras_ciclo_item
                                 where ciclo_id = c.id and cdpro = p_cdpro and retirado_em is null) then
    raise exception 'Este item não está em uma cotação aberta' using errcode = '22023';
  end if;
  if p_preco is not null and p_preco <= 0 then raise exception 'Informe um preço maior que zero' using errcode = '22023'; end if;
  insert into public.compras_cotacao (ciclo_id, cdpro, cnpj, atualizado_por)
  values (c.id, p_cdpro, a.cdfnr, a.email) on conflict do nothing;
  select * into k from public.compras_cotacao where ciclo_id = c.id and cdpro = p_cdpro and cnpj = a.cdfnr for update;
  if p_preco is not null then
    if k.preco is null then
      update public.compras_cotacao set preco = p_preco, lances = 1 where ciclo_id = c.id and cdpro = p_cdpro and cnpj = a.cdfnr;
    elsif p_preco < k.preco then
      update public.compras_cotacao set preco = p_preco, lances = lances + 1, cego = true
      where ciclo_id = c.id and cdpro = p_cdpro and cnpj = a.cdfnr;
    elsif p_preco > k.preco then
      raise exception 'Só é possível reduzir: seu preço atual é R$ %', replace(to_char(k.preco, 'FM999999990.00'), '.', ',') using errcode = '22023';
    end if;
  end if;
  if p_qtd_min is not null then
    update public.compras_cotacao set qtd_min = nullif(p_qtd_min, 0) where ciclo_id = c.id and cdpro = p_cdpro and cnpj = a.cdfnr;
  end if;
  update public.compras_cotacao set atualizado_em = now(), atualizado_por = a.email
  where ciclo_id = c.id and cdpro = p_cdpro and cnpj = a.cdfnr returning * into k;
  insert into public.compras_cotacao_hist (ciclo_id, cdpro, cnpj, preco, qtd_min, feito_por)
  values (c.id, p_cdpro, a.cdfnr, k.preco, k.qtd_min, a.email);
  return jsonb_build_object('preco', k.preco, 'qtd_min', k.qtd_min, 'lances', k.lances, 'cego', k.cego);
end $$;

-- ---------------------------------------------------------------- fila de e-mails (n8n)

create or replace function public.compras_email_fila(p_limite integer default 50)
returns setof public.compras_email language sql security definer set search_path = public as $$
  select * from public.compras_email where status = 'pendente' order by id limit p_limite;
$$;

create or replace function public.compras_email_resultado(p_id bigint, p_ok boolean, p_erro text default null)
returns void language sql security definer set search_path = public as $$
  update public.compras_email
     set status = case when p_ok then 'enviado' else 'erro' end,
         enviado_em = case when p_ok then now() end, erro = case when p_ok then null else left(p_erro, 500) end
   where id = p_id;
$$;

-- ---------------------------------------------------------------- permissões

alter table public.compras_ciclo        enable row level security;
alter table public.compras_ciclo_item   enable row level security;
alter table public.compras_cotacao      enable row level security;
alter table public.compras_cotacao_hist enable row level security;
alter table public.compras_email        enable row level security;

revoke all on public.compras_ciclo, public.compras_ciclo_item, public.compras_cotacao,
              public.compras_cotacao_hist, public.compras_email
  from anon, authenticated;

revoke all on function public.compras_qtd_pedido(), public.compras_ciclo_ativo(),
                       public.compras_enfileirar(integer, text, text, integer[]),
                       public.compras_ciclo_aplicar(integer[]), public.compras_ciclo_retirar(integer),
                       public.compras_ciclo_lancar(integer), public.compras_ciclo_travar(integer),
                       public.compras_ciclos_listar(), public.compras_ciclo_detalhe(integer),
                       public.compras_cotacao_listar(boolean), public.compras_cotar(integer, numeric, numeric),
                       public.compras_email_fila(integer), public.compras_email_resultado(bigint, boolean, text)
  from public, anon, authenticated;
grant execute on function public.compras_ciclo_aplicar(integer[]), public.compras_ciclo_retirar(integer),
                          public.compras_ciclo_lancar(integer), public.compras_ciclo_travar(integer),
                          public.compras_ciclos_listar(), public.compras_ciclo_detalhe(integer),
                          public.compras_cotacao_listar(boolean), public.compras_cotar(integer, numeric, numeric)
  to authenticated;
grant execute on function public.compras_email_fila(integer), public.compras_email_resultado(bigint, boolean, text) to service_role;
