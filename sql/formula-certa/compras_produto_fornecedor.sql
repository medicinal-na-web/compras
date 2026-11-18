-- compras_produto_fornecedor: fornecedor do lote de entrada mais recente de cada produto.
-- Lotes de FÓRMULA PADRÃO são produção interna e ficam de fora.
-- Banco: Firebird (Fórmula Certa), réplica.
SELECT l.CDPRO, l.CDFNR, CAST(l.DTENT AS VARCHAR(10)) AS DTENT
FROM FC03140 l
WHERE l.ORLOT <> 'FORMULA PADRAO'
  AND l.CDFNR IS NOT NULL
  AND l.DTENT = (SELECT MAX(x.DTENT) FROM FC03140 x
                 WHERE x.CDPRO = l.CDPRO AND x.ORLOT <> 'FORMULA PADRAO' AND x.CDFNR IS NOT NULL)
