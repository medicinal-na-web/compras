-- compras_fornecedor_item: todo par produto × fornecedor com lote de entrada nos últimos 3 anos (FC03140).
-- Lotes de FÓRMULA PADRÃO (produção interna) e com data futura ficam de fora. Banco: Firebird (Fórmula Certa), réplica.
SELECT L.CDPRO, TRIM(L.CDFNR) AS CDFNR, CAST(MAX(L.DTENT) AS VARCHAR(10)) AS ULTIMA, COUNT(*) AS LOTES
FROM FC03140 L
WHERE COALESCE(L.ORLOT, '') <> 'FORMULA PADRAO'
  AND L.CDFNR IS NOT NULL
  AND L.DTENT BETWEEN CURRENT_DATE - 1095 AND CURRENT_DATE
GROUP BY L.CDPRO, TRIM(L.CDFNR)
