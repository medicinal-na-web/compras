# Protótipo do Portal de Compras

`lista-compras.html` é o modelo da página publicada como artefato (claude.ai). O marcador `__DADOS__`
recebe a lista de produtos em JSON: `[cdpro, descr, situa, unida, prcomn, controlado, porta,
estoque_f1, estoque_f2, consumo_fisico_30d, consumo_fisico_90d, consumo_custo_90d, consumo_frequencia_90d]`.

Os dados não ficam no repositório (custos e estoques do ERP). Hoje vêm do snapshot do
`LISTADECOMPRAS.V7.pbix`; quando a carga do n8n estiver ativa, vêm da view `compras_lista` do Supabase.

O cálculo em JavaScript repete a view `compras_lista`
(`supabase/migrations/20261114120000_compras_lista_v1.sql`). Mudou a regra num, mude no outro.
Visual no molde dos portais da casa (PortalSiteMedicinal).
