# Portal de Compras (produção)

`compras.html` é o fragmento que o Brasa CMS injeta na rota **/compras** de www.medicinalnaweb.com.br,
no mesmo molde dos outros portais (PCP, IG, SM): `<style>` escopado em `#cmproot`, a raiz em tela cheia
e um `<script>` que fala com o Supabase **formulaCerta** só por `rpc`, com a chave anon e o token do login.

## Login
1. `compras_email_autorizado(p_email)` (anon) confere se o e-mail tem acesso ativo em `compras_acesso`.
2. `/auth/v1/otp` com `create_user:false` envia o código; `/auth/v1/verify` devolve a sessão.
3. `compras_eu()` diz o perfil: admin, comprador, produção ou fornecedor (ligado ao CNPJ).

A conta de login é criada pela Edge Function `compras-provisionar-login`, disparada pelo gatilho em
`compras_acesso` (cadastro na aba Acessos ou liberação de fornecedor na aba Fornecedores).

## RPCs usadas
| Tela | RPC |
|---|---|
| Lista (interno) | `compras_lista_compacta`, `compras_parametros`, `compras_ajustar` |
| Ciclo | `compras_ciclo_aplicar`, `compras_ciclo_retirar`, `compras_ciclo_lancar`, `compras_ciclo_travar`, `compras_ciclos_listar`, `compras_ciclo_detalhe` |
| Cotação (fornecedor) | `compras_cotacao_listar`, `compras_cotar` |
| Fornecedores | `compras_listar_fornecedores`, `compras_liberar_fornecedor` |
| Acessos (admin) | `compras_listar_acessos`, `compras_salvar_acesso` |
| Parâmetros (admin) | `compras_salvar_parametros` |

## Publicar uma nova versão
O conteúdo fica em `public._brasa_parts_compras` (partes base64 de 8.000 caracteres) e o CMS lê por
`brasa_loader_compras()`. `python3 portal/publicar.py` gera o SQL que guarda a versão anterior em
`_brasa_parts_compras_bkp_<data>` e troca as partes. Depois de publicar, confira o md5 do loader contra o arquivo.

## Peças fora deste arquivo
- Carga diária do FórmulaCerta: workflow n8n "Compras - Carga FórmulaCerta (réplica)" (`n8n/compras-carga-formulacerta.js`), 5h40.
- E-mails aos fornecedores: workflow n8n "Compras - Envio de e-mails aos fornecedores" (`n8n/compras-envio-emails.js`), lê a fila `compras_email`.
- A página /compras no Brasa CMS é criada por quem administra o site, apontando para `brasa_loader_compras()`.
