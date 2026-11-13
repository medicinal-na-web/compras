-- Dataset_Compras_FC03140: estoque atual por produto nas filiais 1 e 2.
-- Origem: dataflow do Power BI (LISTADECOMPRAS.V7). Banco: Firebird (Fórmula Certa).
SELECT
    CDPRO,
    SUM(IIF(CDFIL = 1, ESTAT, 0)) AS EstoqueFilial1,
    SUM(IIF(CDFIL = 2, ESTAT, 0)) AS EstoqueFilial2
FROM
    FC03140
GROUP BY
    CDPRO
