# Protótipo do Portal de Compras

`lista-compras.html` é o modelo da página publicada como artefato (claude.ai). O marcador `__DADOS__`
recebe a lista de produtos em JSON: `[cdpro, descr, situa, unida, prcomn, controlado, porta,
estoque_f1, estoque_f2, consumo_fisico_30d, consumo_fisico_90d, consumo_custo_90d, consumo_frequencia_90d,
ultimo_fornecedor_cnpj]`. O marcador `__FORNECEDORES__` recebe `{cnpj: [nome fantasia, razão social]}`
da FC02000 (`sql/formula-certa/compras_fornecedor.sql`). O marcador `__CADASTRO__` recebe a FC02000 inteira:
`[fornecid, cnpj, fantasia, razão, contato, [e-mails válidos], telefone, texto do campo e-mail que não é e-mail]`.
Contém contatos de fornecedores: não vai para o repositório.

Os dados não ficam no repositório (custos e estoques do ERP). Hoje vêm do snapshot do
`LISTADECOMPRAS.V7.pbix`; quando a carga do n8n estiver ativa, vêm da view `compras_lista` do Supabase.

O cálculo em JavaScript repete a view `compras_lista`
(`supabase/migrations/20261114120000_compras_lista_v1.sql`). Mudou a regra num, mude no outro.
Visual no molde dos portais da casa (PortalSiteMedicinal).

## Perfis de acesso

O seletor "Ver como" simula os perfis. No portal, o perfil vem do login e as regras valem no banco
(`supabase/migrations/20261118120000_compras_acesso_v1.sql`):

| Perfil | Vê | Pode |
|---|---|---|
| Administrador | tudo | ajustar quantidades, alterar parâmetros, cadastrar acessos |
| Comprador | tudo, com preços e valores | ajustar quantidades |
| Produção | lista sem preços e valores | só consultar |
| Fornecedor | só os itens do pedido ligados ao próprio CNPJ (código, descrição, unidade, quantidade) | só consultar |
