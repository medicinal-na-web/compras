-- Ciclo de compras v2: passo a passo (1 escolher produtos, 2 revisar e incluir, 3 lançar com prazo).
--
--  * Prazo de fechamento (compras_ciclo.fecha_em): obrigatório ao lançar. Depois dele o fornecedor não
--    grava mais preço nem quantidade mínima (compras_cotar recusa), e o ciclo é travado na primeira
--    chamada de compras_ciclo_travar_vencidos (o portal chama ao abrir; o n8n pode chamar também).
--  * Quantidade por item no ciclo (compras_ciclo_item.quantidade): vazia = quantidade do pedido da lista
--    (ajuste do comprador ou sugestão). Preenchida = definida na etapa 2.
--  * Itens fora da sugestão: produto cadastrado (qualquer um de compras_produto) ou item avulso digitado
--    (não cadastrado no FórmulaCerta). Avulso recebe código negativo e guarda descrição e unidade.
--  * Link dos e-mails: https://portalcompras.medicinalnaweb.com.br

alter table public.compras_ciclo add column if not exists fecha_em timestamptz;
comment on column public.compras_ciclo.fecha_em is 'Fechamento da cotação: depois disso o fornecedor não altera mais nada.';

alter table public.compras_ciclo_item add column if not exists quantidade numeric check (quantidade >= 0);
alter table public.compras_ciclo_item add column if not exists descr_avulsa text;
alter table public.compras_ciclo_item add column if not exists unida_avulsa text;
comment on column public.compras_ciclo_item.quantidade is 'Quantidade definida no ciclo. Vazia = quantidade do pedido da lista (compras_qtd_pedido).';
comment on column public.compras_ciclo_item.descr_avulsa is 'Item avulso (não cadastrado no FórmulaCerta): cdpro negativo, descrição digitada.';

create sequence if not exists public.compras_avulso_seq;

-- descrição e unidade de um item do ciclo (cadastrado ou avulso)
create or replace function public.compras_item_descr(p_cdpro integer, p_ciclo integer)
returns table (descr text, unida text) language sql stable security definer set search_path = public as $$
  select coalesce(p.descr, i.descr_avulsa, p_cdpro::text), coalesce(p.unida, i.unida_avulsa, '')
  from (select 1) x
  left join public.compras_produto p on p.cdpro = p_cdpro
  left join public.compras_ciclo_item i on i.ciclo_id = p_ciclo and i.cdpro = p_cdpro;
$$;

-- quantidade efetiva de cada item de um ciclo
create or replace function public.compras_ciclo_qtd(p_ciclo integer)
returns table (cdpro integer, quantidade numeric) language sql stable security definer set search_path = public as $$
  select i.cdpro, coalesce(i.qtd_travada, i.quantidade, q.quantidade, 0)
  from public.compras_ciclo_item i left join public.compras_qtd_pedido() q on q.cdpro = i.cdpro
  where i.ciclo_id = p_ciclo;
$$;

-- ---------------------------------------------------------------- e-mails

