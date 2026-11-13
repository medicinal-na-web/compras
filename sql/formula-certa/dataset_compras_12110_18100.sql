-- DataSet_Compras_12110_18100: consumo por produto nos últimos 30 e 90 dias.
--   Q1 = FC12110 (consumo das fórmulas manipuladas)
--   Q2 = FC18100/FC18000 (ordens de produção, sufixo FP)
--   Consolidado = Q1 + Q2
-- Origem: dataflow do Power BI (LISTADECOMPRAS.V7). Banco: Firebird (Fórmula Certa).
WITH
Q1 AS (
    SELECT
        CDPRIN AS CDPRO,

        -- FC12110 - consumo normal

        -- Últimos 30 dias
        SUM(CASE WHEN DTENTR >= CURRENT_DATE - 30 THEN 1      ELSE 0 END) AS SomaFrequencia30D,
        SUM(CASE WHEN DTENTR >= CURRENT_DATE - 30 THEN QTREAL ELSE 0 END) AS SomaFisico30D,
        SUM(CASE WHEN DTENTR >= CURRENT_DATE - 30 THEN PRCUSTO ELSE 0 END) AS SomaCusto30D,

        -- Últimos 90 dias
        SUM(CASE WHEN DTENTR >= CURRENT_DATE - 90 THEN 1      ELSE 0 END) AS SomaFrequencia90D,
        SUM(CASE WHEN DTENTR >= CURRENT_DATE - 90 THEN QTREAL ELSE 0 END) AS SomaFisico90D,
        SUM(CASE WHEN DTENTR >= CURRENT_DATE - 90 THEN PRCUSTO ELSE 0 END) AS SomaCusto90D,

        -- Colunas da parte FP zeradas (serão preenchidas na Q2)
        0 AS SomaFrequencia30DFP,
        0 AS SomaFisico30DFP,
        0 AS SomaCusto30DFP,
        0 AS SomaFrequencia90DFP,
        0 AS SomaFisico90DFP,
        0 AS SomaCusto90DFP

    FROM
        FC12110
    WHERE
        DTENTR >= CURRENT_DATE - 90   -- já limita a leitura aos últimos 90 dias
    GROUP BY
        CDPRIN
),

Q2 AS (
    SELECT
        i.CDPRO,

        -- Colunas da parte “normal” zeradas
        0 AS SomaFrequencia30D,
        0 AS SomaFisico30D,
        0 AS SomaCusto30D,
        0 AS SomaFrequencia90D,
        0 AS SomaFisico90D,
        0 AS SomaCusto90D,

        -- FC18100/18000/03000 - produção (FP)

        -- Últimos 30 dias
        SUM(IIF(o.DTORD >= CURRENT_DATE - 30, 1, 0))                  AS SomaFrequencia30DFP,
        SUM(IIF(o.DTORD >= CURRENT_DATE - 30, i.QTREAL, 0))           AS SomaFisico30DFP,
        SUM(IIF(o.DTORD >= CURRENT_DATE - 30, i.QTREAL * p.PRCOM, 0)) AS SomaCusto30DFP,

        -- Últimos 90 dias
        SUM(IIF(o.DTORD >= CURRENT_DATE - 90, 1, 0))                  AS SomaFrequencia90DFP,
        SUM(IIF(o.DTORD >= CURRENT_DATE - 90, i.QTREAL, 0))           AS SomaFisico90DFP,
        SUM(IIF(o.DTORD >= CURRENT_DATE - 90, i.QTREAL * p.PRCOM, 0)) AS SomaCusto90DFP

    FROM
        FC18100 i
        JOIN FC18000 o ON o.NRORD  = i.NRORD
        JOIN FC03000 p ON p.CDPRO = i.CDPRO
    WHERE
        o.DTORD >= CURRENT_DATE - 90   -- idem, só últimos 90 dias
    GROUP BY
        i.CDPRO
),

UNION_Q AS (
    SELECT * FROM Q1
    UNION ALL
    SELECT * FROM Q2
)

SELECT
    CDPRO,

    --------------------------------------------------------------------
    -- COLUNAS ORIGINAIS (SOMA POR FONTE)
    --------------------------------------------------------------------
    -- FC12110
    SUM(SomaFrequencia30D)    AS SomaFrequencia30D,
    SUM(SomaFisico30D)        AS SomaFisico30D,
    SUM(SomaCusto30D)         AS SomaCusto30D,

    SUM(SomaFrequencia90D)    AS SomaFrequencia90D,
    SUM(SomaFisico90D)        AS SomaFisico90D,
    SUM(SomaCusto90D)         AS SomaCusto90D,

    -- FC18100/18000/03000 (FP)
    SUM(SomaFrequencia30DFP)  AS SomaFrequencia30DFP,
    SUM(SomaFisico30DFP)      AS SomaFisico30DFP,
    SUM(SomaCusto30DFP)       AS SomaCusto30DFP,

    SUM(SomaFrequencia90DFP)  AS SomaFrequencia90DFP,
    SUM(SomaFisico90DFP)      AS SomaFisico90DFP,
    SUM(SomaCusto90DFP)       AS SomaCusto90DFP,

    --------------------------------------------------------------------
    -- COLUNAS CONSOLIDADAS (Q1 + Q2)
    --------------------------------------------------------------------
    -- 30 dias
    SUM(SomaCusto30D)        + SUM(SomaCusto30DFP)       AS ConsolidadoCusto30D,
    SUM(SomaFrequencia30D)   + SUM(SomaFrequencia30DFP)  AS ConsolidadoFrequencia30D,
    SUM(SomaFisico30D)       + SUM(SomaFisico30DFP)      AS ConsolidadoFisico30D,

    -- 90 dias
    SUM(SomaCusto90D)        + SUM(SomaCusto90DFP)       AS ConsolidadoCusto90D,
    SUM(SomaFrequencia90D)   + SUM(SomaFrequencia90DFP)  AS ConsolidadoFrequencia90D,
    SUM(SomaFisico90D)       + SUM(SomaFisico90DFP)      AS ConsolidadoFisico90D

FROM
    UNION_Q
GROUP BY
    CDPRO
