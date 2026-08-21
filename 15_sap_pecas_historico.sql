-- =============================================================================
-- 15_sap_pecas_historico.sql
-- Substitui : sync_sap_pecas_historico.py -> QUERY
-- Destino   : public.sap_pecas_historico
-- Fonte     : já era nativa (AFIH/RESB/AUFK/EQKT/MAKT/MARA)
--
-- Parâmetros: %(ini)s e %(fim)s = Nº DE DIAS para trás (padronizado com as
-- demais queries do runner; ex.: ini=365, fim=0 = último ano). [PATCH r2.2]
--
-- >>> O PROBLEMA PRINCIPAL DESTA QUERY <<<
--
--   INNER JOIN RESB ON LTRIM(TRIM(AFIH.AUFNR),'0') = LTRIM(TRIM(RESB.AUFNR),'0')
--
--   Aplicar função nos DOIS lados de um join impede o uso de índice: o banco
--   é obrigado a materializar AFIH inteira e RESB inteira, calcular a função
--   linha a linha e só então casar (hash join sobre tudo). O mesmo padrão se
--   repetia em EQKT, MAKT, MARA e AUFK — cinco joins, todos cegos ao índice.
--
--   AUFNR, EQUNR e MATNR são CHAR de largura fixa com zeros à esquerda no SAP.
--   Se os dois lados vêm do SAP, eles JÁ são iguais byte a byte — o LTRIM é
--   desnecessário no join. Ele só é necessário na SAÍDA, e lá continua.
--
-- Ganhos:
--   1. Todos os joins passam a ser igualdade coluna-a-coluna (usa índice).
--   2. O recorte de data virou a CTE `ordens`, avaliada primeiro. Antes o
--      filtro de AUFK.ERDAT ficava no WHERE de um LEFT JOIN, ou seja, depois
--      de já ter montado o produto AFIH × RESB inteiro.
--   3. AUFK deixa de ser LEFT JOIN e vira o driver da query (o WHERE sobre
--      AUFK.ERDAT já tornava o LEFT JOIN um INNER JOIN na prática).
--   4. Os textos (EQKT/MAKT/MARA) são resolvidos por DISTINCT ON depois da
--      agregação, sobre um conjunto muito menor.
--
-- Correção: `MAX(LTRIM(TRIM(AFIH.AUFNR),'0'))` devolvia o maior número de ordem
-- como TEXTO ('9998' > '10001'), não a ordem mais recente. Agora `ultima_ordem`
-- é de fato a ordem da `ultima_data`.
-- =============================================================================

WITH ordens AS (
    SELECT
        a.aufnr,
        a.erdat,
        h.equnr
    FROM aufk a
    JOIN afih h ON h.aufnr = a.aufnr
    WHERE a.erdat >= TO_CHAR(CURRENT_DATE - %(ini)s::int, 'YYYY-MM-DD')
      AND a.erdat <= TO_CHAR(CURRENT_DATE - %(fim)s::int, 'YYYY-MM-DD')
      AND h.equnr IS NOT NULL
      AND TRIM(h.equnr) <> ''
),

consumo AS (
    SELECT
        o.equnr,
        r.matnr,
        o.aufnr,
        o.erdat,
        r.bdmng
    FROM ordens o
    JOIN resb r ON r.aufnr = o.aufnr
    WHERE r.matnr IS NOT NULL
      AND TRIM(r.matnr) <> ''
),

agregado AS (
    SELECT
        equnr,
        matnr,
        COUNT(DISTINCT aufnr) AS qtd_ocorrencias,
        SUM(bdmng)            AS qtd_total,
        MAX(erdat)            AS ultima_data
    FROM consumo
    GROUP BY equnr, matnr
),

ultima_ordem AS (
    -- Ordem correspondente à ultima_data (o MAX() de texto do original
    -- devolvia a ordem "alfabeticamente maior", não a mais recente).
    SELECT DISTINCT ON (c.equnr, c.matnr)
        c.equnr, c.matnr, c.aufnr
    FROM consumo c
    ORDER BY c.equnr, c.matnr, c.erdat DESC, c.aufnr DESC
),

desc_ativo AS (
    -- [PATCH r2.6-15] chaves normalizadas nos DOIS lados: nesta réplica o
    -- padding difere entre tabelas (mesmo caso do JEST) e o lookup zerava.
    SELECT DISTINCT ON (LTRIM(TRIM(k.equnr), '0'))
           LTRIM(TRIM(k.equnr), '0') AS equnr_norm, k.eqktx
    FROM eqkt k
    WHERE lower(k.spras) IN ('p', 'pt')
      AND LTRIM(TRIM(k.equnr), '0') IN (SELECT DISTINCT LTRIM(TRIM(equnr), '0') FROM agregado)
    ORDER BY LTRIM(TRIM(k.equnr), '0'), k.spras
),

desc_material AS (
    SELECT DISTINCT ON (LTRIM(TRIM(m.matnr), '0'))
           LTRIM(TRIM(m.matnr), '0') AS matnr_norm, m.maktx
    FROM makt m
    WHERE lower(m.spras) IN ('p', 'pt')
      AND LTRIM(TRIM(m.matnr), '0') IN (SELECT DISTINCT LTRIM(TRIM(matnr), '0') FROM agregado)
    ORDER BY LTRIM(TRIM(m.matnr), '0'), m.spras
)

SELECT
    LTRIM(TRIM(a.equnr), '0')  AS ativo,
    da.eqktx                   AS descricao_ativo,
    LTRIM(TRIM(a.matnr), '0')  AS cod_sap,
    dm.maktx                   AS descricao_componente,
    mara.matkl                 AS grupo_mercadoria,
    a.qtd_ocorrencias,
    a.qtd_total,
    LTRIM(TRIM(uo.aufnr), '0') AS ultima_ordem,
    a.ultima_data
FROM agregado a
LEFT JOIN ultima_ordem uo  ON uo.equnr = a.equnr AND uo.matnr = a.matnr
LEFT JOIN desc_ativo da    ON da.equnr_norm = LTRIM(TRIM(a.equnr), '0')
LEFT JOIN desc_material dm ON dm.matnr_norm = LTRIM(TRIM(a.matnr), '0')
LEFT JOIN mara             ON LTRIM(TRIM(mara.matnr), '0') = LTRIM(TRIM(a.matnr), '0')
ORDER BY 1, 3;
