-- compras_produto_fornecedor: fornecedor do lote de entrada mais recente de cada produto.
-- Lotes de FÓRMULA PADRÃO são produção interna e ficam de fora; lotes com data futura (erro de
-- digitação) também. Janela de 3 anos. O n8n escolhe o lote mais recente por produto no nó Code
-- (a subconsulta correlacionada com MAX(DTENT) é pesada demais na réplica).
-- Banco: Firebird (Fórmula Certa), réplica.
SELECT L.CDPRO, TRIM(L.CDFNR) AS CDFNR, CAST(L.DTENT AS VARCHAR(10)) AS DTENT
FROM FC03140 L
WHERE COALESCE(L.ORLOT, '') <> 'FORMULA PADRAO'
  AND L.CDFNR IS NOT NULL
  AND L.DTENT BETWEEN CURRENT_DATE - 1095 AND CURRENT_DATE
