-- Portal de Compras: RPCs de leitura para o app publicado em /compras.
--  * compras_parametros(): parâmetros atuais (admin edita; comprador e produção só veem).
--  * compras_lista_compacta(): a lista em linhas compactas (arrays) para o app — ~600 KB em vez de ~3 MB.
--    Produção recebe a mesma linha sem preço, total e fornecedor (nulos).

create or replace function public.compras_parametros()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.compras_exige(array['admin', 'comprador', 'producao']);
  return (select to_jsonb(p) - 'id' from public.compras_parametro p where p.id);
end $$;

create or replace function public.compras_lista_compacta()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.compras_acesso; vp boolean;
begin
  a := public.compras_exige(array['admin', 'comprador', 'producao']);
  vp := a.papel <> 'producao';
  return jsonb_build_object(
    'atualizado_em', (select max(synced_at) from public.compras_estoque),
    'colunas', jsonb_build_array('cdpro', 'descr', 'situa', 'unida', 'ctrl', 'e1', 'e2', 'f30', 'f90',
                                 'cf', 'cfi', 'cfr', 'lista', 'media', 'dg', 'd2', 'comprar', 'qtd', 'qtdF',
                                 'ajustado', 'prcomn', 'cdfnr', 'forn'),
    'linhas', coalesce((
      select jsonb_agg(jsonb_build_array(
               l.cdpro, l.descr, l.situa, l.unida, l.controlado, l.estoque_filial1, l.estoque_filial2,
               l.fisico_30d, l.fisico_90d, l.curva_financeiro, l.curva_fisico, l.curva_frequencia, l.lista,
               l.media_consumo_diario, l.dias_consumo_geral, l.dias_consumo_filial2, l.comprar,
               l.quantidade_compra, coalesce(aj.quantidade, l.quantidade_compra), aj.cdpro is not null,
               case when vp then l.prcomn end,
               case when vp then pf.cdfnr end,
               case when vp then coalesce(cf.fantasia, cf.razao, pf.cdfnr) end))
      from public.compras_lista l
      left join public.compras_pedido_ajuste aj on aj.cdpro = l.cdpro
      left join public.compras_produto_fornecedor pf on pf.cdpro = l.cdpro
      left join public.compras_fornecedor cf on cf.cnpj = pf.cdfnr), '[]'::jsonb));
end $$;

revoke all on function public.compras_parametros(), public.compras_lista_compacta() from public, anon;
grant execute on function public.compras_parametros(), public.compras_lista_compacta() to authenticated;