create or replace function public.compras_enfileirar(p_ciclo integer, p_tipo text, p_cnpj text, p_itens integer[])
returns void language plpgsql security definer set search_path = public as $$
declare para text[]; nome text; lista text; n integer := coalesce(array_length(p_itens, 1), 0); assunto text; corpo text; prazo text;
begin
  select coalesce(array_agg(email order by email), '{}') into para
  from public.compras_acesso where papel = 'fornecedor' and ativo and cdfnr = p_cnpj;
  select coalesce(fantasia, razao, p_cnpj) into nome from public.compras_fornecedor where cnpj = p_cnpj;
  select to_char(fecha_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY "às" HH24:MI') into prazo from public.compras_ciclo where id = p_ciclo;
  select string_agg('- ' || d.descr || case when i > 0 then ' (' || i || ')' else '' end, E'\n' order by d.descr) into lista
  from unnest(p_itens) i cross join lateral public.compras_item_descr(i, p_ciclo) d;
  assunto := case p_tipo
    when 'convite'  then format('Medicinal: cotação do ciclo %s aberta', p_ciclo)
                         || case when prazo is not null then ' até ' || prazo else '' end
    when 'inclusao' then format('Ciclo %s: %s à cotação da Medicinal', p_ciclo, case when n = 1 then 'item adicionado' else n || ' itens adicionados' end)
    else                 format('Ciclo %s: %s da cotação da Medicinal', p_ciclo, case when n = 1 then 'item retirado' else n || ' itens retirados' end) end;
  corpo := format(E'Olá, %s.\n\n', coalesce(nome, 'fornecedor'))
    || case p_tipo
         when 'convite'  then format(E'A cotação do ciclo %s de compras da Medicinal está aberta.\n', p_ciclo)
         when 'inclusao' then format(E'Incluímos na cotação do ciclo %s:\n', p_ciclo)
         else                 format(E'Retiramos da cotação do ciclo %s (não precisa mais cotar):\n', p_ciclo) end
    || case when lista is not null then case when p_tipo = 'convite' then E'Itens que você costuma fornecer:\n' else '' end || lista || E'\n' else '' end
    || case when prazo is not null and p_tipo <> 'retirada'
            then format(E'\nPrazo: até %s (horário de Brasília). Depois disso a cotação fecha e não aceita mais preços nem alterações.\n', prazo) else '' end
    || E'\nAcesse o Portal de Compras para informar ou rever seus preços:\nhttps://portalcompras.medicinalnaweb.com.br\n\nEquipe de Compras · Medicinal';
  insert into public.compras_email (ciclo_id, tipo, cnpj, para, assunto, corpo, itens, status)
  values (p_ciclo, p_tipo, p_cnpj, para, assunto, corpo, coalesce(p_itens, '{}'),
          case when cardinality(para) = 0 then 'sem_destinatario' else 'pendente' end);
end $$;

-- aviso de inclusão com o ciclo aberto: habitual do item; avulso vai a todos os fornecedores com acesso
create or replace function public.compras_avisar_inclusao(p_ciclo integer, p_itens integer[])
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select cnpj, array_agg(i order by i) itens from (
      select i, pf.cdfnr cnpj from unnest(p_itens) i join public.compras_produto_fornecedor pf on pf.cdpro = i where i > 0
      union all
      select i, a.cnpj from unnest(p_itens) i
        cross join (select distinct cdfnr cnpj from public.compras_acesso where papel = 'fornecedor' and ativo and cdfnr is not null) a
      where i < 0) x
    group by cnpj
  loop
    perform public.compras_enfileirar(p_ciclo, 'inclusao', r.cnpj, r.itens);
  end loop;
end $$;

-- ---------------------------------------------------------------- comprador

-- ciclo ativo para receber itens (cria em montagem se não houver); recusa ciclo com prazo vencido
create or replace function public.compras_ciclo_para_incluir(p_email text)
returns public.compras_ciclo language plpgsql security definer set search_path = public as $$
declare c public.compras_ciclo;
begin
  c := public.compras_ciclo_ativo();
  if c.id is null then
    insert into public.compras_ciclo (criado_por) values (p_email) returning * into c;
  elsif c.status = 'aberto' and c.fecha_em <= now() then
    raise exception 'A cotação do ciclo % já fechou (%). Trave o ciclo ou mude o prazo para incluir itens.', c.id,
      to_char(c.fecha_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') using errcode = '22023';
  end if;
  return c;
end $$;

create or replace function public.compras_ciclo_aplicar(p_cdpros integer[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; c public.compras_ciclo; novos integer[] := '{}';
begin
  a := public.compras_exige(array['admin', 'comprador']);
  c := public.compras_ciclo_para_incluir(a.email);
  with alvo as (
    select distinct x as cdpro from unnest(p_cdpros) x
    where exists (select 1 from public.compras_produto p where p.cdpro = x)
  ), gravados as (
    insert into public.compras_ciclo_item (ciclo_id, cdpro, incluido_por, apos_abertura)
    select c.id, alvo.cdpro, a.email, c.status = 'aberto' from alvo
    on conflict (ciclo_id, cdpro) do update
      set incluido_em = now(), incluido_por = excluded.incluido_por, apos_abertura = excluded.apos_abertura,
          retirado_em = null, retirado_por = null
      where compras_ciclo_item.retirado_em is not null
    returning cdpro
  )
  select coalesce(array_agg(cdpro), '{}') into novos from gravados;
  if c.status = 'aberto' and cardinality(novos) > 0 then perform public.compras_avisar_inclusao(c.id, novos); end if;
  return jsonb_build_object('ciclo', c.id, 'status', c.status, 'incluidos', cardinality(novos));
end $$;

-- inclui um produto cadastrado (sugerido ou não) com quantidade definida
create or replace function public.compras_ciclo_incluir(p_cdpro integer, p_quantidade numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; c public.compras_ciclo; novo boolean;
begin
  a := public.compras_exige(array['admin', 'comprador']);
  if not exists (select 1 from public.compras_produto where cdpro = p_cdpro) then
    raise exception 'Produto % não está no cadastro', p_cdpro using errcode = '22023';
  end if;
  if p_quantidade is null or p_quantidade <= 0 then raise exception 'Informe a quantidade' using errcode = '22023'; end if;
  c := public.compras_ciclo_para_incluir(a.email);
  select not exists (select 1 from public.compras_ciclo_item where ciclo_id = c.id and cdpro = p_cdpro and retirado_em is null) into novo;
  insert into public.compras_ciclo_item (ciclo_id, cdpro, incluido_por, apos_abertura, quantidade)
  values (c.id, p_cdpro, a.email, c.status = 'aberto', p_quantidade)
  on conflict (ciclo_id, cdpro) do update set quantidade = excluded.quantidade,
    incluido_em = case when compras_ciclo_item.retirado_em is not null then now() else compras_ciclo_item.incluido_em end,
    apos_abertura = case when compras_ciclo_item.retirado_em is not null then excluded.apos_abertura else compras_ciclo_item.apos_abertura end,
    retirado_em = null, retirado_por = null;
  if c.status = 'aberto' and novo then perform public.compras_avisar_inclusao(c.id, array[p_cdpro]); end if;
  return jsonb_build_object('ciclo', c.id, 'status', c.status, 'cdpro', p_cdpro, 'novo', novo);
end $$;

-- inclui um item avulso, não cadastrado no FórmulaCerta
create or replace function public.compras_ciclo_avulso(p_descr text, p_unida text, p_quantidade numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; c public.compras_ciclo; cd integer;
begin
  a := public.compras_exige(array['admin', 'comprador']);
  if coalesce(btrim(p_descr), '') = '' then raise exception 'Informe a descrição do item' using errcode = '22023'; end if;
  if p_quantidade is null or p_quantidade <= 0 then raise exception 'Informe a quantidade' using errcode = '22023'; end if;
  c := public.compras_ciclo_para_incluir(a.email);
  cd := -nextval('public.compras_avulso_seq')::integer;
  insert into public.compras_ciclo_item (ciclo_id, cdpro, incluido_por, apos_abertura, quantidade, descr_avulsa, unida_avulsa)
  values (c.id, cd, a.email, c.status = 'aberto', p_quantidade, upper(btrim(p_descr)), nullif(upper(btrim(coalesce(p_unida, ''))), ''));
  if c.status = 'aberto' then perform public.compras_avisar_inclusao(c.id, array[cd]); end if;
  return jsonb_build_object('ciclo', c.id, 'status', c.status, 'cdpro', cd);
end $$;

-- muda a quantidade de um item do ciclo ativo (vazia = volta à quantidade do pedido da lista)
create or replace function public.compras_ciclo_quantidade(p_cdpro integer, p_quantidade numeric)
returns void language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; c public.compras_ciclo;
begin
  a := public.compras_exige(array['admin', 'comprador']);
  c := public.compras_ciclo_ativo();
  if p_quantidade is not null and p_quantidade < 0 then raise exception 'Quantidade inválida' using errcode = '22023'; end if;
  update public.compras_ciclo_item set quantidade = p_quantidade
  where ciclo_id = c.id and cdpro = p_cdpro and retirado_em is null
    and (p_quantidade is not null or cdpro > 0);
  if not found then raise exception 'O item % não está no ciclo ativo', p_cdpro using errcode = '22023'; end if;
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

drop function if exists public.compras_ciclo_lancar(integer);
create or replace function public.compras_ciclo_lancar(p_ciclo integer, p_fecha_em timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.compras_acesso; r record; n integer := 0;
begin
  a := public.compras_exige(array['admin', 'comprador']);
  if p_fecha_em is null or p_fecha_em <= now() + interval '10 minutes' then
    raise exception 'Informe a data e a hora de fechamento (pelo menos 10 minutos a partir de agora)' using errcode = '22023';
  end if;
  if not exists (select 1 from public.compras_ciclo_item where ciclo_id = p_ciclo and retirado_em is null) then
    raise exception 'O ciclo % não tem itens', p_ciclo using errcode = '22023';
  end if;
  update public.compras_ciclo set status = 'aberto', aberto_em = now(), aberto_por = a.email, fecha_em = p_fecha_em
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
    n := n + 1;
  end loop;
  return jsonb_build_object('ciclo', p_ciclo, 'fecha_em', p_fecha_em, 'convites', n,
    'com_destinatario', (select count(*) from public.compras_email where ciclo_id = p_ciclo and tipo = 'convite' and status = 'pendente'));
end $$;

-- muda o prazo de um ciclo aberto (não avisa por e-mail)
create or replace function public.compras_ciclo_prazo(p_ciclo integer, p_fecha_em timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.compras_exige(array['admin', 'comprador']);
  if p_fecha_em is null or p_fecha_em <= now() then raise exception 'O novo prazo precisa ser no futuro' using errcode = '22023'; end if;
  update public.compras_ciclo set fecha_em = p_fecha_em where id = p_ciclo and status = 'aberto';
  if not found then raise exception 'O ciclo % não está aberto', p_ciclo using errcode = '22023'; end if;
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
  from public.compras_ciclo_qtd(p_ciclo) q
  where i.ciclo_id = p_ciclo and i.retirado_em is null and q.cdpro = i.cdpro;
end $$;

-- trava os ciclos abertos com prazo vencido (portal ao abrir; n8n)
create or replace function public.compras_ciclo_travar_vencidos()
returns integer language plpgsql security definer set search_path = public as $$
declare c record; n integer := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role' then perform public.compras_exige(array['admin', 'comprador']); end if;
  for c in select id from public.compras_ciclo where status = 'aberto' and fecha_em <= now() loop
    update public.compras_ciclo set status = 'travado', travado_em = now(), travado_por = 'prazo de fechamento' where id = c.id;
    update public.compras_ciclo_item i set qtd_travada = q.quantidade
    from public.compras_ciclo_qtd(c.id) q
    where i.ciclo_id = c.id and i.retirado_em is null and q.cdpro = i.cdpro;
    n := n + 1;
  end loop;
  return n;
end $$;

-- produtos do cadastro para incluir fora da sugestão
create or replace function public.compras_produtos_buscar(p_q text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := lower(btrim(coalesce(p_q, '')));
begin
  perform public.compras_exige(array['admin', 'comprador']);
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'descr') from (
      select jsonb_build_object('cdpro', p.cdpro, 'descr', p.descr, 'unida', p.unida, 'situa', p.situa, 'grupo', p.grupo,
                                'prcomn', coalesce(nullif(p.prcomn, 0), p.prcom), 'lista', l.lista,
                                'qtd_sugerida', coalesce(l.quantidade_compra, 0),
                                'fornecedor', coalesce(f.fantasia, pf.cdfnr)) x
      from public.compras_produto p
      left join public.compras_lista l on l.cdpro = p.cdpro
      left join public.compras_produto_fornecedor pf on pf.cdpro = p.cdpro
      left join public.compras_fornecedor f on f.cnpj = pf.cdfnr
      where p.cdpro::text = q or lower(p.descr) like '%' || q || '%'
      order by (p.cdpro::text = q) desc, (p.situa = 'A') desc, p.descr
      limit 40) s), '[]'::jsonb);
end $$;

create or replace function public.compras_ciclos_listar()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.compras_exige(array['admin', 'comprador']);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', c.id, 'status', c.status, 'criado_em', c.criado_em, 'aberto_em', c.aberto_em, 'travado_em', c.travado_em, 'fecha_em', c.fecha_em,
      'itens', (select count(*) from public.compras_ciclo_item i where i.ciclo_id = c.id and i.retirado_em is null))
    order by c.id desc) from public.compras_ciclo c), '[]'::jsonb);
end $$;

create or replace function public.compras_ciclo_detalhe(p_ciclo integer default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.compras_ciclo;
begin
  perform public.compras_exige(array['admin', 'comprador']);
  select * into c from public.compras_ciclo where id = coalesce(p_ciclo, (public.compras_ciclo_ativo()).id,
                                                                (select max(id) from public.compras_ciclo));
  if c.id is null then return null; end if;
  return jsonb_build_object(
    'ciclo', to_jsonb(c) || jsonb_build_object('fechado_para_fornecedor', c.fecha_em is not null and c.fecha_em <= now()),
    'fornecedores_com_acesso', (select count(distinct cdfnr) from public.compras_acesso where papel = 'fornecedor' and ativo and cdfnr is not null),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cdpro', i.cdpro, 'descr', d.descr, 'unida', d.unida, 'avulso', i.cdpro < 0, 'lista', l.lista, 'prcomn', coalesce(nullif(p.prcomn, 0), p.prcom),
        'quantidade', q.quantidade, 'qtd_definida', i.quantidade is not null, 'qtd_lista', coalesce(qp.quantidade, 0),
        'sugerido', coalesce(l.comprar, false),
        'cnpj', pf.cdfnr, 'fornecedor', coalesce(f.fantasia, pf.cdfnr),
        'incluido_em', i.incluido_em, 'apos_abertura', i.apos_abertura, 'retirado_em', i.retirado_em,
        'cotacoes', (select count(*) from public.compras_cotacao k where k.ciclo_id = c.id and k.cdpro = i.cdpro and k.preco is not null),
        'menor_preco', (select min(k.preco) from public.compras_cotacao k where k.ciclo_id = c.id and k.cdpro = i.cdpro),
        'menor_fornecedor', (select coalesce(f2.fantasia, k.cnpj) from public.compras_cotacao k
                               left join public.compras_fornecedor f2 on f2.cnpj = k.cnpj
                              where k.ciclo_id = c.id and k.cdpro = i.cdpro and k.preco is not null
                              order by k.preco, k.atualizado_em limit 1))
        order by i.retirado_em nulls first, coalesce(nullif(p.prcomn, 0), p.prcom, 0) * q.quantidade desc, d.descr)
      from public.compras_ciclo_item i
      cross join lateral public.compras_item_descr(i.cdpro, c.id) d
      join public.compras_ciclo_qtd(c.id) q on q.cdpro = i.cdpro
      left join public.compras_qtd_pedido() qp on qp.cdpro = i.cdpro
      left join public.compras_produto p on p.cdpro = i.cdpro
      left join public.compras_lista l on l.cdpro = i.cdpro
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

create or replace function public.compras_cotacao_listar(p_todos boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.compras_acesso; c public.compras_ciclo;
begin
  a := public.compras_exige(array['fornecedor']);
  select * into c from public.compras_ciclo where status = 'aberto';
  if c.id is null then return jsonb_build_object('ciclo', null, 'itens', '[]'::jsonb); end if;
  return jsonb_build_object('ciclo', c.id, 'fecha_em', c.fecha_em, 'fechada', c.fecha_em <= now(), 'itens', coalesce((
    select jsonb_agg(jsonb_build_object(
      'cdpro', i.cdpro, 'descr', d.descr, 'unida', d.unida, 'quantidade', q.quantidade, 'avulso', i.cdpro < 0,
      'habitual', pf.cdfnr = a.cdfnr, 'novo', i.apos_abertura,
      'preco', k.preco, 'qtd_min', k.qtd_min, 'lances', coalesce(k.lances, 0),
      'total', k.preco * greatest(q.quantidade, coalesce(k.qtd_min, 0)),
      'status', case when k.preco is null then 'aguarda' when k.cego then 'cego'
                     when k.preco <= coalesce((select min(o.preco) from public.compras_cotacao o
                                                where o.ciclo_id = c.id and o.cdpro = i.cdpro and o.cnpj <> a.cdfnr), k.preco)
                     then 'ganha' else 'perde' end)
      order by (pf.cdfnr = a.cdfnr) desc nulls last, d.descr)
    from public.compras_ciclo_item i
    cross join lateral public.compras_item_descr(i.cdpro, c.id) d
    join public.compras_ciclo_qtd(c.id) q on q.cdpro = i.cdpro
    left join public.compras_produto_fornecedor pf on pf.cdpro = i.cdpro
    left join public.compras_cotacao k on k.ciclo_id = c.id and k.cdpro = i.cdpro and k.cnpj = a.cdfnr
    where i.ciclo_id = c.id and i.retirado_em is null and (p_todos or pf.cdfnr = a.cdfnr)), '[]'::jsonb));
end $$;

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
  if c.fecha_em is not null and c.fecha_em <= now() then
    raise exception 'A cotação fechou em %. Não é mais possível alterar.', to_char(c.fecha_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
      using errcode = '22023';
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

-- ---------------------------------------------------------------- permissões

revoke all on sequence public.compras_avulso_seq from anon, authenticated;
revoke all on function public.compras_item_descr(integer, integer), public.compras_ciclo_qtd(integer),
                       public.compras_enfileirar(integer, text, text, integer[]), public.compras_avisar_inclusao(integer, integer[]),
                       public.compras_ciclo_para_incluir(text),
                       public.compras_ciclo_aplicar(integer[]), public.compras_ciclo_incluir(integer, numeric),
                       public.compras_ciclo_avulso(text, text, numeric), public.compras_ciclo_quantidade(integer, numeric),
                       public.compras_ciclo_retirar(integer), public.compras_ciclo_lancar(integer, timestamptz),
                       public.compras_ciclo_prazo(integer, timestamptz), public.compras_ciclo_travar(integer),
                       public.compras_ciclo_travar_vencidos(), public.compras_produtos_buscar(text),
                       public.compras_ciclos_listar(), public.compras_ciclo_detalhe(integer),
                       public.compras_cotacao_listar(boolean), public.compras_cotar(integer, numeric, numeric)
  from public, anon, authenticated;
grant execute on function public.compras_ciclo_aplicar(integer[]), public.compras_ciclo_incluir(integer, numeric),
                          public.compras_ciclo_avulso(text, text, numeric), public.compras_ciclo_quantidade(integer, numeric),
                          public.compras_ciclo_retirar(integer), public.compras_ciclo_lancar(integer, timestamptz),
                          public.compras_ciclo_prazo(integer, timestamptz), public.compras_ciclo_travar(integer),
                          public.compras_ciclo_travar_vencidos(), public.compras_produtos_buscar(text),
                          public.compras_ciclos_listar(), public.compras_ciclo_detalhe(integer),
                          public.compras_cotacao_listar(boolean), public.compras_cotar(integer, numeric, numeric)
  to authenticated;
grant execute on function public.compras_ciclo_travar_vencidos() to service_role;
