-- compras_consumo180: consumo físico e frequência dos últimos 180 dias por produto, para o pedido por fornecedor.
-- Mesmas fontes do dataset de consumo: fórmulas manipuladas (FC12110, por CDPRIN e DTENTR) +
-- ordens de produção (FC18100 ligada à FC18000 por NRORD, data DTORD). Banco: Firebird (Fórmula Certa), réplica.
WITH
Q1 AS (
  SELECT CDPRIN AS CDPRO, SUM(QTREAL) AS FISICO, COUNT(*) AS FREQ
  FROM FC12110 WHERE DTENTR >= CURRENT_DATE - 180 GROUP BY CDPRIN
),
Q2 AS (
  SELECT i.CDPRO, SUM(i.QTREAL) AS FISICO, COUNT(*) AS FREQ
  FROM FC18100 i JOIN FC18000 o ON o.NRORD = i.NRORD
  WHERE o.DTORD >= CURRENT_DATE - 180 GROUP BY i.CDPRO
),
U AS (SELECT * FROM Q1 UNION ALL SELECT * FROM Q2)
SELECT CDPRO, SUM(FISICO) AS FISICO180D, SUM(FREQ) AS FREQUENCIA180D FROM U GROUP BY CDPRO
